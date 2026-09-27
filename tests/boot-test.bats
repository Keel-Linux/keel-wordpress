#!/usr/bin/env bats
# Unit tests of tests/lib/boot-test-lib.sh, the logic of the boot test:
# argument parsing, address discovery, deadlines, the container marks, the spec
# and secret paths, and every verdict this appliance adds. lxc-info is a stub
# first in PATH; the clock and sleep are functions. No root, no network, no LXC.

setup() {
    LIB="$BATS_TEST_DIRNAME/lib/boot-test-lib.sh"
    S="$BATS_TEST_TMPDIR"
    # shellcheck source=lib/boot-test-lib.sh
    source "$LIB"
}

# --- argument parsing --------------------------------------------------------

@test "parse_args takes the appliance and fills the defaults" {
    bt_parse_args wordpress
    [ "$BT_APPLIANCE" = wordpress ]
    [ "$BT_TIMEOUT" = "$BT_DEFAULT_TIMEOUT" ]
    [ "$BT_INTERVAL" = "$BT_DEFAULT_INTERVAL" ]
    [ "$BT_BRIDGE" = "$BT_DEFAULT_BRIDGE" ]
    [ "$BT_LAYERS_DIR" = "$BT_DEFAULT_LAYERS_DIR" ]
    [ "$BT_NAME" = keel-wordpress-boot-test ]
    [ "$BT_ROOTFS" = "$BT_DEFAULT_LXC_PATH/keel-wordpress-boot-test/rootfs" ]
    [ "$BT_KEEP" -eq 0 ]
    [ "$BT_SKIP_UPDATE" -eq 0 ]
}

