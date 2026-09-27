#!/bin/bash
# Boot test of this appliance (org-plan section 1), modelled on the ones in
# keel-core, keel-nodebb and the two database appliances: assemble the
# published layer chain into an LXC rootfs, boot it headless from
# tests/instance.yaml, wait for the first boot to finish, and then prove that
# the appliance does what it exists to do.
#
# What it proves, in order, and none of it by reading a file the build wrote:
#
#   1. the site answers 200 over IPv6 on port 80 and on port 443
#   2. the page is a WordPress site and not the WordPress installer
#   3. wp-config.php names the local database, the appliance's own account and
#      the password the instance description declared, and none of upstream's
#      build time values
#   4. the database and the database account exist, and that account can log
#      in to the database with the declared password
#   5. the administrator logs in over HTTP with the declared app_password and
#      is given a session cookie, a wrong password is refused, and the
#      dashboard comes back for the session
#   6. apt-get update against archive.keellinux.org verifies its signature,
#      apt takes a project package from that archive at the appliance's own pin
#      priority, a project package the image has not got is fetched from it
#      against the digest of the signed index, and a project package the image
#      has is downloaded again and put through dpkg
#   7. keel diff reports no drift between the spec and the machine
#
# Called by the reusable workflow test-appliance.yml after keel pull and keel
# verify; runnable by hand as root on any host with LXC, see tests/README.md.
# It builds nothing: the layers come from the mirror or from a directory
# bt-layer wrote, so the test needs no fab, deck or buildtasks. The logic lives
# in tests/lib/boot-test-lib.sh and is unit tested; this file is the thin main
# that touches the system.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/boot-test-lib.sh
source "$here/lib/boot-test-lib.sh"

bt_parse_args "$@" || { rc=$?; [ "$rc" -eq 2 ] && exit 0; exit 1; }
BT_SPEC=${BT_SPEC:-$here/instance.yaml}
if [ "$(id -u)" -ne 0 ]; then
    echo "boot-test: must run as root (keel assemble, lxc-start)" >&2
    exit 1
fi
for tool in keel lxc-start lxc-info lxc-attach lxc-stop curl; do
    command -v "$tool" >/dev/null || { echo "boot-test: $tool not found" >&2; exit 1; }
done

container_dir=$BT_LXC_PATH/$BT_NAME
log() { printf '%s boot-test: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
lxc() { "lxc-$1" -P "$BT_LXC_PATH" -n "$BT_NAME" "${@:2}"; }
# Everything that needs a secret runs inside the container and reads it from
# the container's own /etc/keel/secrets, so no password is ever an argument of
# a command on this host.
inside() { lxc attach --clear-env -- /bin/bash -c "$1"; }

cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -r "$BT_ROOTFS/var/log/inithooks.log" ]; then
        log "last lines of the container's inithooks log:"
        tail -n 60 "$BT_ROOTFS/var/log/inithooks.log"
    fi
    if [ "$BT_KEEP" -eq 1 ]; then
        log "keeping $BT_NAME under $BT_LXC_PATH (--keep); lxc-attach -P $BT_LXC_PATH -n $BT_NAME"
        return
    fi
    lxc stop -k >/dev/null 2>&1 || true
    rm -rf "$container_dir"
}
trap cleanup EXIT

# 1. Assemble the chain from the layers the build host published.
log "assembling $BT_APPLIANCE from $BT_LAYERS_DIR into $BT_ROOTFS"
lxc stop -k >/dev/null 2>&1 || true
rm -rf "$container_dir"
mkdir -p "$BT_ROOTFS"
keel pull "$BT_APPLIANCE" --source "$BT_LAYERS_DIR" --cache-dir "$BT_CACHE_DIR" --non-interactive
keel assemble "$BT_APPLIANCE" --rootfs "$BT_ROOTFS" --cache-dir "$BT_CACHE_DIR" --non-interactive

# 2. The container marks, the instance spec, the secrets it references and the
#    conf the first boot hooks read. bt_mark_container does what buildtasks'
#    container patch does: the marker under /var/lib/turnkey-info that inspect
#    reads to call the machine a container (managed_by: host), and
#    REDIRECT_OUTPUT=true, without which a hook that prints a lot blocks
#    writing to a tty1 nobody reads. The conf is what makes the first boot
#    headless; without it 30rootpass, 35mysqlpass and 40wordpress wait on a
#    dialog forever.
log "installing the spec, the secrets and the conf into $BT_ROOTFS"
bt_mark_container "$BT_ROOTFS"
install -d -m 0700 "$BT_ROOTFS/etc/keel/secrets"
for target in $(bt_secret_targets "$BT_ROOTFS"); do
    bt_random_password > "$target"
    chmod 0600 "$target"
done
for target in $(bt_spec_targets "$BT_ROOTFS"); do
    install -D -m 0600 "$BT_SPEC" "$target"
