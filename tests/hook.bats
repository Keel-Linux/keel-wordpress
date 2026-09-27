#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/firstboot.d/40wordpress, the first
# boot hook, executed for real against scratch directories.
#
# Everything it touches is a stub first in PATH (systemctl, mysqladmin, mysql,
# php, wp, chown, openssl) writing a line per call into a log the tests read,
# and INITHOOKS_PATH is a scratch tree whose lib is a symlink to the real
# library, so kcov measures the file the appliance ships. No test needs root, a
# database, a web server or a network.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    HOOK="$REPO/overlay/usr/lib/inithooks/firstboot.d/40wordpress"
    SCRATCH="$BATS_TEST_TMPDIR"
    CALLS="$SCRATCH/calls"
    : > "$CALLS"

    # the inithooks tree the hook reads itself from
    IH="$SCRATCH/inithooks"
    mkdir -p "$IH/bin"
    ln -s "$REPO/overlay/usr/lib/inithooks/lib" "$IH/lib"

    DEFAULTS="$SCRATCH/default-inithooks"
    CONF="$SCRATCH/inithooks.conf"
    cat > "$DEFAULTS" <<EOF
INITHOOKS_PATH=$IH
INITHOOKS_CONF=$CONF
RUN_FIRSTBOOT=true
REDIRECT_OUTPUT=true
EOF

    WPROOT="$SCRATCH/wordpress"
    mkdir -p "$WPROOT"

    # the dialog, which a headless run must never reach
    cat > "$IH/bin/wordpress.py" <<EOF
#!/bin/bash
echo "wordpress.py \$*" >> "$CALLS"
for name in "\$@"; do echo "\$name=asked-\$name"; done
EOF
    chmod +x "$IH/bin/wordpress.py"

    STUBS="$SCRATCH/bin"
    mkdir -p "$STUBS"
    _stub systemctl 0
    _stub chown 0
    _stub mysqladmin 0
    # openssl is only used for the throwaway password
    cat > "$STUBS/openssl" <<EOF
#!/bin/bash
echo "openssl \$*" >> "$CALLS"
echo throwaway-password
EOF
    chmod +x "$STUBS/openssl"
    # mysql: the schema count query answers 1, which means the account reached
    # its database
    cat > "$STUBS/mysql" <<EOF
#!/bin/bash
echo "mysql \$*" >> "$CALLS"
[ -n "\${WP_TEST_DB_REFUSES:-}" ] && exit 1
echo \${WP_TEST_DB_COUNT:-1}
EOF
    chmod +x "$STUBS/mysql"
    _stub php 0
    # wp: "core is-installed" decides the branch, everything else succeeds
    # unless a test says which subcommand must fail
    cat > "$STUBS/wp" <<EOF
#!/bin/bash
echo "wp \$*" >> "$CALLS"
for arg in "\$@"; do
    case "\$arg" in --allow-root|--path=*) continue ;; esac
    first=\$arg; break
done
if [ "\$first" = core ]; then
    case "\$*" in
        *"is-installed"*)
            [ -n "\${WP_TEST_INSTALLED:-}" ] && exit 0
            exit 1
            ;;
    esac
fi
[ "\${WP_TEST_FAIL:-}" = "\$first" ] && exit 1
if [ "\$first" = eval ]; then
    : \${WP_TEST_EVAL_SEEN:=0}
    if [ "\${WP_TEST_FAIL_EVAL:-}" = both ]; then exit 1; fi
    if [ "\${WP_TEST_FAIL_EVAL:-}" = auth ]; then
        case "\$*" in *wp_authenticate*) exit 1 ;; esac
    fi
fi
exit 0
EOF
    chmod +x "$STUBS/wp"
    PATH="$STUBS:$PATH"
    export PATH INITHOOKS_DEFAULT="$DEFAULTS" WORDPRESS_ROOT="$WPROOT"
    export WORDPRESS_CONFIG="$WPROOT/wp-config.php"
    # a salt source with no entropy, so the rendered file is comparable
    export WORDPRESS_RANDOM="echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    # the web user of the scratch tree is whoever is running the tests
    export WORDPRESS_WEB_USER="$(id -gn)"
    _conf
}

_stub() {
    cat > "$SCRATCH/bin/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "$CALLS"
exit ${2:-0}
EOF
    chmod +x "$SCRATCH/bin/$1"
}

# _conf [KEY=VALUE ...]: write the rendered inithooks conf, the declared values
# by default and whatever a test overrides.
_conf() {
    cat > "$CONF" <<EOF
APP_PASS='declared-app-password'
DB_PASS='declared-db-password'
APP_ADMIN_USER='admin'
APP_SITE_TITLE='A Keel Blog'
APP_EMAIL='admin@example.org'
APP_DB_USER='wordpress'
APP_DB_NAME='wordpress'
APP_DB_PREFIX='wp_'
EOF
    local pair
    for pair in "$@"; do printf '%s\n' "$pair" >> "$CONF"; done
}

# --- the headless happy path -------------------------------------------------

@test "a declared description installs WordPress with no dialog" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wp-config.php written"* ]]
    [[ "$output" == *"WordPress installed: 'A Keel Blog'"* ]]
    [[ "$output" == *"authenticated against the site itself"* ]]
    run grep -c "wordpress.py" "$CALLS"
    [ "$output" = "0" ]
}

@test "wp-config.php carries the declared database password and nothing built in" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "define('DB_PASSWORD', 'declared-db-password');" "$WPROOT/wp-config.php"
    grep -q "define('DB_NAME', 'wordpress');" "$WPROOT/wp-config.php"
    grep -q "define('DB_USER', 'wordpress');" "$WPROOT/wp-config.php"
    grep -q "define('DB_HOST', '\[::1\]');" "$WPROOT/wp-config.php"
    ! grep -q "turnkey" "$WPROOT/wp-config.php"
}