@test "parse_args takes every option" {
    bt_parse_args wordpress --timeout 60 --interval 2 --bridge br9 \
        --layers-dir https://mirror.example.org/layers --cache-dir /tmp/c \
        --lxc-path /tmp/l --name demo.one --spec /tmp/s.yaml --keep --skip-update
    [ "$BT_TIMEOUT" = 60 ]
    [ "$BT_INTERVAL" = 2 ]
    [ "$BT_BRIDGE" = br9 ]
    [ "$BT_LAYERS_DIR" = https://mirror.example.org/layers ]
    [ "$BT_CACHE_DIR" = /tmp/c ]
    [ "$BT_LXC_PATH" = /tmp/l ]
    [ "$BT_NAME" = demo.one ]
    [ "$BT_SPEC" = /tmp/s.yaml ]
    [ "$BT_KEEP" -eq 1 ]
    [ "$BT_SKIP_UPDATE" -eq 1 ]
}

@test "parse_args refuses no appliance, two appliances and an unknown option" {
    run bt_parse_args
    [ "$status" -eq 1 ]
    [[ "$output" == *"APPLIANCE is required"* ]]
    run bt_parse_args wordpress mariadb
    [ "$status" -eq 1 ]
    [[ "$output" == *"one appliance at a time"* ]]
    run bt_parse_args wordpress --nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "parse_args refuses a bad appliance name and a keel- prefix" {
    run bt_parse_args WordPress
    [ "$status" -eq 1 ]
    run bt_parse_args keel-wordpress
    [ "$status" -eq 1 ]
    [[ "$output" == *"not an appliance name"* ]]
}

@test "parse_args refuses a container name LXC would not take" {
    run bt_parse_args wordpress --name "Bad Name"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a container name"* ]]
}

@test "parse_args refuses a timeout that is not a positive number" {
    run bt_parse_args wordpress --timeout 0
    [ "$status" -eq 1 ]
    run bt_parse_args wordpress --timeout abc
    [ "$status" -eq 1 ]
    run bt_parse_args wordpress --interval -1
    [ "$status" -eq 1 ]
}

@test "parse_args refuses an option with no value" {
    run bt_parse_args wordpress --bridge
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a value"* ]]
}

@test "the help text exits 2 and names the proofs" {
    run bt_parse_args --help
    [ "$status" -eq 2 ]
    [[ "$output" == *"wp-login"* ]] || [[ "$output" == *"logs in"* ]]
    [[ "$output" == *"apt-get update"* ]]
    [[ "$output" == *"apt-get install"* ]]
    [[ "$output" == *"apt-get download"* ]]
    [[ "$output" == *"apt-cache policy"* ]]
}

@test "container_name and the name predicates" {
    [ "$(bt_container_name wordpress)" = keel-wordpress-boot-test ]
    bt_is_container_name demo.one
    bt_is_container_name 9lives
    ! bt_is_container_name ".hidden"
    ! bt_is_container_name ""
    bt_is_appliance_name wordpress
    ! bt_is_appliance_name 9wordpress
}

# --- addresses ---------------------------------------------------------------

@test "is_global_ipv6 accepts a public address and a ULA" {
    bt_is_global_ipv6 2804:710:d0:5::13
    bt_is_global_ipv6 fc42:5009:ba4b:5ab0::1
    bt_is_global_ipv6 FD00::1
}

@test "is_global_ipv6 refuses link local, loopback, multicast and IPv4" {
    ! bt_is_global_ipv6 fe80::1
    ! bt_is_global_ipv6 FE80::1
    ! bt_is_global_ipv6 ::1
    ! bt_is_global_ipv6 ff02::1
    ! bt_is_global_ipv6 10.0.3.1
    ! bt_is_global_ipv6 ""
}

@test "global_ipv6 takes the first global address from lxc-info output" {
    run bt_global_ipv6 <<EOF
IP: 10.0.3.68
IP: fe80::1
IP: fc42:5009:ba4b:5ab0::20
IP: 2804:710:d0:5::99
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "fc42:5009:ba4b:5ab0::20" ]
}

@test "global_ipv6 fails when there is no global address yet" {
    run bt_global_ipv6 <<EOF
IP: 10.0.3.68
IP: fe80::1
EOF
    [ "$status" -eq 1 ]
}

@test "container_ipv6 reads the address through lxc-info" {
    mkdir -p "$S/bin"
    cat > "$S/bin/lxc-info" <<EOF
#!/bin/bash
echo "IP: 10.0.3.5"
echo "IP: fc42::7"
EOF
    chmod +x "$S/bin/lxc-info"
    PATH="$S/bin:$PATH"
    run bt_container_ipv6 some-name /var/lib/lxc
    [ "$output" = "fc42::7" ]
}

# --- deadlines ---------------------------------------------------------------

@test "deadline_passed compares the elapsed time with the timeout" {
    bt_deadline_passed 100 10 110
    bt_deadline_passed 100 10 115
    ! bt_deadline_passed 100 10 105
}

@test "wait_for returns as soon as the command succeeds" {
    BT_CLOCK="echo 0"
    run bt_wait_for 10 1 "a thing" true
    [ "$status" -eq 0 ]
}

@test "wait_for gives up once the deadline has passed and says what it waited for" {
    # A clock that advances on every reading, because a constant one never
    # reaches the deadline and the loop would never end.
    printf '0' > "$S/clock"
    _clock() {
        local n
        n=$(cat "$S/clock")
        n=$((n + 10))
        printf '%s' "$n" > "$S/clock"
        echo "$n"
    }
    BT_CLOCK=_clock
    BT_SLEEP=:
    run bt_wait_for 5 1 "the site" false
    [ "$status" -eq 1 ]
    [[ "$output" == *"timeout after 5s waiting for the site"* ]]
}

@test "now reads the clock it is given" {
    BT_CLOCK="echo 1234"
    [ "$(bt_now)" = 1234 ]
}

# --- first boot -------------------------------------------------------------

@test "is_ssh_banner accepts an OpenSSH banner and nothing else" {
    bt_is_ssh_banner "SSH-2.0-OpenSSH_10.0p2 Debian-8"
    ! bt_is_ssh_banner "220 ready"
    ! bt_is_ssh_banner ""
}

@test "firstboot_done_in reads the flag 98finalize clears" {
    printf 'RUN_FIRSTBOOT=true\n' > "$S/defaults"
    ! bt_firstboot_done_in "$S/defaults"
    printf 'RUN_FIRSTBOOT=false\n' > "$S/defaults"
    bt_firstboot_done_in "$S/defaults"
    ! bt_firstboot_done_in "$S/nothing-here"
}

# --- the container config and the container marks ----------------------------

@test "lxc_config carries the apparmor pair a systemd container needs" {
    run bt_lxc_config demo "$S/rootfs" br0
    [[ "$output" == *"lxc.apparmor.profile = generated"* ]]
    [[ "$output" == *"lxc.apparmor.allow_nesting = 1"* ]]
    [[ "$output" == *"lxc.rootfs.path = dir:$S/rootfs"* ]]
    [[ "$output" == *"lxc.net.0.link = br0"* ]]
    [[ "$output" == *"lxc.uts.name = demo"* ]]
}

@test "mark_container writes the marker, the redirect and the drop-in" {
    mkdir -p "$S/rootfs/etc/default"
    printf 'REDIRECT_OUTPUT=false\nRUN_FIRSTBOOT=true\n' > "$S/rootfs/$BT_INITHOOKS_DEFAULT"
    run bt_mark_container "$S/rootfs"
    [ "$status" -eq 0 ]
    [ -f "$S/rootfs/$BT_CONTAINER_MARKER" ]
    grep -qx 'REDIRECT_OUTPUT=true' "$S/rootfs/$BT_INITHOOKS_DEFAULT"
    grep -q 'StandardOutput=journal' "$S/rootfs/$BT_INITHOOKS_DROPIN"
}

@test "mark_container fails when the defaults file is missing or has no redirect" {
    mkdir -p "$S/r2"
    run bt_mark_container "$S/r2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not in the rootfs"* ]]
    mkdir -p "$S/r3/etc/default"
    printf 'RUN_FIRSTBOOT=true\n' > "$S/r3/$BT_INITHOOKS_DEFAULT"
    run bt_mark_container "$S/r3"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares no REDIRECT_OUTPUT"* ]]
}

