#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/firstboot.d/40wordpress, the first
# boot hook, executed for real against scratch directories.
#
# Everything it touches is a stub first in PATH (systemctl, mysqladmin, mysql,
# php, wp, chown, openssl) writing a line per call into a log the tests read,
# and INITHOOKS_PATH is a scratch tree whose lib is a symlink to the real
# library, so kcov measures the file the appliance ships. No test needs root, a
# database, a web server or a network.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    HOOK="$REPO/overlay/usr/lib/inithooks/firstboot.d/40wordpress"
    SCRATCH="$BATS_TEST_TMPDIR"
    CALLS="$SCRATCH/calls"
    : > "$CALLS"

    # the inithooks tree the hook reads itself from. Each file of the library
    # is a symlink to the real one, so kcov measures the file the appliance
    # ships; console.sh is inithooks' own and is a stand-in (_console).
    IH="$SCRATCH/inithooks"
    mkdir -p "$IH/bin" "$IH/lib"
    local lib
    for lib in "$REPO"/overlay/usr/lib/inithooks/lib/*; do
        ln -s "$(cd "$(dirname "$lib")" && pwd)/$(basename "$lib")" "$IH/lib/"
    done
    _console deferred
    unset INITHOOKS_UNATTENDED

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
    # its database. A call with no --execute reads its statements from
    # standard input, and they go to a file of their own, not to the log.
    STDIN_SQL="$SCRATCH/stdin.sql"
    cat > "$STUBS/mysql" <<EOF
#!/bin/bash
echo "mysql \$*" >> "$CALLS"
case "\$*" in
    *--execute*) ;;
    *)
        cat >> "$STDIN_SQL"
        [ -n "\${WP_TEST_ACCOUNT_FAILS:-}" ] && exit 1
        exit 0
        ;;
esac
case "\$*" in *--user*) [ -n "\${WP_TEST_DB_REFUSES:-}" ] && exit 1 ;; esac
case "\$*" in
    *read_only*) echo \${WP_TEST_READ_ONLY:-0}; exit 0 ;;
    *"CREATE DATABASE"*) [ -n "\${WP_TEST_CREATE_FAILS:-}" ] && exit 1; exit 0 ;;
esac
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
if [ "\$first" = eval-file ]; then
    if [ "\${WP_TEST_FAIL_EVAL:-}" = both ]; then exit 1; fi
    if [ "\${WP_TEST_FAIL_EVAL:-}" = auth ]; then
        case "\$*" in *verify-login*) exit 1 ;; esac
    fi
fi
exit 0
EOF
    chmod +x "$STUBS/wp"
    PATH="$STUBS:$PATH"
    export PATH INITHOOKS_DEFAULT="$DEFAULTS" WORDPRESS_ROOT="$WPROOT"
    export WORDPRESS_CONFIG="$WPROOT/wp-config.php"
    # no spec: a standalone machine, which is what the role guard reads
    export WORDPRESS_SPEC="$SCRATCH/instance.yaml"
    export WORDPRESS_READY="$SCRATCH/ready"
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

# _console deferred|skipped: inithooks' lib/console.sh, as the hook relies on
# it. console_unattended answers from INITHOOKS_UNATTENDED alone, the answer
# run exports; the real rule is inithooks' and is measured there. "deferred"
# is a library with console_deferred, which also records the hook so that
# the first login starts keel-init; "skipped" is an older library with
# console_skipped only.
_console() {
    {
        cat <<'LIB'
console_unattended() {
    [[ -n "${INITHOOKS_UNATTENDED:-}" && "$INITHOOKS_UNATTENDED" != no ]]
}
console_skipped() {
    echo "[$1] not asked, nobody can answer ($INITHOOKS_UNATTENDED): $2" >&2
}
LIB
        if [[ "$1" == deferred ]]; then
            cat <<LIB
console_deferred() {
    console_skipped "\$@"
    echo "\$1" >> "$SCRATCH/deferred"
}
LIB
        fi
    } > "$IH/lib/console.sh"
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
    run ! grep -q "turnkey" "$WPROOT/wp-config.php"
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

@test "the declared password is set and then authenticated through wp eval-file" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -c -- " eval-file " "$CALLS"
    [ "$output" = "2" ]
    grep -q "wordpress-set-password.php" "$CALLS"
    grep -q "wordpress-verify-login.php" "$CALLS"
}

@test "the database is started and waited for before anything is written" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -n "systemctl start mariadb.service" "$CALLS"
    [ "$status" -eq 0 ]
    run grep -n "mysqladmin ping" "$CALLS"
    [ "$status" -eq 0 ]
}

@test "nginx is started at the end, and never restarted: its site is static" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "systemctl start nginx.service" "$CALLS"
    run grep -c "systemctl restart" "$CALLS"
    [ "$output" = "0" ]
}

@test "the schema is made before the account is asked whether it reaches it" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    create=$(grep -n "CREATE DATABASE IF NOT EXISTS \`wordpress\`" "$CALLS" | head -1 | cut -d: -f1)
    reach=$(grep -n "information_schema.schemata" "$CALLS" | head -1 | cut -d: -f1)
    [ -n "$create" ]
    [ -n "$reach" ]
    [ "$create" -lt "$reach" ]
}

@test "the permalinks are the post name once the site is installed" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -qF "rewrite structure /%postname%/" "$CALLS"
    inst=$(grep -n -- "core install" "$CALLS" | head -1 | cut -d: -f1)
    rw=$(grep -n "rewrite structure" "$CALLS" | head -1 | cut -d: -f1)
    [ "$inst" -lt "$rw" ]
}

@test "an installed site keeps the permalinks its owner chose" {
    export WP_TEST_INSTALLED=1
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -c "rewrite structure" "$CALLS"
    [ "$output" = "0" ]
}

@test "a permalink structure that cannot be set is fatal" {
    export WP_TEST_FAIL=rewrite
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot set the permalink structure"* ]]
}

@test "a schema that cannot be created is fatal and names the statement" {
    export WP_TEST_CREATE_FAILS=1
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot create the database 'wordpress'"* ]]
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

# Whether anybody can answer the dialog is inithooks' rule (lib/console.sh),
# as for lnmp's 35mysqlpass. The hook used to test its own standard input for
# a terminal, and tty1 of an LXC container is a terminal nobody is attached
# to: a headless first boot drew the password box there, got no answer and
# failed (BR2, 2026-11-05). Now the hook asks nothing, records that it is
# deferred, and the first login starts keel-init, which asks the values.

@test "a headless boot with no passwords defers the hook and says which fields to declare" {
    : > "$CONF"
    export INITHOOKS_UNATTENDED="the console has no size, nobody is attached to it"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[40wordpress] not asked, nobody can answer (the console has no size"* ]]
    [[ "$output" == *"APP_PASS"* ]]
    [[ "$output" == *"DB_PASS"* ]]
    [[ "$output" == *"secrets.app_password"* ]]
    [[ "$output" == *"secrets.db_password"* ]]
    [[ "$output" == *"keel-init"* ]]
    [ "$(cat "$SCRATCH/deferred")" = 40wordpress ]
}

@test "a deferred hook writes nothing, starts nothing and leaves the site closed (503)" {
    : > "$CONF"
    export INITHOOKS_UNATTENDED="there is no terminal"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -e "$WPROOT/wp-config.php" ]
    [ ! -e "$WORDPRESS_READY" ]
    run grep -cE "wordpress.py|^mysql|^wp |systemctl start" "$CALLS"
    [ "$output" = "0" ]
}

@test "an inithooks without console_deferred gets the line of console_skipped" {
    : > "$CONF"
    _console skipped
    export INITHOOKS_UNATTENDED="there is no terminal"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[40wordpress] not asked, nobody can answer (there is no terminal)"* ]]
    [ ! -e "$SCRATCH/deferred" ]
    [ ! -e "$WORDPRESS_READY" ]
}

@test "a headless boot with one password declared still defers for the other" {
    _conf "APP_PASS=''"
    export INITHOOKS_UNATTENDED="there is no terminal"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no APP_PASS in"* ]]
    [ ! -e "$WORDPRESS_READY" ]
}

@test "a description that declares everything needs nobody at the console" {
    export INITHOOKS_UNATTENDED="there is no terminal"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -e "$SCRATCH/deferred" ]
    [ -f "$WORDPRESS_READY" ]
}

@test "with somebody at the console the dialog is asked for each value and the boot goes on" {
    : > "$CONF"
    export INITHOOKS_UNATTENDED=no
    # script gives the hook a pty, as keel-init at a console does. The stub
    # answers on stdout, which the hook reads, so the evidence that it was
    # called is in the call log.
    run script -qec "bash '$HOOK'" /dev/null
    [ "$status" -eq 0 ]
    run grep "wordpress.py" "$CALLS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APP_PASS"* ]]
    [[ "$output" == *"DB_PASS"* ]]
    # and what the dialog answered is what reached wp-config.php
    grep -q "define('DB_PASSWORD', 'asked-DB_PASS');" "$WPROOT/wp-config.php"
}

@test "a dialog that answers nothing is fatal rather than installing without a password" {
    : > "$CONF"
    cat > "$IH/bin/wordpress.py" <<EOF
#!/bin/bash
echo "wordpress.py \$*" >> "$CALLS"
EOF
    chmod +x "$IH/bin/wordpress.py"
    export INITHOOKS_UNATTENDED=no
    run script -qec "bash '$HOOK'" /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"no password given"* ]]
    [ ! -e "$WORDPRESS_READY" ]
}

@test "somebody at the console: the hook asks whatever its standard input is, as run found a console" {
    : > "$CONF"
    export INITHOOKS_UNATTENDED=no
    run bash "$HOOK" < /dev/null
    [ "$status" -eq 0 ]
    grep -q "wordpress.py APP_PASS DB_PASS" "$CALLS"
}

@test "a missing conf file is not fatal on its own" {
    rm -f "$CONF"
    export INITHOOKS_UNATTENDED="there is no terminal"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[40wordpress] not asked"* ]]
}

# --- the database account ----------------------------------------------------
# 40wordpress gives its own account its password, through the root socket.
# Under keel-init the inithooks conf is empty (98finalize blanked it), so
# lnmp's 35mysqlpass sets its account 'admin' and not 'wordpress', and the
# check below failed on BR2 (2026-11-05) with the site left at 503.

@test "the account gets the declared password on its three hosts, by standard input" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -qxF "ALTER USER 'wordpress'@'localhost' IDENTIFIED BY 'declared-db-password';" "$STDIN_SQL"
    grep -qxF "ALTER USER 'wordpress'@'::1' IDENTIFIED BY 'declared-db-password';" "$STDIN_SQL"
    grep -qxF "CREATE USER IF NOT EXISTS 'wordpress'@'127.0.0.1' IDENTIFIED BY 'declared-db-password';" "$STDIN_SQL"
    # never on a command line: the call log holds every argument of mysql
    run grep -c "declared-db-password" "$CALLS"
    [ "$output" = "0" ]
}

@test "the account has its password before it is granted the schema and asked to reach it" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    account=$(grep -n "^mysql --batch$" "$CALLS" | head -1 | cut -d: -f1)
    grant=$(grep -n "GRANT ALL PRIVILEGES" "$CALLS" | head -1 | cut -d: -f1)
    create=$(grep -n "CREATE DATABASE" "$CALLS" | head -1 | cut -d: -f1)
    [ -n "$account" ]
    [ "$create" -lt "$account" ]
    [ "$account" -lt "$grant" ]
}

@test "the keel-init path: an empty conf, the values asked, the account set with the asked password" {
    : > "$CONF"
    export INITHOOKS_UNATTENDED=no
    run bash "$HOOK" < /dev/null
    [ "$status" -eq 0 ]
    grep -qxF "ALTER USER 'wordpress'@'localhost' IDENTIFIED BY 'asked-DB_PASS';" "$STDIN_SQL"
    grep -q "define('DB_PASSWORD', 'asked-DB_PASS');" "$WPROOT/wp-config.php"
    [ -f "$WORDPRESS_READY" ]
}

@test "a password with a quote and a backslash is escaped for SQL and kept as it is for PHP" {
    _conf "DB_PASS='it'\\''s\\x'"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -qxF "ALTER USER 'wordpress'@'localhost' IDENTIFIED BY 'it\\'s\\\\x';" "$STDIN_SQL"
    grep -qF "define('DB_PASSWORD', 'it\\'s\\\\x');" "$WPROOT/wp-config.php"
}

@test "another account name is created and granted the schema" {
    _conf "APP_DB_USER='blog'"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -qxF "CREATE USER IF NOT EXISTS 'blog'@'localhost' IDENTIFIED BY 'declared-db-password';" "$STDIN_SQL"
    grep -q "TO 'blog'@'localhost'" "$CALLS"
}

@test "an account the server will not change is fatal, before wp-config.php" {
    export WP_TEST_ACCOUNT_FAILS=1
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot give 'wordpress' its password"* ]]
    [ ! -e "$WPROOT/wp-config.php" ]
    [ ! -e "$WORDPRESS_READY" ]
}

@test "a replica does not touch the account: it comes with the copy of the primary" {
    _replica_spec
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -e "$STDIN_SQL" ]
}

# --- the database refusing ---------------------------------------------------

@test "a database that refuses the declared password is fatal" {
    export WP_TEST_DB_REFUSES=1
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot reach the database"* ]]
    [[ "$output" != *"35mysqlpass"* ]]
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
case "\$*" in *"start nginx"*) exit 1 ;; esac
exit 0
EOF
    chmod +x "$SCRATCH/bin/systemctl"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nginx did not start"* ]]
}

@test "the log says how long each password was and never what it was" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"(20 characters)"* ]]
    [[ "$output" != *"declared-app-password"* ]]
    [[ "$output" != *"declared-db-password"* ]]
}

# --- a replica ---------------------------------------------------------------
# The database of a replica comes from the primary, with the copy that seeds
# it. A schema or a site made here would be a local database that keel's seed
# refuses to replace without --destroy-local-database, and a write the
# primary never saw.

_replica_spec() {
    printf 'database:\n  server:\n    engine: mariadb\n    role: replica\n' > "$WORDPRESS_SPEC"
}

@test "a replica by the spec gets wp-config.php and nothing in the database" {
    _replica_spec
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"wp-config.php written"* ]]
    [[ "$output" == *"replica"* ]]
    grep -q "define('DB_PASSWORD', 'declared-db-password');" "$WPROOT/wp-config.php"
    run grep -cE "CREATE DATABASE|core install|rewrite structure|eval-file|option update|information_schema" "$CALLS"
    [ "$output" = "0" ]
}

@test "a replica by the spec still has nginx started" {
    _replica_spec
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "systemctl start nginx.service" "$CALLS"
}

@test "a server that is read only is a replica, with or without a spec" {
    export WP_TEST_READ_ONLY=1
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"replica"* ]]
    run grep -cE "CREATE DATABASE|core install" "$CALLS"
    [ "$output" = "0" ]
}

@test "a replica needs no administrator password in the description" {
    _replica_spec
    _conf "APP_PASS=''"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ -e "$WPROOT/wp-config.php" ]
}

@test "a replica still needs the database password, the same as the pair's primary" {
    _replica_spec
    _conf "DB_PASS=''"
    export INITHOOKS_UNATTENDED="there is no terminal"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no DB_PASS in"* ]]
    [ ! -e "$WPROOT/wp-config.php" ]
    [ ! -e "$WORDPRESS_READY" ]
}

@test "a replica that has a wp-config.php keeps it" {
    _replica_spec
    printf '%s\n' "<?php /* mine */" > "$WPROOT/wp-config.php"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"wp-config.php written"* ]]
    grep -q "mine" "$WPROOT/wp-config.php"
}

