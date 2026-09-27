#!/bin/bash
# Pure helpers of tests/boot-test.sh (decision 0004: logic apart from effect).
# Same shape as the ones in keel-core, keel-nodebb and the two database
# appliances, with the checks this appliance adds: three secrets, a verdict on
# what WordPress answers on each port, a verdict on a real login, and verdicts
# on the appliance's own update path. Nothing here starts a container, writes
# outside a path it is given or opens a socket. The functions that run a
# command take it from the environment or from PATH so a test can replace it.
# Sourced by boot-test.sh and by tests/boot-test.bats.
# shellcheck disable=SC2034  # the BT_* variables are read by the caller

BT_DEFAULT_TIMEOUT=900
BT_DEFAULT_INTERVAL=5
BT_DEFAULT_BRIDGE=lxcbr0
BT_DEFAULT_LAYERS_DIR=/mnt/builds/layers
BT_DEFAULT_CACHE_DIR=/var/cache/keel/layers
BT_DEFAULT_LXC_PATH=/var/lib/lxc
BT_SSH_PORT=22
BT_PASSWORD_LENGTH=24
BT_RANDOM_BYTES=1024
# The secrets tests/instance.yaml references, one file each under
# etc/keel/secrets in the rootfs: the root account, the WordPress database
# account and the WordPress administrator.
BT_SECRETS="root_password db_password app_password"
# Where the first boot reads the instance description. inithooks reads
# etc/inithooks.yaml (hook 00declarative), keel reads etc/keel/instance.yaml;
# the final name is a maintainer decision (brief section 11), so the test
# installs the same file at both until then.
BT_SPEC_PATHS="etc/keel/instance.yaml etc/inithooks.yaml"
# What marks the tree as a container build, relative to the rootfs: the marker
# file bt-container writes and the inithooks defaults whose REDIRECT_OUTPUT it
# sets. See bt_mark_container.
BT_CONTAINER_MARKER="var/lib/turnkey-info/inithooks.service/lxc"
BT_INITHOOKS_DEFAULT="etc/default/inithooks"
BT_INITHOOKS_DROPIN="etc/systemd/system/inithooks.service.d/container.conf"
# Where WordPress lives in the appliance, and the fields of wp-config.php this
# test reads back.
BT_WP_ROOT="var/www/wordpress"
BT_WP_CONFIG="$BT_WP_ROOT/wp-config.php"
# The project's own APT archive, and the keyring it must be verified with.
BT_ARCHIVE_URI="https://archive.keellinux.org"
BT_ARCHIVE_SUITE="trixie"
BT_ARCHIVE_KEYRING="/usr/share/keyrings/keel-archive-keyring.gpg"
BT_SOURCES="etc/apt/sources.list.d/keel.sources"
# What the two update proofs use, beyond apt-get update itself.
#
# A project package the image already carries, to show that apt would take its
# next version from our archive rather than from anywhere else: the candidate
# has to come from our archive, at the priority the appliance's own pin file
# sets.
BT_POLICY_PACKAGE="inithooks"
BT_ARCHIVE_PIN=1001
# And the package path itself, in two steps, neither of which needs a version
# newer than the image to exist. Requiring one would mean either inventing a
# release or shipping the image deliberately stale so the archive is always
# ahead, and both would be lies told to make a test pass.
#
# Both steps stay inside our own archive on purpose. The CI runner has no IPv4
# route out (docs/releases-host.md section 7), so Debian's mirrors are
# unreachable from a container there while ours, being IPv6, is not: a step
# that needed a package from Debian would be testing the runner's network
# rather than the appliance. keel-transition, for instance, depends on gpgv,
# which a Debian 13 appliance does not carry because apt verifies with sqv.
#
# A project package the image has NOT got, fetched from the archive. apt
# checks the download against the digest in the signed index, so this is the
# signature reaching a real file and not only an index.
BT_FETCH_PACKAGE="keel-transition"
# And a project package the image has, reinstalled, which downloads it again
# and runs dpkg on it: the installation half of the same path.
BT_INSTALL_PACKAGE="keel-archive-keyring"