# --- the spec and the secrets -----------------------------------------------

@test "spec_targets names both paths the first boot may read" {
    run bt_spec_targets /rootfs
    [ "${lines[0]}" = "/rootfs/etc/keel/instance.yaml" ]
    [ "${lines[1]}" = "/rootfs/etc/inithooks.yaml" ]
}

@test "secret_targets names the three secrets this appliance declares" {
    run bt_secret_targets /rootfs
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "/rootfs/etc/keel/secrets/root_password" ]
    [ "${lines[1]}" = "/rootfs/etc/keel/secrets/db_password" ]
    [ "${lines[2]}" = "/rootfs/etc/keel/secrets/app_password" ]
}

@test "spec_in_rootfs points every secret reference inside the rootfs" {
    cat > "$S/spec.yaml" <<EOF
secrets:
  root_password:
    file: /etc/keel/secrets/root_password
  app_password:
    file: /etc/keel/secrets/app_password
EOF
    run bt_spec_in_rootfs "$S/spec.yaml" /var/lib/lxc/x/rootfs
    [[ "$output" == *"file: /var/lib/lxc/x/rootfs/etc/keel/secrets/root_password"* ]]
    [[ "$output" == *"file: /var/lib/lxc/x/rootfs/etc/keel/secrets/app_password"* ]]
}