@test "a primary by the spec installs the site" {
    printf 'database:\n  server:\n    engine: mariadb\n    role: primary\n' > "$WORDPRESS_SPEC"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WordPress installed"* ]]
}

# --- the media library -------------------------------------------------------
# wp-cli runs as root in the hook (wp --allow-root), and WordPress makes the
# directory of the month in wp-content/uploads when it installs. Left to
# root, that directory refuses every upload of the web user: the REST API
# answers "could not be moved to wp-content/uploads/2026/10" (found by the
# upload test of Keel-Linux/keel-web#15).

@test "the uploads tree belongs to the web user once the site is installed, before the web server starts" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    local chown_line option_line start_line
    chown_line="$(grep -n "^chown -R $WORDPRESS_WEB_USER:$WORDPRESS_WEB_USER $WPROOT/wp-content/uploads\$" "$CALLS" | head -1 | cut -d: -f1)"
    option_line="$(grep -n "^wp .*option update admin_email" "$CALLS" | head -1 | cut -d: -f1)"
    start_line="$(grep -n "^systemctl start nginx.service" "$CALLS" | head -1 | cut -d: -f1)"
    [ -n "$chown_line" ]
    [ "$chown_line" -gt "$option_line" ]
    [ "$chown_line" -lt "$start_line" ]
}

