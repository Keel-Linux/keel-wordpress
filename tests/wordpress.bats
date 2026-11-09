#!/usr/bin/env bats
# Unit tests of overlay/usr/lib/inithooks/lib/wordpress.sh, the logic behind
# the first boot hook 40wordpress. No root, no database, no web server, no
# network: every function takes its inputs as arguments and prints its result.

setup() {
    LIB="$BATS_TEST_DIRNAME/../overlay/usr/lib/inithooks/lib/wordpress.sh"
    # A salt source with no entropy in it, so wp-config.php is comparable
    # between runs and the tests say nothing about randomness.
    WORDPRESS_RANDOM="echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    export WORDPRESS_RANDOM
    # shellcheck source=../overlay/usr/lib/inithooks/lib/wordpress.sh
    source "$LIB"
}

# --- wordpress_first_value ---------------------------------------------------

@test "first_value takes the first value that is set" {
    run wordpress_first_value "" "second" "third"
    [ "$status" -eq 0 ]
    [ "$output" = "second" ]
}

@test "first_value skips the inithooks DEFAULT placeholder in any case" {
    run wordpress_first_value "DEFAULT" "default" "real"
    [ "$status" -eq 0 ]
    [ "$output" = "real" ]
}

@test "first_value fails when nothing is set" {
    run wordpress_first_value "" ""
    [ "$status" -ne 0 ]
}

# --- names -------------------------------------------------------------------

@test "admin_user falls back to admin" {
    run wordpress_admin_user ""
    [ "$status" -eq 0 ]
    [ "$output" = "admin" ]
}

@test "admin_user takes APP_ADMIN_USER" {
    run wordpress_admin_user "editor.one"
    [ "$status" -eq 0 ]
    [ "$output" = "editor.one" ]
}

@test "admin_user accepts an email shaped login" {
    run wordpress_admin_user "admin@example.org"
    [ "$status" -eq 0 ]
}

@test "admin_user refuses a login with a space in it" {
    run wordpress_admin_user "two words"
    [ "$status" -ne 0 ]
}

@test "admin_user refuses a login carrying a quote" {
    run wordpress_admin_user "ad'min"
    [ "$status" -ne 0 ]
}

@test "db_user falls back to wordpress and takes APP_DB_USER" {
    run wordpress_db_user ""
    [ "$output" = "wordpress" ]
    run wordpress_db_user "wp_site"
    [ "$output" = "wp_site" ]
}

@test "db_user refuses a name that would need quoting" {
    run wordpress_db_user "wp-site"
    [ "$status" -ne 0 ]
    run wordpress_db_user "1site"
    [ "$status" -ne 0 ]
    run wordpress_db_user 'wp;DROP'
    [ "$status" -ne 0 ]
}

@test "db_name falls back to wordpress and refuses a bad identifier" {
    run wordpress_db_name ""
    [ "$output" = "wordpress" ]
    run wordpress_db_name "blog"
    [ "$output" = "blog" ]
    run wordpress_db_name "blog db"
    [ "$status" -ne 0 ]
}

@test "db_prefix falls back to wp_ and refuses a bad prefix" {
    run wordpress_db_prefix ""
    [ "$output" = "wp_" ]
    run wordpress_db_prefix "site_"
    [ "$output" = "site_" ]
    run wordpress_db_prefix "1_"
    [ "$status" -ne 0 ]
    run wordpress_db_prefix "wp-"
    [ "$status" -ne 0 ]
}

@test "site_title falls back to WordPress and keeps spaces and accents" {
    run wordpress_site_title ""
    [ "$output" = "WordPress" ]
    run wordpress_site_title "Le journal de bord"
    [ "$output" = "Le journal de bord" ]
}

# --- email -------------------------------------------------------------------

@test "admin_email falls back and accepts a normal address" {
    run wordpress_admin_email ""
    [ "$output" = "admin@example.com" ]
    run wordpress_admin_email "me@keellinux.org"
    [ "$output" = "me@keellinux.org" ]
}

@test "admin_email accepts an address at localhost" {
    run wordpress_admin_email "root@localhost"
    [ "$status" -eq 0 ]
}