bt_usage() {
    cat <<USAGE
usage: tests/boot-test.sh APPLIANCE [options]

Assembles the layer chain of APPLIANCE (wordpress) into an LXC rootfs, boots
it headless from tests/instance.yaml, waits for the first boot to finish, and
then proves, in this order:

  the site answers 200 over IPv6 on port 80 and on port 443
  the answer is a WordPress site and not the WordPress installer
  wp-config.php names the local database and carries no build time password
  the wordpress database and the wordpress database account exist
  the administrator logs in over HTTP with the declared app_password, and a
    wrong password is refused
  apt-get update against $BT_ARCHIVE_URI verifies its signature
  apt-cache policy shows $BT_POLICY_PACKAGE coming from that archive, at the
    priority the appliance's own pin file sets
  apt-get download fetches $BT_FETCH_PACKAGE, which the image has not got,
    from that archive and against the digest the signed index carries
  apt-get install --reinstall $BT_INSTALL_PACKAGE downloads it again and runs
    dpkg on it, so the whole path is exercised
  keel diff reports no drift

Root only.

options:
  --timeout SECONDS     give up after this long per wait (default $BT_DEFAULT_TIMEOUT)
  --interval SECONDS    poll interval (default $BT_DEFAULT_INTERVAL)
  --bridge NAME         bridge the container joins (default $BT_DEFAULT_BRIDGE)
  --layers-dir DIR|URL  where the layers are published: a directory, or an
                        http(s) URL such as https://mirror.keellinux.org/layers
                        (default $BT_DEFAULT_LAYERS_DIR)
  --cache-dir DIR       keel layer cache (default $BT_DEFAULT_CACHE_DIR)
  --lxc-path DIR        lxcpath for the test container (default $BT_DEFAULT_LXC_PATH)
  --name NAME           container name (default keel-APPLIANCE-boot-test)
  --spec FILE           instance spec (default tests/instance.yaml)
  --skip-update         do not run the three APT proofs (a host with no
                        outbound network)
  --keep                leave the container running for inspection
  -h, --help            this text
USAGE
}

bt_is_positive_int() {
    [[ ${1-} =~ ^[1-9][0-9]*$ ]]
}

bt_is_appliance_name() {
    # The name bt-layer and the workflow use: no keel- prefix, lower case.
    [[ ${1-} =~ ^[a-z][a-z0-9-]*$ ]] && [[ $1 != keel-* ]]
}

bt_container_name() {
    printf 'keel-%s-boot-test\n' "$1"
}

bt_is_container_name() {
    # What LXC accepts and what the CI cleanup command allows: lower case
    # letters, digits, dot and dash, starting with a letter or a digit.
    [[ ${1-} =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

# Sets BT_APPLIANCE, BT_TIMEOUT, BT_INTERVAL, BT_BRIDGE, BT_LAYERS_DIR,
# BT_CACHE_DIR, BT_LXC_PATH, BT_SPEC, BT_KEEP, BT_SKIP_UPDATE, BT_NAME and
# BT_ROOTFS. Returns 0 when parsed, 2 after printing the usage, 1 on a bad
# argument (message on stderr).
bt_parse_args() {
    BT_APPLIANCE=""
    BT_TIMEOUT=$BT_DEFAULT_TIMEOUT
    BT_INTERVAL=$BT_DEFAULT_INTERVAL
    BT_BRIDGE=$BT_DEFAULT_BRIDGE
    BT_LAYERS_DIR=$BT_DEFAULT_LAYERS_DIR
    BT_CACHE_DIR=$BT_DEFAULT_CACHE_DIR
    BT_LXC_PATH=$BT_DEFAULT_LXC_PATH
    BT_NAME=""
    BT_SPEC=""
    BT_KEEP=0
    BT_SKIP_UPDATE=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout|--interval)
                bt_is_positive_int "${2-}" || {
                    echo "boot-test: $1 needs a positive number of seconds" >&2
                    return 1
                }
                [ "$1" = --timeout ] && BT_TIMEOUT=$2 || BT_INTERVAL=$2
                shift
                ;;
            --bridge|--layers-dir|--cache-dir|--lxc-path|--name|--spec)
                [ -n "${2-}" ] || {
                    echo "boot-test: $1 needs a value" >&2
                    return 1
                }
                case "$1" in
                    --bridge) BT_BRIDGE=$2 ;;
                    --layers-dir) BT_LAYERS_DIR=$2 ;;
                    --cache-dir) BT_CACHE_DIR=$2 ;;
                    --lxc-path) BT_LXC_PATH=$2 ;;
                    --name) BT_NAME=$2 ;;
                    --spec) BT_SPEC=$2 ;;
                esac
                shift
                ;;
            --keep) BT_KEEP=1 ;;
            --skip-update) BT_SKIP_UPDATE=1 ;;
            -h|--help)
                bt_usage
                return 2
                ;;
            -*)
                echo "boot-test: unknown option $1" >&2
                return 1
                ;;
            *)
                if [ -n "$BT_APPLIANCE" ]; then
                    echo "boot-test: one appliance at a time ($BT_APPLIANCE, $1)" >&2
                    return 1
                fi
                BT_APPLIANCE=$1
                ;;
        esac
        shift
    done
    if [ -z "$BT_APPLIANCE" ]; then
        echo "boot-test: APPLIANCE is required (core, wordpress, ...)" >&2
        return 1
    fi
    if ! bt_is_appliance_name "$BT_APPLIANCE"; then
        echo "boot-test: '$BT_APPLIANCE' is not an appliance name (lower case, no keel- prefix)" >&2
        return 1
    fi
    BT_NAME=${BT_NAME:-$(bt_container_name "$BT_APPLIANCE")}
    if ! bt_is_container_name "$BT_NAME"; then
        echo "boot-test: '$BT_NAME' is not a container name (lower case, digits, dot, dash)" >&2
        return 1
    fi
    BT_ROOTFS=$BT_LXC_PATH/$BT_NAME/rootfs
    return 0
}

