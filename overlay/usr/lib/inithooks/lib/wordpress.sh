#!/bin/bash
# Logic behind firstboot.d/40wordpress (decision 0004: logic apart from
# effect). Meant to be sourced. Every function reads its inputs from its
# arguments, prints its result on stdout and returns non-zero instead of
# exiting, so the hook decides what is fatal and a test can exercise every
# branch without a database, a web server, a network or root.
#
# No function here puts a secret on the command line of another process. The
# two that handle one, wordpress_config_php and wordpress_masked, are shell
# functions: their arguments never reach the argv of anything else.

WORDPRESS_ROOT="${WORDPRESS_ROOT:-/var/www/wordpress}"
WORDPRESS_CONFIG="${WORDPRESS_CONFIG:-$WORDPRESS_ROOT/wp-config.php}"
WORDPRESS_WEB_USER="${WORDPRESS_WEB_USER:-www-data}"
# The database this appliance owns. app.options.db_user names the account
# that lnmp's 35mysqlpass gives the MariaDB password; the site itself logs in
# as the web user over the socket (wordpress_socket_account_sql).
WORDPRESS_DB_NAME="${WORDPRESS_DB_NAME:-wordpress}"
WORDPRESS_DB_USER="${WORDPRESS_DB_USER:-wordpress}"
WORDPRESS_DB_PREFIX="${WORDPRESS_DB_PREFIX:-wp_}"
# The site logs in over the socket (localhost): the web user with no password
# (unix_socket), and wp-cli as root as the root account of the same socket.
WORDPRESS_DB_HOST="${WORDPRESS_DB_HOST:-localhost}"
WORDPRESS_DB_LOGIN="${WORDPRESS_DB_LOGIN:-www-data}"
WORDPRESS_ADMIN_USER="${WORDPRESS_ADMIN_USER:-admin}"
WORDPRESS_SITE_TITLE="${WORDPRESS_SITE_TITLE:-WordPress}"
WORDPRESS_ADMIN_EMAIL="${WORDPRESS_ADMIN_EMAIL:-admin@example.com}"
# Only used when nothing declares a domain and no request is being served:
# wp-config.php derives the real one from the Host header.
WORDPRESS_FALLBACK_URL="${WORDPRESS_FALLBACK_URL:-http://localhost}"
WORDPRESS_DB_SERVICE="${WORDPRESS_DB_SERVICE:-mariadb}"
WORDPRESS_WEB_SERVICE="${WORDPRESS_WEB_SERVICE:-nginx}"
# The instance description, which says whether this node is a replica
# (database.server.role), and the permalink structure of a new site. nginx
# serves a pretty permalink with try_files, so no .htaccess is needed.
WORDPRESS_SPEC="${WORDPRESS_SPEC:-/etc/keel/instance.yaml}"
WORDPRESS_PERMALINKS="${WORDPRESS_PERMALINKS:-/%postname%/}"
# The marker that opens the site. nginx may be up before the first boot ends,
# so the route answers 503 until this file exists (60-keel-wordpress.conf),
# and nobody reaches the WordPress installer in the window between
# wp-config.php and the end of the installation. It is beside the WordPress
# tree and not in it, so an update of core never touches it.
WORDPRESS_READY="${WORDPRESS_READY:-/var/www/.keel-wordpress-ready}"
WORDPRESS_WAIT_TRIES="${WORDPRESS_WAIT_TRIES:-30}"
# The eight keys wp-config.php carries. WordPress asks its own API for them;
# a first boot must not need the internet, so they are generated here.
WORDPRESS_SALT_BYTES=48
# What a WordPress login may be here, and what a database identifier may be.
# Both are narrower than what the software accepts: a name that would need
# quoting is a name this appliance will not create.
WORDPRESS_LOGIN_RE='^[A-Za-z0-9._@+-]+$'
WORDPRESS_IDENT_RE='^[A-Za-z_][A-Za-z0-9_]*$'