@test "the password never reaches the command line of wp core install" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -- "core install" "$CALLS"
    [ "$status" -eq 0 ]
    [[ "$output" != *"declared-app-password"* ]]
    [[ "$output" == *"--admin_password=throwaway-password"* ]]
    run grep -c "declared-app-password" "$CALLS"
    [ "$output" = "0" ]
}

@test "the declared password is set and then authenticated through wp eval" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -c -- " eval " "$CALLS"
    [ "$output" = "2" ]
    grep -q "wp_set_password" "$CALLS"
    grep -q "wp_authenticate" "$CALLS"
}

@test "the database is started and waited for before anything is written" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -n "systemctl start mariadb.service" "$CALLS"
    [ "$status" -eq 0 ]
    run grep -n "mysqladmin ping" "$CALLS"
    [ "$status" -eq 0 ]
}

@test "the web server is restarted at the end" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "systemctl restart apache2.service" "$CALLS"
}

@test "the rendered wp-config.php is checked as PHP before it is moved into place" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "^php -l" "$CALLS"
}

# --- the values, and what a bad one does -------------------------------------

@test "a login that would need quoting is refused before anything runs" {
    _conf "APP_ADMIN_USER='bad login'"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a WordPress login"* ]]
    [ ! -e "$WPROOT/wp-config.php" ]
}

@test "a value that is not an email address is refused" {
    _conf "APP_EMAIL='nonsense'"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"declare app.email"* ]]
}

@test "a domain with an unsupported scheme is refused" {
    _conf "APP_DOMAIN='ftp://blog.example.org'"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"declare app.domain"* ]]
}

@test "a database account, name or prefix that would need quoting is refused" {
    _conf "APP_DB_USER='wp-user'"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"database account name"* ]]
    _conf "APP_DB_NAME='word press'"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"database name"* ]]
    _conf "APP_DB_PREFIX='1_'"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"table prefix"* ]]
}

@test "a declared domain is what the installation records" {
    _conf "APP_DOMAIN='blog.example.org'"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -q -- "--url=https://blog.example.org" "$CALLS"
}

# --- nothing declared --------------------------------------------------------

@test "a headless boot with no passwords says which fields to declare" {
    : > "$CONF"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"APP_PASS"* ]]
    [[ "$output" == *"DB_PASS"* ]]
    [[ "$output" == *"secrets.app_password"* ]]
    [[ "$output" == *"secrets.db_password"* ]]
    [ ! -e "$WPROOT/wp-config.php" ]
}

@test "with a terminal the dialog is asked instead of failing" {
    : > "$CONF"
    run script -qec "bash '$HOOK'" /dev/null
    [[ "$output" == *"wordpress.py"* ]] || skip "no pty available in this environment"
    run grep "wordpress.py" "$CALLS"
    [[ "$output" == *"APP_PASS"* ]]
    [[ "$output" == *"DB_PASS"* ]]
}

@test "a missing conf file is not fatal on its own" {
    rm -f "$CONF"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no terminal to"* ]]
}

# --- the database refusing ---------------------------------------------------

@test "a database that refuses the declared password names the hook before it" {
    export WP_TEST_DB_REFUSES=1
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot reach the database"* ]]
    [[ "$output" == *"35mysqlpass"* ]]
    [ ! -e "$WPROOT/wp-config.php" ]
}

@test "a database with no such schema is refused" {
    export WP_TEST_DB_COUNT=0
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot reach the database 'wordpress'"* ]]
}

@test "a database that never answers is reported as such" {
    _stub mysqladmin 1
    export WORDPRESS_WAIT_TRIES=2 WORDPRESS_SLEEP=:
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not answer after 2 tries"* ]]
}

# --- running twice -----------------------------------------------------------

@test "an existing wp-config.php is not written again" {
    printf '%s\n' "<?php /* mine */" > "$WPROOT/wp-config.php"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"wp-config.php written"* ]]
    grep -q "mine" "$WPROOT/wp-config.php"
}

@test "an installed site is left alone" {
    export WP_TEST_INSTALLED=1
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed; leaving the site alone"* ]]
    run grep -c -- "core install " "$CALLS"
    [ "$output" = "0" ]
}

# --- the steps failing -------------------------------------------------------

@test "an unwritable wp-config.php is fatal and leaves nothing behind" {
    chmod 0500 "$WPROOT"
    run bash "$HOOK"
    chmod 0700 "$WPROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot write beside"* ]]
}

@test "a wp-config.php that is not valid PHP is fatal" {
    _stub php 1
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid PHP"* ]]
    [ ! -e "$WPROOT/wp-config.php" ]
}

@test "a failed installation is fatal" {
    export WP_TEST_FAIL=core
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wp core install failed"* ]]
}

@test "a password that cannot be set is fatal" {
    export WP_TEST_FAIL_EVAL=both
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot set the password"* ]]
}

@test "a password the site will not authenticate is fatal" {
    export WP_TEST_FAIL_EVAL=auth
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot authenticate with the declared secrets.app_password"* ]]
}

@test "an address that cannot be recorded is fatal" {
    export WP_TEST_FAIL=option
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot set the administrator address"* ]]
}

@test "a web server that will not start is fatal" {
    cat > "$SCRATCH/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$CALLS"
case "\$*" in *"restart apache2"*) exit 1 ;; esac
exit 0
EOF
    chmod +x "$SCRATCH/bin/systemctl"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"apache2 did not start"* ]]
}

@test "the log says how long each password was and never what it was" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(20 characters)"* ]]
    [[ "$output" != *"declared-app-password"* ]]
    [[ "$output" != *"declared-db-password"* ]]
}