bt_is_global_ipv6() {
    # Global unicast, which includes ULA (fc00::/7); not link local
    # (fe80::/10), loopback or multicast. IPv4 has no colon.
    local addr=${1,,}
    [[ $addr == *:* ]] || return 1
    [[ $addr == fe[89ab]?:* ]] && return 1
    [[ $addr == ::1 ]] && return 1
    [[ $addr == ff* ]] && return 1
    return 0
}

bt_global_ipv6() {
    # stdin: the output of lxc-info -i ("IP:  ADDRESS" per line). Prints the
    # first global IPv6 address; returns 1 when there is none yet.
    local label addr _
    while read -r label addr _; do
        [ "$label" = "IP:" ] || continue
        if bt_is_global_ipv6 "$addr"; then
            printf '%s\n' "$addr"
            return 0
        fi
    done
    return 1
}

bt_container_ipv6() {
    # bt_container_ipv6 NAME LXCPATH: the container's first global IPv6.
    lxc-info -P "$2" -n "$1" -i 2>/dev/null | bt_global_ipv6
}

bt_now() {
    ${BT_CLOCK:-date +%s}
}

bt_deadline_passed() {
    # bt_deadline_passed START TIMEOUT NOW
    [ $(( $3 - $1 )) -ge "$2" ]
}

bt_wait_for() {
    # bt_wait_for TIMEOUT INTERVAL DESCRIPTION COMMAND [ARGS...]
    # Runs COMMAND until it succeeds; returns 1 once TIMEOUT seconds passed.
    local timeout=$1 interval=$2 what=$3 start now
    shift 3
    start=$(bt_now)
    until "$@"; do
        now=$(bt_now)
        if bt_deadline_passed "$start" "$timeout" "$now"; then
            echo "boot-test: timeout after ${timeout}s waiting for $what" >&2
            return 1
        fi
        ${BT_SLEEP:-sleep} "$interval"
    done
}

bt_is_ssh_banner() {
    [[ ${1-} == SSH-2.0-* ]]
}

bt_firstboot_done_in() {
    # bt_firstboot_done_in FILE: FILE is the rootfs copy of
    # /etc/default/inithooks; 98finalize sets RUN_FIRSTBOOT=false at the end.
    [ -r "$1" ] && grep -q '^RUN_FIRSTBOOT=false' "$1"
}

bt_lxc_config() {
    # bt_lxc_config NAME ROOTFS BRIDGE: an LXC config for a plain rootfs
    # directory on a bridge; the address comes from the bridge (SLAAC or
    # DHCPv6), the spec declares managed_by: host.
    #
    # The apparmor pair is not decoration. Under the stock container profile a
    # unit that asks systemd for a mount namespace is refused, and both
    # mariadb.service and apache2.service ask: they fail with
    # status=226/NAMESPACE, so the first boot never reaches the database and
    # the site never starts. A generated profile with nesting allowed is what
    # a container running systemd needs, and it is what the appliance
    # containers on the build host have carried all along.
    cat <<CONFIG
lxc.uts.name = $1
lxc.rootfs.path = dir:$2
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = amd64
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
lxc.net.0.type = veth
lxc.net.0.link = $3
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.start.auto = 0
CONFIG
}