# wordpress_first_value VALUE...: the first argument that is set and is not
# the inithooks placeholder DEFAULT; fails when there is none.
wordpress_first_value() {
    local value
    for value in "$@"; do
        if [[ -n "$value" && "${value^^}" != "DEFAULT" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

# wordpress_is_login NAME: true for a WordPress login this appliance creates
wordpress_is_login() {
    [[ -n "${1-}" ]] && [[ $1 =~ $WORDPRESS_LOGIN_RE ]]
}

# wordpress_is_ident NAME: true for a database name, account or table prefix
# this appliance will interpolate into a statement unquoted
wordpress_is_ident() {
    [[ -n "${1-}" ]] && [[ $1 =~ $WORDPRESS_IDENT_RE ]]
}

# wordpress_admin_user [APP_ADMIN_USER]: the WordPress account the declared
# app_password belongs to.
wordpress_admin_user() {
    local name
    name=$(wordpress_first_value "${1-}" "$WORDPRESS_ADMIN_USER") || return 1
    wordpress_is_login "$name" || return 1
    printf '%s\n' "$name"
}

# wordpress_db_user [APP_DB_USER]: the database account wp-config.php uses.
# The same field the parent layer reads, so one declaration serves both.
wordpress_db_user() {
    local name
    name=$(wordpress_first_value "${1-}" "$WORDPRESS_DB_USER") || return 1
    wordpress_is_ident "$name" || return 1
    printf '%s\n' "$name"
}

# wordpress_db_name [APP_DB_NAME]: the database WordPress owns
wordpress_db_name() {
    local name
    name=$(wordpress_first_value "${1-}" "$WORDPRESS_DB_NAME") || return 1
    wordpress_is_ident "$name" || return 1
    printf '%s\n' "$name"
}

# wordpress_db_prefix [APP_DB_PREFIX]: the table prefix. A value that is not
# an identifier is refused rather than escaped, because it is interpolated
# into every query WordPress makes.
wordpress_db_prefix() {
    local prefix
    prefix=$(wordpress_first_value "${1-}" "$WORDPRESS_DB_PREFIX") || return 1
    wordpress_is_ident "$prefix" || return 1
    printf '%s\n' "$prefix"
}

# wordpress_site_title [APP_SITE_TITLE]: the title the installer would have
# asked for. Anything non empty is accepted; it is content, not an
# identifier, and it never reaches a statement unquoted.
wordpress_site_title() {
    wordpress_first_value "${1-}" "$WORDPRESS_SITE_TITLE"
}

# wordpress_admin_email [APP_EMAIL]: the address of that account
wordpress_admin_email() {
    local address
    address=$(wordpress_first_value "${1-}" "$WORDPRESS_ADMIN_EMAIL") || return 1
    [[ $address == *@*.* || $address == *@localhost ]] || return 1
    [[ $address != *[[:space:]]* ]] || return 1
    printf '%s\n' "$address"
}

# wordpress_site_url [APP_DOMAIN]: the URL recorded in the database at
# install time. A domain with no scheme is https, which is how an appliance
# that terminates TLS itself should be reached; an empty value falls back to
# WORDPRESS_FALLBACK_URL. What is actually served is decided per request by
# wp-config.php from the Host header, so this value only matters to WP-CLI
# and to wp-cron.
wordpress_site_url() {
    local value
    if ! value=$(wordpress_first_value "${1-}"); then
        printf '%s\n' "$WORDPRESS_FALLBACK_URL"
        return 0
    fi
    [[ $value != *[[:space:]]* ]] || return 1
    case "$value" in
        http://|https://) return 1 ;;
        http://*|https://*) ;;
        *://*) return 1 ;;
        *) value="https://$value" ;;
    esac
    printf '%s\n' "$value"
}

# wordpress_missing_values APP_PASS [ROLE]: the names of the values that need
# a prompt, one per line. Empty output means the instance description carried
# everything, which is the headless case the boot test proves. A replica
# installs nothing, so it needs no administrator password: the administrator
# is a row that comes with the copy of the primary. The site logs in over the
# socket, so no database password is asked.
wordpress_missing_values() {
    [[ -n "${1-}" || "${2-}" == replica ]] || echo APP_PASS
    return 0
}

# wordpress_spec_role [SPEC]: database.server.role of the instance
# description, or nothing when the file is missing or declares no role. A
# machine with no spec has no pair. A spec that exists and cannot be read as
# a mapping is an error and not "no role": a replica would then make a schema
# and a site of its own.
wordpress_spec_role() {
    local spec=${1:-$WORDPRESS_SPEC}
    [[ -e "$spec" ]] || return 0
    python3 - "$spec" <<'PY'
import sys, yaml

def mapping(value, name):
    if value is None:
        return {}
    if not isinstance(value, dict):
        sys.exit("%s is not a mapping" % name)
    return value

spec = mapping(yaml.safe_load(open(sys.argv[1])), "the spec")
server = mapping(mapping(spec.get("database"), "database").get("server"), "database.server")
print(server.get("role") or "")
PY
}

# wordpress_is_replica ROLE READ_ONLY: true when this node must write
# nothing to the database. The role is what the description declares and
# READ_ONLY is @@global.read_only of the server, so a node that is already a
# replica is one even when the description is gone.
wordpress_is_replica() {
    local role=${1-} read_only=${2-}
    [[ "$role" == replica ]] && return 0
    case "${read_only^^}" in
        1|ON) return 0 ;;
    esac
    return 1
}

# wordpress_socket_account_sql NAME: the statements that give the web user
# its socket account (unix_socket, no password) and the schema. The two
# nodes of a cloud pair then need no password that each must know: the seed
# of a replica copies the account with the rest of the primary (decision of
# 2026-11-06). CREATE IF NOT EXISTS and GRANT do nothing the second time.
wordpress_socket_account_sql() {
    wordpress_is_ident "${1-}" || return 1
    printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED VIA unix_socket;\n" "$WORDPRESS_DB_LOGIN"
    printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'localhost';\n" "$1" "$WORDPRESS_DB_LOGIN"
}

# wordpress_create_database_sql NAME: the statement that makes the schema.
# It is made at the first boot of a primary or a standalone node and not in
# the image: keel counts a schema that is not the server's own as a local
# database, and refuses to replace it with the copy of the primary.
wordpress_create_database_sql() {
    wordpress_is_ident "${1-}" || return 1
    printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$1"
}

# wordpress_masked PASS: what a log may show of a password
wordpress_masked() {
    if [[ -z "${1-}" ]]; then
        echo "(none)"
    else
        echo "(${#1} characters)"
    fi
}

# wordpress_php_string VALUE: VALUE as a single quoted PHP string literal.
# Only a backslash and a single quote mean anything inside one.
wordpress_php_string() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//\'/\\\'}
    printf "'%s'" "$value"
}