@test "admin_email refuses something that is not an address" {
    run wordpress_admin_email "not-an-address"
    [ "$status" -ne 0 ]
    run wordpress_admin_email "two words@example.org"
    [ "$status" -ne 0 ]
}

# --- site url ----------------------------------------------------------------

@test "site_url falls back when no domain is declared" {
    run wordpress_site_url ""
    [ "$status" -eq 0 ]
    [ "$output" = "http://localhost" ]
}

@test "site_url assumes https for a bare domain" {
    run wordpress_site_url "blog.example.org"
    [ "$output" = "https://blog.example.org" ]
}

@test "site_url keeps an explicit scheme" {
    run wordpress_site_url "http://blog.example.org"
    [ "$output" = "http://blog.example.org" ]
    run wordpress_site_url "https://blog.example.org"
    [ "$output" = "https://blog.example.org" ]
}

@test "site_url refuses another scheme, a bare scheme and whitespace" {
    run wordpress_site_url "ftp://blog.example.org"
    [ "$status" -ne 0 ]
    run wordpress_site_url "https://"
    [ "$status" -ne 0 ]
    run wordpress_site_url "blog example org"
    [ "$status" -ne 0 ]
}

# --- the values a headless boot needs ----------------------------------------

# The site logs in over the socket with no password (decision of
# 2026-11-06), so the only value a headless boot needs is the administrator's.
@test "missing_values is empty when the description carried the administrator password" {
    run wordpress_missing_values "app"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "missing_values names the administrator password, and never a database password" {
    run wordpress_missing_values ""
    [ "$output" = "APP_PASS" ]
    [[ "$output" != *DB_PASS* ]]
}

@test "masked says how long a password is and never what it is" {
    run wordpress_masked "hunter2hunter2"
    [ "$output" = "(14 characters)" ]
    [[ "$output" != *hunter* ]]
    run wordpress_masked ""
    [ "$output" = "(none)" ]
}

# --- PHP quoting and salts ---------------------------------------------------

@test "php_string quotes a plain value" {
    run wordpress_php_string "wordpress"
    [ "$output" = "'wordpress'" ]
}

@test "php_string escapes the backslash and the single quote" {
    run wordpress_php_string "a'b"
    [ "$output" = "'a\\'b'" ]
    run wordpress_php_string 'a\b'
    [ "$output" = "'a\\\\b'" ]
}

# --- wp-config.php -----------------------------------------------------------

# The two nodes of a cloud pair share what wp-config.php used to make on each
# machine (decision of 2026-11-06). The site logs in over the socket as the
# web user with no password; wp-cli as root logs in as root over the same
# socket. The salts are options of the database, which keel seeds to the
# replica and replicates, so a login cookie of one node opens on the other.
@test "config_php logs in over the socket, as root for root and as the web user otherwise, with no password" {
    run wordpress_config_php wordpress localhost wp_ "https://blog.example.org"
    [ "$status" -eq 0 ]
    [[ "$output" == *"define('DB_NAME', 'wordpress');"* ]]
    [[ "$output" == *"define('DB_USER', (function_exists('posix_geteuid') && posix_geteuid() === 0) ? 'root' : 'www-data');"* ]]
    [[ "$output" == *"define('DB_PASSWORD', '');"* ]]
    [[ "$output" == *"define('DB_HOST', 'localhost');"* ]]
    [[ "$output" == *"\$table_prefix = 'wp_';"* ]]
}

@test "config_php defines no salt: WordPress keeps them in its database" {
    run wordpress_config_php wordpress localhost wp_ "https://x.example.org"
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
        AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        [[ "$output" != *"'$key'"* ]]
    done
}

@test "config_php derives the served address from the Host header" {
    run wordpress_config_php wordpress localhost wp_ "https://x.example.org"
    [[ "$output" == *"HTTP_HOST"* ]]
    [[ "$output" == *"define('WP_SITEURL', WP_HOME);"* ]]
    [[ "$output" == *"define('KEEL_WP_FALLBACK_URL', 'https://x.example.org');"* ]]
}

@test "config_php tells PHP that the request is HTTPS when the scheme it works out is https" {
    # Behind Anubis the request reaches PHP-FPM from a unix socket with
    # X-Forwarded-Proto and no HTTPS variable. WordPress sets FORCE_SSL_ADMIN
    # from an https site URL and then redirects wp-login.php to itself for
    # ever, because is_ssl() reads $_SERVER['HTTPS'] only.
    run wordpress_config_php wordpress localhost wp_ "https://x.example.org"
    [[ "$output" == *"if (\$keel_wp_scheme === 'https') {"* ]]
    [[ "$output" == *"\$_SERVER['HTTPS'] = 'on';"* ]]
    # and it is set before the address that WordPress reads is defined
    set_line=$(grep -n "_SERVER\['HTTPS'\] = 'on'" <<< "$output" | head -1 | cut -d: -f1)
    home_line=$(grep -n "define('WP_HOME', \$keel_wp_scheme" <<< "$output" | head -1 | cut -d: -f1)
    [ -n "$set_line" ] && [ -n "$home_line" ]
    [ "$set_line" -lt "$home_line" ]
}

@test "config_php turns off the visitor driven cron and automatic core updates" {
    run wordpress_config_php wordpress localhost wp_ "https://x.example.org"
    [[ "$output" == *"define('DISABLE_WP_CRON', true);"* ]]
    [[ "$output" == *"define('AUTOMATIC_UPDATER_DISABLED', true);"* ]]
    [[ "$output" == *"define('WP_AUTO_UPDATE_CORE', false);"* ]]
}

@test "config_php has WordPress link its admin styles and scripts as files, not through load-styles.php" {
    # load-styles.php and load-scripts.php are PHP, a known load target
    # (CVE-2018-6389), and behind Anubis a PHP path gets the challenge.
    # With CONCATENATE_SCRIPTS false the login and admin pages link the
    # files of wp-admin and wp-includes, which Nginx serves from the disk.
    run wordpress_config_php wordpress localhost wp_ "https://x.example.org"
    [[ "$output" == *"define('CONCATENATE_SCRIPTS', false);"* ]]
}

@test "config_php refuses an empty host, prefix or url" {
    run wordpress_config_php wordpress "" wp_ "https://x"
    [ "$status" -ne 0 ]
    run wordpress_config_php wordpress localhost "" "https://x"
    [ "$status" -ne 0 ]
    run wordpress_config_php wordpress localhost wp_ ""
    [ "$status" -ne 0 ]
}

@test "config_php refuses a database name that needs quoting" {
    run wordpress_config_php "word press" localhost wp_ "https://x"
    [ "$status" -ne 0 ]
}

# --- waiting -----------------------------------------------------------------

@test "wait_ready returns as soon as the command succeeds" {
    run wordpress_wait_ready true 3
    [ "$status" -eq 0 ]
}

@test "wait_ready gives up after the given number of tries" {
    WORDPRESS_SLEEP=:
    run wordpress_wait_ready false 3
    [ "$status" -ne 0 ]
}

# --- the installation arguments ----------------------------------------------

@test "install_args carries the url, the title, the user and the address" {
    run wordpress_install_args "https://blog.example.org" "My Blog" admin me@example.org
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "core" ]
    [ "${lines[1]}" = "install" ]
    [ "${lines[2]}" = "--url=https://blog.example.org" ]
    [ "${lines[3]}" = "--title=My Blog" ]
    [ "${lines[4]}" = "--admin_user=admin" ]
    [ "${lines[5]}" = "--admin_email=me@example.org" ]
    [ "${lines[6]}" = "--skip-email" ]
}