done
bt_spec_in_rootfs "$BT_SPEC" "$BT_ROOTFS" > "$container_dir/instance-host.yaml"
keel spec apply --spec "$container_dir/instance-host.yaml" \
    --conf "$BT_ROOTFS/etc/inithooks.conf" --non-interactive

# 3. Boot.
bt_lxc_config "$BT_NAME" "$BT_ROOTFS" "$BT_BRIDGE" > "$container_dir/config"
log "starting $BT_NAME on bridge $BT_BRIDGE"
lxc start -d

# 4. A global IPv6 address from the bridge.
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "a global IPv6 address on $BT_NAME" \
    bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH" > /dev/null
addr=$(bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH")
log "container address $addr"

# 5. First boot finished: 98finalize has cleared RUN_FIRSTBOOT and the machine
#    answers, on the console (confconsole's usage screen) or on SSH. The answer
#    alone is not enough: sshd is up long before the hooks are done, so the
#    flag is what says the first boot ended.
usage_screen() {
    lxc attach -- pgrep -f confconsole > /dev/null 2>&1
}
ssh_answers() {
    local banner
    banner=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1" && read -r -t 5 line <&3 && printf "%s" "$line"' \
        "$addr" "$BT_SSH_PORT" 2>/dev/null) || return 1
    bt_is_ssh_banner "$banner"
}
first_boot_done() {
    bt_firstboot_done_in "$BT_ROOTFS/etc/default/inithooks" || return 1
    usage_screen || ssh_answers
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the first boot of $BT_NAME to finish" \
    first_boot_done
log "first boot finished; ssh root@$addr"

# 6. The site answers on both ports. WordPress is up as soon as Apache is, but
#    40wordpress restarts Apache at the end of the first boot, so the page is
#    polled rather than fetched once.
page=$container_dir/index.html
code=""
site_answers() {
    code=$(curl -6 -k -sS -o "$page" -w '%{http_code}' "https://[$addr]/" 2>/dev/null || true)
    [ "$code" = 200 ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the site on https://[$addr]/" site_answers
bt_http_verdict 443 "$code" "$(bt_page_title "$page")"

plain=$container_dir/index-80.html
code80=$(curl -6 -sS -o "$plain" -w '%{http_code}' "http://[$addr]/" 2>/dev/null || true)
bt_http_verdict 80 "$code80" "$(bt_page_title "$plain")"

# 7. It is a WordPress site, and it is not the installer.
bt_installer_verdict "$page"

# 8. wp-config.php: what it names, and that it carries the declared password.
#    The rootfs copy is read, because what the appliance runs on is what has to
#    be right, and the comparison happens in the shell so the password never
#    becomes an argument.
config=$BT_ROOTFS/$BT_WP_CONFIG
[ -r "$config" ] || { echo "boot-test: no $BT_WP_CONFIG in the rootfs" >&2; exit 1; }
bt_config_verdict "$config" wordpress wordpress
if bt_password_in_config "$config" "$(cat "$BT_ROOTFS/etc/keel/secrets/db_password")"; then
    echo "boot-test: wp-config.php carries the declared secrets.db_password"
else
    echo "boot-test: wp-config.php does not carry the declared secrets.db_password" >&2
    exit 1
fi

# 9. The database and the account, asked of the database rather than of a file,
#    from inside the container with the secret the container already holds.
db_report=$(inside '
    export MYSQL_PWD=$(cat /etc/keel/secrets/db_password)
    mysql --user=wordpress --host=::1 --port=3306 --protocol=TCP --batch \
        --skip-column-names --execute="
            SELECT CURRENT_USER(),
                   (SELECT COUNT(*) FROM information_schema.schemata
                     WHERE schema_name = '"'"'wordpress'"'"'),
                   (SELECT COUNT(*) FROM information_schema.tables
                     WHERE table_schema = '"'"'wordpress'"'"'
                       AND table_name = '"'"'wp_users'"'"')"
') || { echo "boot-test: the wordpress account cannot reach its database over [::1]:3306" >&2; exit 1; }
echo "boot-test: the database answered: $db_report"
case "$db_report" in
    wordpress@*$'\t'1$'\t'1) echo "boot-test: the wordpress database, the wp_users table and the wordpress account all exist" ;;
    *) echo "boot-test: the database is not in the state the first boot should have left ($db_report)" >&2; exit 1 ;;
esac

# 10. A real login. The password is written once, without its newline, into a
#     file curl reads, so it is never an argument; the login is a POST and the
#     verdict is the session cookie, because fetching the login form proves
#     nothing at all.
passfile=$container_dir/app_password
umask 0077
printf '%s' "$(cat "$BT_ROOTFS/etc/keel/secrets/app_password")" > "$passfile"
jar=$container_dir/cookies
rm -f "$jar"
login_code=$(curl -6 -k -sS -o "$container_dir/login.html" -w '%{http_code}' \
    -c "$jar" -b 'wordpress_test_cookie=WP Cookie check' \
    -d 'log=admin' --data-urlencode "pwd@$passfile" \
    -d 'wp-submit=Log In' -d 'testcookie=1' \
    --data-urlencode "redirect_to=https://[$addr]/wp-admin/" \
    "https://[$addr]/wp-login.php")
bt_login_verdict "$login_code" "$jar"

dash_code=$(curl -6 -k -sS -o "$container_dir/wp-admin.html" -w '%{http_code}' \
    -b "$jar" -c "$jar" "https://[$addr]/wp-admin/")
bt_dashboard_verdict "$dash_code" "$container_dir/wp-admin.html"

badjar=$container_dir/cookies-bad
rm -f "$badjar"
printf '%s' "not-the-password" > "$container_dir/bad_password"
bad_code=$(curl -6 -k -sS -o /dev/null -w '%{http_code}' \
    -c "$badjar" -b 'wordpress_test_cookie=WP Cookie check' \
    -d 'log=admin' --data-urlencode "pwd@$container_dir/bad_password" \
    -d 'wp-submit=Log In' -d 'testcookie=1' \
    "https://[$addr]/wp-login.php")
bt_refused_login_verdict "$bad_code" "$badjar"
rm -f "$passfile" "$container_dir/bad_password"

# 11. The update path: the appliance's own APT source, then apt itself. This is
#     the half of the deliverable that is not about WordPress, and it is proved
#     on the booted machine because a source file that says the right thing and
#     an apt that cannot verify the archive look identical from the build.
bt_sources_verdict "$BT_ROOTFS/$BT_SOURCES"
if [ "$BT_SKIP_UPDATE" -eq 1 ]; then
    log "--skip-update: the two APT proofs were not run"
else
    update_out=$container_dir/apt-update.txt
    set +e
    inside 'apt-get update' > "$update_out" 2>&1
    update_code=$?
    set -e
    tail -n 6 "$update_out"
    bt_apt_update_verdict "$update_code" "$update_out"

    # Where apt would take a project package from. Not whether a newer one
    # exists: that depends on what the archive happens to hold tonight, and a
    # test that needs it either invents a release or wants the image kept
    # stale. What matters to an operator is that this machine's project
    # packages come from our archive, at the priority the appliance sets.
    policy_out=$container_dir/apt-policy.txt
    inside "apt-cache policy $BT_POLICY_PACKAGE" > "$policy_out" 2>&1
    cat "$policy_out"
    bt_policy_verdict "$BT_POLICY_PACKAGE" "$policy_out"

    # A project package the image has not got, fetched from our archive. Both
    # this and the next step stay inside our archive: the CI runner has no
    # IPv4 route out, so a step that needed a package from Debian would be
    # testing the runner's network and not the appliance.
    before=$(inside "dpkg-query -W -f '\${Status}' $BT_FETCH_PACKAGE 2>/dev/null" || true)
    bt_absent_verdict "$BT_FETCH_PACKAGE" "$before"
    fetch_out=$container_dir/apt-download.txt
    set +e
    inside "cd /run && rm -f ${BT_FETCH_PACKAGE}_*.deb && apt-get download $BT_FETCH_PACKAGE" \
        > "$fetch_out" 2>&1
    fetch_code=$?
    set -e
    tail -n 4 "$fetch_out"
    fetched=$(inside "ls /run/${BT_FETCH_PACKAGE}_*.deb 2>/dev/null | head -1" || true)
    bt_download_verdict "$BT_FETCH_PACKAGE" "$fetch_code" \
        "${BT_ROOTFS}${fetched:-/run/nothing}" "$fetch_out"
    inside "rm -f /run/${BT_FETCH_PACKAGE}_*.deb" || true

    # And the installation half: the same archive, downloaded again and put
    # through dpkg.
    install_out=$container_dir/apt-install.txt
    set +e
    inside "DEBIAN_FRONTEND=noninteractive apt-get -y install --reinstall $BT_INSTALL_PACKAGE" \
        > "$install_out" 2>&1
    install_code=$?
    set -e
    tail -n 6 "$install_out"
    version=$(inside "dpkg-query -W -f '\${Version}' $BT_INSTALL_PACKAGE" || true)
    status=$(inside "dpkg-query -W -f '\${Status}' $BT_INSTALL_PACKAGE" || true)
    bt_install_verdict "$BT_INSTALL_PACKAGE" "$install_code" "$version" "$status" "$install_out"
fi

# 12. No drift between the declared spec and the booted root.
set +e
keel diff --root "$BT_ROOTFS" --spec "$BT_SPEC"
code=$?
set -e
bt_diff_verdict "$code"
log "$BT_APPLIANCE boot test passed"