bt_mark_container() {
    # bt_mark_container ROOTFS: make the tree look like the container build
    # buildtasks produces, which is two things, both from its
    # patches/container/conf:
    #
    #   the marker under /var/lib/turnkey-info, which inithooks' unit
    #   conditions read and which `keel inspect` reads to call the machine a
    #   container (network.managed_by: host), and
    #
    #   REDIRECT_OUTPUT=true in /etc/default/inithooks, which sends first boot
    #   output to the log with a tail on the active console instead of writing
    #   it straight to tty1,
    #
    # and a drop-in that keeps the first boot off tty1.
    #
    # The last two are not cosmetic. The layer ships the plain appliance
    # inithooks.service, which runs the hooks with StandardOutput=tty on
    # /dev/tty1; the unit a container image gets instead logs to syslog and
    # the console. Nothing reads tty1 in a container nobody has attached to,
    # so a hook that prints more than the terminal buffer holds blocks in the
    # write and never returns. keel-nodebb met that as a first boot that never
    # came back, and the database appliances met it again the next day.
    local rootfs=$1 defaults=$1/$BT_INITHOOKS_DEFAULT
    install -D -m 0644 /dev/null "$rootfs/$BT_CONTAINER_MARKER" || return 1
    if [ ! -f "$defaults" ]; then
        echo "boot-test: $defaults is not in the rootfs" >&2
        return 1
    fi
    sed -i '/REDIRECT_OUTPUT/ s/=.*/=true/' "$defaults" || return 1
    if ! grep -q '^REDIRECT_OUTPUT=true$' "$defaults"; then
        echo "boot-test: $defaults declares no REDIRECT_OUTPUT to set" >&2
        return 1
    fi
    install -D -m 0644 /dev/stdin "$rootfs/$BT_INITHOOKS_DROPIN" <<DROPIN || return 1
[Service]
StandardOutput=journal
StandardError=journal
DROPIN
}

bt_spec_targets() {
    # bt_spec_targets ROOTFS: the paths the spec is installed at.
    local relative
    for relative in $BT_SPEC_PATHS; do
        printf '%s/%s\n' "$1" "$relative"
    done
}

bt_spec_in_rootfs() {
    # bt_spec_in_rootfs SPEC ROOTFS: the spec with its secret references
    # pointed inside ROOTFS, printed on stdout. `keel spec apply` runs on the
    # host and resolves a secret path against the host, so the copy it reads
    # has to name the files this test wrote into the container.
    sed -E "s#^([[:space:]]*file:[[:space:]]*)(/etc/keel/secrets/)#\1$2\2#" "$1"
}

bt_random_password() {
    # A fixed block is read first and filtered afterwards. The other way
    # round, "tr < source | head -c N", leaves tr killed by SIGPIPE when head
    # has its N characters, and the set -o pipefail of boot-test.sh turns that
    # into exit 141 before the container is ever started.
    local pool source=${BT_RANDOM_SOURCE:-/dev/urandom}
    pool=$(head -c "$BT_RANDOM_BYTES" "$source" | LC_ALL=C tr -dc 'A-Za-z0-9')
    if [ "${#pool}" -lt "$BT_PASSWORD_LENGTH" ]; then
        echo "boot-test: $source gave only ${#pool} usable characters" >&2
        return 1
    fi
    printf '%s\n' "${pool:0:BT_PASSWORD_LENGTH}"
}

bt_secret_targets() {
    # bt_secret_targets ROOTFS: the secret files the spec references.
    local name
    for name in $BT_SECRETS; do
        printf '%s/etc/keel/secrets/%s\n' "$1" "$name"
    done
}

bt_page_title() {
    # bt_page_title FILE: the text of the first <title> element, empty when
    # the page has none.
    tr -d '\n' < "$1" | grep -o '<title>[^<]*</title>' | head -1 \
        | sed -e 's|<title>||' -e 's|</title>||'
}

bt_http_verdict() {
    # bt_http_verdict PORT CODE TITLE: the site answered when the status is
    # 200 and the page carries a title. A redirect is not accepted on either
    # port: this appliance serves the site on both, and a 301 to a recorded
    # site URL is exactly the defect wp-config.php exists to avoid.
    if [ "${2-}" != 200 ]; then
        echo "boot-test: port $1 answered ${2-}, not 200" >&2
        return 1
    fi
    if [ -z "${3-}" ]; then
        echo "boot-test: the page on port $1 has no title element" >&2
        return 1
    fi
    echo "boot-test: port $1 answered 200, title '$3'"
}