@test "random_password gives the declared length from the source it is given" {
    BT_RANDOM_SOURCE=/dev/urandom
    run bt_random_password
    [ "$status" -eq 0 ]
    [ "${#output}" -eq "$BT_PASSWORD_LENGTH" ]
    [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
}

@test "random_password fails rather than shortening when the source is poor" {
    printf 'xy\n' > "$S/poor"
    BT_RANDOM_SOURCE="$S/poor"
    run bt_random_password
    [ "$status" -eq 1 ]
    [[ "$output" == *"usable characters"* ]]
}

# --- the HTTP verdicts ------------------------------------------------------

@test "page_title reads the first title and nothing when there is none" {
    printf '<html>\n<head><title>Keel Linux WordPress</title></head>\n' > "$S/p"
    [ "$(bt_page_title "$S/p")" = "Keel Linux WordPress" ]
    printf '<html><head></head>' > "$S/q"
    [ -z "$(bt_page_title "$S/q")" ]
}

@test "http_verdict passes on 200 with a title" {
    run bt_http_verdict 443 200 "Keel Linux WordPress"
    [ "$status" -eq 0 ]
    [[ "$output" == *"port 443 answered 200"* ]]
}

@test "http_verdict refuses a redirect, an error and a page with no title" {
    run bt_http_verdict 80 301 "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"port 80 answered 301, not 200"* ]]
    run bt_http_verdict 443 500 "x"
    [ "$status" -eq 1 ]
    run bt_http_verdict 443 200 ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"no title element"* ]]
}

@test "installer_verdict refuses every shape of the WordPress installer" {
    for marker in 'wp-admin/install.php' 'setup-config.php' \
        'WordPress &rsaquo; Installation' 'WordPress &rsaquo; Setup Configuration File'; do
        printf '<html>%s wp-content/x</html>' "$marker" > "$S/page"
        run bt_installer_verdict "$S/page"
        [ "$status" -eq 1 ]
        [[ "$output" == *"offering the WordPress installer"* ]]
    done
}

@test "installer_verdict refuses a page that is not a WordPress site at all" {
    printf '<html><body>nginx default</body></html>' > "$S/page"
    run bt_installer_verdict "$S/page"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing a WordPress site would serve"* ]]
}

@test "installer_verdict passes on a served WordPress page" {
    printf '<html><link href="/wp-includes/css/x.css"></html>' > "$S/page"
    run bt_installer_verdict "$S/page"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installer is not offered"* ]]
}

# --- wp-config.php ----------------------------------------------------------

_config() {
    cat > "$S/wp-config.php" <<EOF
<?php
define('DB_NAME', '${1:-wordpress}');
define('DB_USER', '${2:-wordpress}');
define('DB_PASSWORD', '${3:-a-real-password}');
define('DB_HOST', '${4:-[::1]}');
EOF
}

@test "config_verdict passes on a config that names the local database" {
    _config
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 0 ]
    [[ "$output" == *"names 'wordpress' as 'wordpress'"* ]]
}

@test "config_verdict accepts the IPv4 loopback and the socket" {
    _config wordpress wordpress pass 127.0.0.1
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 0 ]
    _config wordpress wordpress pass localhost
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 0 ]
}

@test "config_verdict refuses a remote database host" {
    _config wordpress wordpress pass db.example.org
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not point at the local database"* ]]
}

@test "config_verdict refuses the upstream build time password" {
    _config wordpress wordpress turnkey
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream build time password"* ]]
    # an empty password is the other value upstream's build left behind
    cat > "$S/wp-config.php" <<EOF
<?php
define('DB_NAME', 'wordpress');
define('DB_USER', 'wordpress');
define('DB_PASSWORD', '');
define('DB_HOST', '[::1]');
EOF
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 1 ]
    [[ "$output" == *"upstream build time password"* ]]
}

@test "config_verdict refuses another database or account, and a missing field" {
    _config other wordpress
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not name the database"* ]]
    _config wordpress someone
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not name the account"* ]]
    printf "<?php\ndefine('DB_NAME', 'wordpress');\n" > "$S/wp-config.php"
    run bt_config_verdict "$S/wp-config.php" wordpress wordpress
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no DB_USER"* ]]
}

@test "password_in_config compares the declared password with the one in the file" {
    _config wordpress wordpress 'S3cret-value'
    bt_password_in_config "$S/wp-config.php" 'S3cret-value'
    ! bt_password_in_config "$S/wp-config.php" 'something-else'
    printf "<?php\n" > "$S/wp-config.php"
    ! bt_password_in_config "$S/wp-config.php" 'S3cret-value'
}