@test "install_args never carries a password" {
    run wordpress_install_args "https://x" "T" admin me@example.org
    [[ "$output" != *"password"* ]]
    [[ "$output" != *"pass="* ]]
}

@test "install_args refuses an empty url, title or address and a bad login" {
    run wordpress_install_args "" "T" admin me@example.org
    [ "$status" -ne 0 ]
    run wordpress_install_args "https://x" "" admin me@example.org
    [ "$status" -ne 0 ]
    run wordpress_install_args "https://x" "T" "bad login" me@example.org
    [ "$status" -ne 0 ]
    run wordpress_install_args "https://x" "T" admin ""
    [ "$status" -ne 0 ]
}

# --- the role of the node, the schema and the permalinks ----------------------

@test "spec_role reads database.server.role from the spec" {
    printf 'database:\n  server:\n    role: replica\n' > "$BATS_TEST_TMPDIR/spec.yaml"
    run wordpress_spec_role "$BATS_TEST_TMPDIR/spec.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "replica" ]
}

@test "spec_role is empty for a spec with no database section" {
    printf 'instance:\n  hostname: wordpress\n' > "$BATS_TEST_TMPDIR/spec.yaml"
    run wordpress_spec_role "$BATS_TEST_TMPDIR/spec.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "spec_role is empty for a spec that is missing: a machine with no spec has no pair" {
    run wordpress_spec_role "$BATS_TEST_TMPDIR/none.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "spec_role fails for a spec that exists and cannot be read as a mapping" {
    # A role that cannot be read must not become "no role": a replica would
    # then make a schema and a site of its own.
    printf 'a: [unclosed\n' > "$BATS_TEST_TMPDIR/bad.yaml"
    run wordpress_spec_role "$BATS_TEST_TMPDIR/bad.yaml"
    [ "$status" -ne 0 ]
    printf -- '- a\n- b\n' > "$BATS_TEST_TMPDIR/list.yaml"
    run wordpress_spec_role "$BATS_TEST_TMPDIR/list.yaml"
    [ "$status" -ne 0 ]
    printf 'database:\n  - server\n' > "$BATS_TEST_TMPDIR/db.yaml"
    run wordpress_spec_role "$BATS_TEST_TMPDIR/db.yaml"
    [ "$status" -ne 0 ]
}