bt_installer_verdict() {
    # bt_installer_verdict FILE: the page must not be the WordPress installer
    # or its "there is no wp-config.php" screen. Those are what an appliance
    # that left the installation to the visitor answers, and the whole point
    # of this recipe is that nobody is ever offered them.
    local page=$1 marker
    for marker in 'wp-admin/install.php' 'setup-config.php' \
        'WordPress &rsaquo; Installation' 'WordPress &rsaquo; Setup Configuration File'; do
        if grep -qF "$marker" "$page"; then
            echo "boot-test: the site is offering the WordPress installer ($marker)" >&2
            return 1
        fi
    done
    if ! grep -qE 'wp-(content|includes)/' "$page"; then
        echo "boot-test: the page carries nothing a WordPress site would serve" >&2
        return 1
    fi
    echo "boot-test: the installer is not offered and the page is a WordPress site"
}

bt_config_verdict() {
    # bt_config_verdict FILE APP_DB_USER DB_NAME: wp-config.php names the
    # local database and this appliance's account, and carries none of the
    # values upstream's build time installation left in it.
    local config=$1 db_user=$2 db_name=$3 field
    for field in DB_NAME DB_USER DB_PASSWORD DB_HOST; do
        grep -qE "^define\('$field'," "$config" \
            || { echo "boot-test: wp-config.php has no $field" >&2; return 1; }
    done
    grep -qE "^define\('DB_NAME', *'$db_name'\);" "$config" \
        || { echo "boot-test: wp-config.php does not name the database '$db_name'" >&2; return 1; }
    grep -qE "^define\('DB_USER', *'$db_user'\);" "$config" \
        || { echo "boot-test: wp-config.php does not name the account '$db_user'" >&2; return 1; }
    grep -qE "^define\('DB_HOST', *'(\[::1\]|127\.0\.0\.1|localhost)'\);" "$config" \
        || { echo "boot-test: wp-config.php does not point at the local database" >&2; return 1; }
    if grep -qE "^define\('DB_PASSWORD', *'(turnkey|)'\);" "$config"; then
        echo "boot-test: wp-config.php carries the upstream build time password" >&2
        return 1
    fi
    echo "boot-test: wp-config.php names '$db_name' as '$db_user' on the local database"
}

bt_password_in_config() {
    # bt_password_in_config FILE PASS: true when the declared password is the
    # one wp-config.php carries. The password is compared in the shell, so it
    # never becomes an argument of grep, which every process on the machine
    # could read while it ran.
    local config=$1 pass=$2 line
    line=$(sed -n "s|^define('DB_PASSWORD', '\\(.*\\)');\$|\\1|p" "$config" | head -1)
    [ -n "$line" ] || return 1
    [ "$line" = "$pass" ]
}

bt_login_verdict() {
    # bt_login_verdict CODE COOKIEJAR: what a real login looks like. WordPress
    # answers a 302 to the dashboard and sets a wordpress_logged_in_ cookie;
    # a refused login answers 200 and sets none. Fetching the login form
    # proves nothing, which is why this test posts to it.
    local code=$1 jar=$2
    case "$code" in
        200)
            echo "boot-test: wp-login.php answered 200, which is the form again: the login was refused" >&2
            return 1
            ;;
        30[1278]) ;;
        *)
            echo "boot-test: wp-login.php answered $code" >&2
            return 1
            ;;
    esac
    if ! grep -q 'wordpress_logged_in_' "$jar"; then
        echo "boot-test: no wordpress_logged_in_ cookie came back from the login" >&2
        return 1
    fi
    echo "boot-test: the login was accepted and set a wordpress_logged_in_ cookie"
}

bt_refused_login_verdict() {
    # bt_refused_login_verdict CODE JAR: a wrong password must be refused. A
    # check that only ever tries the right password cannot tell a working
    # login from a site that lets anybody in.
    local code=$1 jar=$2
    if [ "$code" != 200 ]; then
        echo "boot-test: a wrong password got $code, not the login form again" >&2
        return 1
    fi
    if grep -q 'wordpress_logged_in_' "$jar"; then
        echo "boot-test: a wrong password was given a wordpress_logged_in_ cookie" >&2
        return 1
    fi
    echo "boot-test: a wrong password was refused"
}