# --- the login verdicts -----------------------------------------------------

@test "login_verdict passes on a redirect that set the session cookie" {
    printf '# Netscape HTTP Cookie File\nx\tFALSE\t/\tTRUE\t0\twordpress_logged_in_abc\tvalue\n' > "$S/jar"
    run bt_login_verdict 302 "$S/jar"
    [ "$status" -eq 0 ]
    [[ "$output" == *"accepted and set a wordpress_logged_in_ cookie"* ]]
}

@test "login_verdict reads a 200 as the form coming back, which is a refusal" {
    : > "$S/jar"
    run bt_login_verdict 200 "$S/jar"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the login was refused"* ]]
}

@test "login_verdict refuses a redirect with no session cookie" {
    : > "$S/jar"
    run bt_login_verdict 302 "$S/jar"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no wordpress_logged_in_ cookie"* ]]
}

@test "login_verdict refuses any other status" {
    : > "$S/jar"
    run bt_login_verdict 500 "$S/jar"
    [ "$status" -eq 1 ]
    [[ "$output" == *"answered 500"* ]]
}

@test "refused_login_verdict wants the form back and no cookie" {
    : > "$S/jar"
    run bt_refused_login_verdict 200 "$S/jar"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wrong password was refused"* ]]
    run bt_refused_login_verdict 302 "$S/jar"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not the login form again"* ]]
    printf 'wordpress_logged_in_abc\tvalue\n' > "$S/jar"
    run bt_refused_login_verdict 200 "$S/jar"
    [ "$status" -eq 1 ]
    [[ "$output" == *"was given a wordpress_logged_in_ cookie"* ]]
}

@test "dashboard_verdict wants the dashboard and not the login form" {
    printf '<div id="adminmenu">Dashboard</div>' > "$S/dash"
    run bt_dashboard_verdict 200 "$S/dash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"with the dashboard"* ]]
    printf '<form name="loginform">' > "$S/dash"
    run bt_dashboard_verdict 200 "$S/dash"
    [ "$status" -eq 1 ]
    [[ "$output" == *"served the login form"* ]]
    printf 'something else' > "$S/dash"
    run bt_dashboard_verdict 200 "$S/dash"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not the dashboard"* ]]
    run bt_dashboard_verdict 302 "$S/dash"
    [ "$status" -eq 1 ]
    [[ "$output" == *"answered 302 with the login cookie"* ]]
}

# --- the update path --------------------------------------------------------

_sources() {
    cat > "$S/keel.sources" <<EOF
Types: deb
URIs: ${1:-https://archive.keellinux.org}
Suites: ${2:-trixie}
Components: main
Enabled: ${3:-yes}
Signed-By: ${4:-/usr/share/keyrings/keel-archive-keyring.gpg}
EOF
}

@test "sources_verdict passes on the source as the appliance ships it" {
    _sources
    run bt_sources_verdict "$S/keel.sources"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is enabled and verified with"* ]]
}

@test "sources_verdict refuses a disabled source, a staging suite, another archive and another keyring" {
    _sources https://archive.keellinux.org trixie no
    run bt_sources_verdict "$S/keel.sources"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not enabled"* ]]
    _sources https://archive.keellinux.org trixie-staging yes
    run bt_sources_verdict "$S/keel.sources"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names the suite 'trixie-staging'"* ]]
    _sources https://apt.example.org trixie yes
    run bt_sources_verdict "$S/keel.sources"
    [ "$status" -eq 1 ]
    _sources https://archive.keellinux.org trixie yes /usr/share/keyrings/other.gpg
    run bt_sources_verdict "$S/keel.sources"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is signed by"* ]]
}

@test "apt_update_verdict passes when our archive was read and nothing complained" {
    printf 'Get:8 https://archive.keellinux.org trixie InRelease [1867 B]\nReading package lists...\n' > "$S/out"
    run bt_apt_update_verdict 0 "$S/out"
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified its signature"* ]]
}

@test "apt_update_verdict refuses a non zero exit" {
    : > "$S/out"
    run bt_apt_update_verdict 100 "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exited 100"* ]]
}