@test "an installed site gets the same owner for the uploads tree when the hook runs again" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    : > "$CALLS"
    WP_TEST_INSTALLED=1 run bash "$HOOK"
    [ "$status" -eq 0 ]
    grep -q "^chown -R $WORDPRESS_WEB_USER:$WORDPRESS_WEB_USER $WPROOT/wp-content/uploads\$" "$CALLS"
}

@test "a node that lacks a replicated directory gets it, owned by the web user (keel-wordpress#30)" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    for dir in uploads themes plugins languages; do
        [ -d "$WPROOT/wp-content/$dir" ]
        grep -q "^chown $WORDPRESS_WEB_USER:$WORDPRESS_WEB_USER $WPROOT/wp-content/$dir\$" "$CALLS"
    done
}

@test "a replica gets the replicated directories too, before the web server starts" {
    _replica_spec
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ -d "$WPROOT/wp-content/languages" ]
    grep -q "^chown $WORDPRESS_WEB_USER:$WORDPRESS_WEB_USER $WPROOT/wp-content/languages\$" "$CALLS"
}

@test "a replicated directory that exists is left alone" {
    mkdir -p "$WPROOT/wp-content/languages"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -c "wp-content/languages" "$CALLS"
    [ "$output" = 0 ]
}

@test "a replica does not touch the uploads tree" {
    _replica_spec
    mkdir -p "$WPROOT/wp-content/uploads"
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    run grep -c "wp-content/uploads" "$CALLS"
    [ "$output" = 0 ]
}