bt_dashboard_verdict() {
    # bt_dashboard_verdict CODE FILE: with the login cookie, /wp-admin/
    # answers 200 and the page is the dashboard rather than the login form.
    local code=$1 page=$2
    if [ "$code" != 200 ]; then
        echo "boot-test: /wp-admin/ answered $code with the login cookie" >&2
        return 1
    fi
    if grep -qF 'loginform' "$page"; then
        echo "boot-test: /wp-admin/ served the login form, so the cookie was not accepted" >&2
        return 1
    fi
    if ! grep -qE 'wp-admin|adminmenu|Dashboard' "$page"; then
        echo "boot-test: /wp-admin/ served something that is not the dashboard" >&2
        return 1
    fi
    echo "boot-test: /wp-admin/ answered 200 with the dashboard for the logged in admin"
}

bt_sources_verdict() {
    # bt_sources_verdict FILE: the appliance's own APT source, as it ships:
    # enabled, the signed distribution, our keyring, and never a staging one.
    local sources=$1 field value
    while read -r field value; do
        case "$field" in
            Enabled:) [ "$value" = yes ] || {
                echo "boot-test: $sources is not enabled" >&2; return 1; } ;;
            URIs:) [ "$value" = "$BT_ARCHIVE_URI" ] || {
                echo "boot-test: $sources names '$value', not $BT_ARCHIVE_URI" >&2; return 1; } ;;
            Suites:) [ "$value" = "$BT_ARCHIVE_SUITE" ] || {
                echo "boot-test: $sources names the suite '$value', not $BT_ARCHIVE_SUITE" >&2; return 1; } ;;
            Signed-By:) [ "$value" = "$BT_ARCHIVE_KEYRING" ] || {
                echo "boot-test: $sources is signed by '$value', not $BT_ARCHIVE_KEYRING" >&2; return 1; } ;;
        esac
    done < "$sources"
    echo "boot-test: $BT_ARCHIVE_URI $BT_ARCHIVE_SUITE is enabled and verified with $BT_ARCHIVE_KEYRING"
}

bt_apt_update_verdict() {
    # bt_apt_update_verdict CODE FILE: apt-get update must succeed and must
    # have verified a signature. apt says nothing when a signature is good, so
    # what is checked is that it fetched our archive and said nothing bad
    # about it: any of the words below means it could not verify, and apt
    # prints them while still exiting 0 in some configurations.
    local code=$1 output=$2 complaint
    if [ "$code" != 0 ]; then
        echo "boot-test: apt-get update exited $code" >&2
        return 1
    fi
    for complaint in NO_PUBKEY 'is not signed' 'no longer has a Release file' \
        'not have a Release file' EXPKEYSIG REVKEYSIG BADSIG \
        'insufficiently signed' 'cannot be authenticated'; do
        if grep -qF "$complaint" "$output"; then
            echo "boot-test: apt could not verify the archive ($complaint)" >&2
            return 1
        fi
    done
    if ! grep -qF "$BT_ARCHIVE_URI" "$output"; then
        echo "boot-test: apt-get update never reached $BT_ARCHIVE_URI" >&2
        return 1
    fi
    echo "boot-test: apt-get update read $BT_ARCHIVE_URI $BT_ARCHIVE_SUITE and verified its signature"
}

bt_policy_verdict() {
    # bt_policy_verdict PACKAGE FILE: FILE is "apt-cache policy PACKAGE" from
    # inside the appliance. Our archive has to be a source apt knows, at the
    # priority the appliance's own /etc/apt/preferences.d/keel sets, and the
    # candidate has to be the version that source offers. That is what "this
    # machine takes its project packages from Keel" means, and it is true
    # whether or not a newer version happens to exist today.
    local package=$1 file=$2 candidate
    candidate=$(awk '$1 == "Candidate:" { print $2; exit }' "$file")
    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
        echo "boot-test: apt has no candidate for $package" >&2
        return 1
    fi
    if ! awk -v pin="$BT_ARCHIVE_PIN" -v uri="$BT_ARCHIVE_URI" \
        '$1 == pin && $2 == uri { found = 1 } END { exit !found }' "$file"; then
        echo "boot-test: $BT_ARCHIVE_URI is not a source of $package at priority $BT_ARCHIVE_PIN" >&2
        return 1
    fi
    if ! awk -v version="$candidate" -v pin="$BT_ARCHIVE_PIN" \
        '$1 == version && $2 == pin { found = 1 } END { exit !found }' "$file"; then
        echo "boot-test: the candidate $package $candidate does not come from" \
            "$BT_ARCHIVE_URI at priority $BT_ARCHIVE_PIN" >&2
        return 1
    fi
    echo "boot-test: apt takes $package from $BT_ARCHIVE_URI at priority" \
        "$BT_ARCHIVE_PIN, candidate $candidate"
}