@test "apt_update_verdict refuses every way apt says it could not verify" {
    for complaint in NO_PUBKEY 'is not signed' 'not have a Release file' \
        EXPKEYSIG REVKEYSIG BADSIG 'insufficiently signed' 'cannot be authenticated'; do
        printf 'Get:8 https://archive.keellinux.org trixie InRelease\nW: %s\n' "$complaint" > "$S/out"
        run bt_apt_update_verdict 0 "$S/out"
        [ "$status" -eq 1 ]
        [[ "$output" == *"could not verify the archive"* ]]
    done
}

@test "apt_update_verdict refuses a run that never reached our archive" {
    printf 'Get:1 http://deb.debian.org/debian trixie InRelease\n' > "$S/out"
    run bt_apt_update_verdict 0 "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"never reached"* ]]
}

_policy() {
    cat > "$S/policy" <<EOF
inithooks:
  Installed: ${1:-2.3.6+keel4}
  Candidate: ${2:-2.3.6+keel5}
  Version table:
     ${2:-2.3.6+keel5} ${3:-1001}
        ${3:-1001} ${4:-https://archive.keellinux.org} trixie/main amd64 Packages
 *** ${1:-2.3.6+keel4} 100
        100 /var/lib/dpkg/status
EOF
}

@test "policy_verdict passes when the candidate comes from our archive at our pin" {
    _policy
    run bt_policy_verdict inithooks "$S/policy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"takes inithooks from https://archive.keellinux.org at priority 1001"* ]]
    [[ "$output" == *"candidate 2.3.6+keel5"* ]]
}

@test "policy_verdict passes when the archive offers exactly what is installed" {
    # the ordinary state of a current appliance, and not a failure
    _policy 2.3.6+keel5 2.3.6+keel5
    run bt_policy_verdict inithooks "$S/policy"
    [ "$status" -eq 0 ]
}

@test "policy_verdict refuses a package apt has no candidate for" {
    printf 'inithooks:\n  Installed: (none)\n  Candidate: (none)\n' > "$S/policy"
    run bt_policy_verdict inithooks "$S/policy"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no candidate"* ]]
}

@test "policy_verdict refuses an archive that is not a source at our pin" {
    _policy 2.3.6+keel4 2.3.6+keel5 500
    run bt_policy_verdict inithooks "$S/policy"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a source of inithooks at priority 1001"* ]]
}

@test "policy_verdict refuses a candidate that comes from somewhere else" {
    cat > "$S/policy" <<EOF
inithooks:
  Installed: 2.3.6+keel4
  Candidate: 9.9.9
  Version table:
     9.9.9 990
        990 http://deb.debian.org/debian trixie/main amd64 Packages
     2.3.6+keel5 1001
        1001 https://archive.keellinux.org trixie/main amd64 Packages
EOF
    run bt_policy_verdict inithooks "$S/policy"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not come from"* ]]
}

@test "absent_verdict wants the package not installed before the proof" {
    run bt_absent_verdict keel-transition "unknown ok not-installed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is not in the image"* ]]
    run bt_absent_verdict keel-transition ""
    [ "$status" -eq 0 ]
    run bt_absent_verdict keel-transition "install ok installed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"would prove nothing"* ]]
}

@test "download_verdict passes when apt fetched the deb from our archive" {
    printf 'Get:1 https://archive.keellinux.org trixie/main amd64 keel-transition all 0.1.1 [13.8 kB]\n' > "$S/out"
    run bt_download_verdict keel-transition 0 13836 "$S/out"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fetched keel-transition from https://archive.keellinux.org"* ]]
    [[ "$output" == *"13836 bytes"* ]]
}