# --- the site is closed until the hook is done --------------------------------
# nginx may be up before the first boot ends. Until the marker exists the
# route answers 503, so nobody reaches the WordPress installer in the window
# between wp-config.php and the end of the installation.

@test "the ready marker is written at the end of an installation" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ -f "$WORDPRESS_READY" ]
    [ "$(stat -c %a "$WORDPRESS_READY")" = 644 ]
}

@test "the ready marker is written on a replica too" {
    _replica_spec
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [ -f "$WORDPRESS_READY" ]
}

@test "no ready marker when the installation fails" {
    export WP_TEST_FAIL=core
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [ ! -e "$WORDPRESS_READY" ]
}

@test "the ready marker is written after the password was authenticated" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"authenticated against the site itself"* ]]
    [ -f "$WORDPRESS_READY" ]
}

@test "the account is granted the schema on every host before it is asked to reach it" {
    run bash "$HOOK"
    [ "$status" -eq 0 ]
    grant=$(grep -n "GRANT ALL PRIVILEGES ON \`wordpress\`" "$CALLS" | head -1 | cut -d: -f1)
    reach=$(grep -n "information_schema.schemata" "$CALLS" | head -1 | cut -d: -f1)
    [ -n "$grant" ]
    [ "$grant" -lt "$reach" ]
}

@test "a spec that cannot be read stops the hook before it writes anything" {
    printf 'database: [unclosed\n' > "$WORDPRESS_SPEC"
    run bash "$HOOK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read database.server.role"* ]]
    run grep -cE "CREATE DATABASE|core install" "$CALLS"
    [ "$output" = "0" ]
    [ ! -e "$WPROOT/wp-config.php" ]
}