bt_absent_verdict() {
    # bt_absent_verdict PACKAGE STATUS: the package must not be installed
    # before the install proof, or the proof is about nothing.
    local package=$1 status=${2-}
    case "$status" in
        *"install ok installed")
            echo "boot-test: $package is already installed ('$status'), so installing" \
                "it from the archive would prove nothing" >&2
            return 1
            ;;
    esac
    echo "boot-test: $package is not in the image, which is what makes the next step a proof"
}

bt_download_verdict() {
    # bt_download_verdict PACKAGE CODE SIZE OUTPUT: apt fetched the package
    # from our archive, and the file it left is SIZE bytes. apt checks a
    # download against the digest the signed index carries and refuses an
    # archive it cannot verify before it asks for a single byte, so a file
    # that arrives this way is a file the signature covers.
    #
    # The size is measured inside the container and passed in, not read from
    # the rootfs here: apt writes into a tmpfs the host does not see through
    # the rootfs directory, so a check on a host path would fail on a download
    # that worked.
    local package=$1 code=$2 size=$3 output=$4
    if [ "$code" != 0 ]; then
        echo "boot-test: apt-get download $package exited $code" >&2
        return 1
    fi
    if ! awk -v uri="$BT_ARCHIVE_URI" -v pkg="$package" \
        '/^Get:/ && index($0, uri) && index($0, pkg) { found = 1 } END { exit !found }' "$output"; then
        echo "boot-test: apt did not fetch $package from $BT_ARCHIVE_URI" >&2
        return 1
    fi
    if [ -z "$size" ] || [ "$size" -le 0 ] 2>/dev/null; then
        echo "boot-test: apt-get download $package left no file (size '${size:-none}')" >&2
        return 1
    fi
    echo "boot-test: the $package archive is $size bytes"
    echo "boot-test: apt fetched $package from $BT_ARCHIVE_URI, against the digest of the signed index"
}

bt_install_verdict() {
    # bt_install_verdict PACKAGE CODE VERSION STATUS FILE: the package was
    # fetched from our archive, installed, and dpkg has it configured. apt
    # refuses an unverifiable archive before it downloads anything, so a
    # successful fetch from our URI is the signature check passing on the
    # bytes that were actually installed, not only on an index.
    local package=$1 code=$2 version=$3 status=$4 file=$5
    if [ "$code" != 0 ]; then
        echo "boot-test: apt-get install --reinstall $package exited $code" >&2
        return 1
    fi
    if ! awk -v uri="$BT_ARCHIVE_URI" -v pkg="$package" \
        '/^Get:/ && index($0, uri) && index($0, pkg) { found = 1 } END { exit !found }' "$file"; then
        echo "boot-test: apt did not fetch $package from $BT_ARCHIVE_URI" >&2
        return 1
    fi
    if [ -z "$version" ]; then
        echo "boot-test: $package has no version after the install" >&2
        return 1
    fi
    if [ "$status" != "install ok installed" ]; then
        echo "boot-test: $package is '$status' after the install, not 'install ok installed'" >&2
        return 1
    fi
    echo "boot-test: apt fetched and reinstalled $package $version from $BT_ARCHIVE_URI, dpkg configured"
}

bt_diff_verdict() {
    # bt_diff_verdict CODE: interprets the exit code of keel diff
    # (docs/diff.md of the keel repository). 0 and 13 mean no drift.
    case "$1" in
        0) echo "keel diff: no drift"; return 0 ;;
        13) echo "keel diff: no drift, but a declared field could not be observed offline (see the report above)"; return 0 ;;
        14) echo "keel diff: drift found" >&2; return 1 ;;
        2|3) echo "keel diff: the spec is unreadable or invalid (exit $1)" >&2; return 1 ;;
        *) echo "keel diff: failed with exit $1" >&2; return 1 ;;
    esac
}