@test "download_verdict refuses a non zero exit, another archive and a missing file" {
    printf 'Get:1 https://archive.keellinux.org trixie/main amd64 keel-transition all 0.1.1\n' > "$S/out"
    run bt_download_verdict keel-transition 100 13836 "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exited 100"* ]]
    printf 'Get:1 http://deb.debian.org/debian trixie/main amd64 keel-transition all 0.1.1\n' > "$S/out2"
    run bt_download_verdict keel-transition 0 13836 "$S/out2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not fetch keel-transition from"* ]]
    run bt_download_verdict keel-transition 0 0 "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"left no file"* ]]
    run bt_download_verdict keel-transition 0 "" "$S/out"
    [ "$status" -eq 1 ]
}

@test "install_verdict passes when apt fetched it from our archive and dpkg configured it" {
    printf 'Get:1 https://archive.keellinux.org trixie/main amd64 keel-archive-keyring all 0.1.1 [4904 B]\n' > "$S/out"
    run bt_install_verdict keel-archive-keyring 0 0.1.1 "install ok installed" "$S/out"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fetched and reinstalled keel-archive-keyring 0.1.1"* ]]
}

@test "install_verdict refuses a non zero exit" {
    : > "$S/out"
    run bt_install_verdict keel-archive-keyring 100 "" "" "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exited 100"* ]]
}

@test "install_verdict refuses a package that came from anywhere but our archive" {
    printf 'Get:1 http://deb.debian.org/debian trixie/main amd64 keel-transition all 0.1.1 [13.8 kB]\n' > "$S/out"
    run bt_install_verdict keel-transition 0 0.1.1 "install ok installed" "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not fetch keel-transition from"* ]]
}

@test "install_verdict refuses a half configured package and one with no version" {
    printf 'Get:1 https://archive.keellinux.org trixie/main amd64 keel-transition all 0.1.1 [13.8 kB]\n' > "$S/out"
    run bt_install_verdict keel-transition 0 0.1.1 "install ok unpacked" "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not 'install ok installed'"* ]]
    run bt_install_verdict keel-transition 0 "" "install ok installed" "$S/out"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no version after the install"* ]]
}

# --- keel diff --------------------------------------------------------------

@test "diff_verdict reads 0 and 13 as no drift" {
    run bt_diff_verdict 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"no drift"* ]]
    run bt_diff_verdict 13
    [ "$status" -eq 0 ]
    [[ "$output" == *"no drift"* ]]
}

@test "diff_verdict reads 14 as drift and 2, 3 and anything else as a failure" {
    run bt_diff_verdict 14
    [ "$status" -eq 1 ]
    [[ "$output" == *"drift found"* ]]
    run bt_diff_verdict 2
    [ "$status" -eq 1 ]
    [[ "$output" == *"unreadable or invalid"* ]]
    run bt_diff_verdict 3
    [ "$status" -eq 1 ]
    run bt_diff_verdict 9
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed with exit 9"* ]]
}

@test "apt_update_verdict refuses an update that could not fetch the archive" {
    out=$BATS_TEST_TMPDIR/update.txt
    printf '%s\n' \
        "Hit:1 https://deb.debian.org/debian trixie InRelease" \
        "W: Failed to fetch https://archive.keellinux.org/dists/trixie/InRelease  SSL connection failed [IP: 127.0.1.1 443]" \
        "W: Some index files failed to download. They have been ignored, or old ones used instead." \
        > "$out"

    run bt_apt_update_verdict 0 "$out"

    [ "$status" -eq 1 ]
    [[ "$output" == *"could not fetch"* ]]
}

@test "archive_reachable refuses a loopback answer and accepts a routable one" {
    run bt_archive_reachable "127.0.1.1     archive.keellinux.org"
    [ "$status" -ne 0 ]
    run bt_archive_reachable "::1           archive.keellinux.org"
    [ "$status" -ne 0 ]
    run bt_archive_reachable "2804:710:d0:5::13 STREAM archive.keellinux.org"
    [ "$status" -eq 0 ]
    run bt_archive_reachable ""
    [ "$status" -ne 0 ]
}