# wordpress_config_php DB_NAME DB_HOST DB_PREFIX SITE_URL:
# the whole of wp-config.php on stdout.
#
# Two things in it are the appliance's own and not WordPress's defaults.
#
# WP_HOME and WP_SITEURL are derived from the Host header of the request
# instead of being read from the database. An appliance does not know its own
# address when its layer is built, and a WordPress whose recorded site URL is
# not the one it is reached by answers a permanent redirect to the recorded
# one: a machine reached by its IPv6 literal would send the visitor to a name
# that does not resolve. Deriving it per request means the site answers on
# whatever address or name reaches it, and the recorded value is only the
# fallback for WP-CLI and wp-cron, which carry no Host header.
#
# HTTPS is set to on when the scheme worked out is https. FORCE_SSL_ADMIN is
# true for an https site URL, and is_ssl() reads HTTPS only, so behind Anubis
# (X-Forwarded-Proto, a unix socket, no HTTPS variable) wp-login.php would
# redirect to itself for ever.
#
# DISABLE_WP_CRON with /etc/cron.d/wordpress-cron, so scheduled work does not
# depend on somebody visiting the site; and automatic core updates off,
# because core here is root owned and updated by a person (README.rst).
wordpress_config_php() {
    local db_name=${1-} db_host=${2-} db_prefix=${3-} site_url=${4-}
    wordpress_is_ident "$db_name" || return 1
    wordpress_is_ident "$db_prefix" || return 1
    [[ -n "$db_host" ]] || return 1
    [[ -n "$site_url" ]] || return 1
    cat <<HEADER
<?php
/**
 * WordPress configuration of a Keel Linux appliance.
 *
 * Written by /usr/lib/inithooks/firstboot.d/40wordpress on the first boot
 * from the instance description in /etc/keel/instance.yaml. It holds no
 * secret: the site logs in over the socket of MariaDB with no password, as
 * the web user (wp-cli as root logs in as root), and the salts are options of
 * the database. On a cloud pair keel seeds that database to the replica and
 * replicates it, so both nodes have the same salts and a login cookie of one
 * opens on the other (decision of 2026-11-06).
 *
 * To write it again: remove this file and run the hook.
 */

define('DB_NAME', $(wordpress_php_string "$db_name"));
define('DB_USER', (function_exists('posix_geteuid') && posix_geteuid() === 0) ? 'root' : $(wordpress_php_string "$WORDPRESS_DB_LOGIN"));
define('DB_PASSWORD', '');
define('DB_HOST', $(wordpress_php_string "$db_host"));
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

HEADER
    cat <<FOOTER

\$table_prefix = $(wordpress_php_string "$db_prefix");

define('WP_DEBUG', false);
define('FS_METHOD', 'direct');
define('DISABLE_WP_CRON', true);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
/* The admin and login pages link their styles and scripts as files of
   wp-admin and wp-includes, never through load-styles.php or
   load-scripts.php (CVE-2018-6389). */
define('CONCATENATE_SCRIPTS', false);

/* The address this appliance is reached by, decided per request. */
define('KEEL_WP_FALLBACK_URL', $(wordpress_php_string "$site_url"));
if (!empty(\$_SERVER['HTTP_HOST'])) {
    \$keel_wp_scheme = 'http';
    if ((!empty(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] !== 'off')
        || (isset(\$_SERVER['SERVER_PORT']) && (int) \$_SERVER['SERVER_PORT'] === 443)
        || (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO'])
            && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https')) {
        \$keel_wp_scheme = 'https';
    }
    /* is_ssl() of WordPress reads HTTPS and nothing else. Behind Anubis the
       request comes from a unix socket with X-Forwarded-Proto, so say it. */
    if (\$keel_wp_scheme === 'https') {
        \$_SERVER['HTTPS'] = 'on';
    }
    define('WP_HOME', \$keel_wp_scheme . '://' . \$_SERVER['HTTP_HOST']);
} else {
    define('WP_HOME', KEEL_WP_FALLBACK_URL);
}
define('WP_SITEURL', WP_HOME);

/* WP-CLI reaches into WordPress with no request to read a host from. */
if (defined('WP_CLI') && WP_CLI && empty(\$_SERVER['HTTP_HOST'])) {
    \$_SERVER['HTTP_HOST'] = parse_url(KEEL_WP_FALLBACK_URL, PHP_URL_HOST);
}

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
FOOTER
}

# wordpress_wait_ready COMMAND TRIES: run COMMAND until it succeeds, once a
# second, up to TRIES times. COMMAND is given so a test can pass its own.
wordpress_wait_ready() {
    local command=$1 tries=$2 attempt=1
    while [ "$attempt" -le "$tries" ]; do
        if $command >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        ${WORDPRESS_SLEEP:-sleep} 1
    done
    return 1
}

# wordpress_install_args URL TITLE USER EMAIL: the argument list for
# "wp core install", one per line. The administrator's real password is not
# among them: it is set afterwards from the environment, because an argument
# is readable by any process on the machine while the command runs.
wordpress_install_args() {
    local url=${1-} title=${2-} user=${3-} email=${4-}
    [[ -n "$url" ]] || return 1
    [[ -n "$title" ]] || return 1
    wordpress_is_login "$user" || return 1
    [[ -n "$email" ]] || return 1
    printf '%s\n' "core" "install" "--url=$url" "--title=$title" \
        "--admin_user=$user" "--admin_email=$email" "--skip-email"
}