@test "is_replica is true for the role replica and for a server that is read only" {
    run wordpress_is_replica replica 0
    [ "$status" -eq 0 ]
    run wordpress_is_replica "" 1
    [ "$status" -eq 0 ]
    run wordpress_is_replica primary ON
    [ "$status" -eq 0 ]
}

@test "is_replica is false for a primary, a standalone server and a writable server" {
    run wordpress_is_replica primary 0
    [ "$status" -ne 0 ]
    run wordpress_is_replica "" 0
    [ "$status" -ne 0 ]
    run wordpress_is_replica "" OFF
    [ "$status" -ne 0 ]
}

@test "create_database_sql makes the schema with the character set of WordPress" {
    run wordpress_create_database_sql wordpress
    [ "$status" -eq 0 ]
    [ "$output" = 'CREATE DATABASE IF NOT EXISTS `wordpress` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' ]
}

@test "create_database_sql refuses a name that would need quoting" {
    run wordpress_create_database_sql 'word press'
    [ "$status" -ne 0 ]
    run wordpress_create_database_sql 'x`; DROP DATABASE mysql; --'
    [ "$status" -ne 0 ]
    run wordpress_create_database_sql ""
    [ "$status" -ne 0 ]
}

@test "missing_values does not ask a replica for the administrator password" {
    run wordpress_missing_values "" replica
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "the permalink structure is the post name" {
    [ "$WORDPRESS_PERMALINKS" = "/%postname%/" ]
}

@test "socket_account_sql: the web user over the socket, with no password, and its grant" {
    run wordpress_socket_account_sql site
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "CREATE USER IF NOT EXISTS 'www-data'@'localhost' IDENTIFIED VIA unix_socket;" ]
    [ "${lines[1]}" = "GRANT ALL PRIVILEGES ON \`site\`.* TO 'www-data'@'localhost';" ]
}

@test "socket_account_sql refuses a name that would need quoting" {
    run wordpress_socket_account_sql 'a b'
    [ "$status" -ne 0 ]
    run wordpress_socket_account_sql ""
    [ "$status" -ne 0 ]
}

@test "the ready marker is a file beside the WordPress tree, not in it" {
    [[ "$WORDPRESS_READY" == /var/www/.keel-wordpress-ready ]]
}
