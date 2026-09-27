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

@test "missing_values is empty when the description carried both" {
    run wordpress_missing_values "app" "db"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "missing_values names each absent value" {
    run wordpress_missing_values "" "db"
    [ "$output" = "APP_PASS" ]
    run wordpress_missing_values "app" ""
    [ "$output" = "DB_PASS" ]
    run wordpress_missing_values "" ""
    [ "${lines[0]}" = "APP_PASS" ]
    [ "${lines[1]}" = "DB_PASS" ]
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

@test "salt strips the characters that would end a PHP string" {
    WORDPRESS_RANDOM="printf %s \\\\'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop"
    run wordpress_salt
    [ "$status" -eq 0 ]
    [[ "$output" != *"'"* ]]
    [[ "$output" != *"\\"* ]]
}

@test "salt fails when the source gives too little" {
    WORDPRESS_RANDOM="echo short"
    run wordpress_salt
    [ "$status" -ne 0 ]
}

# --- wp-config.php -----------------------------------------------------------

@test "config_php names the database, the account, the password and the host" {
    run wordpress_config_php wordpress wpuser "s3cr3t" "[::1]" wp_ "https://blog.example.org"
    [ "$status" -eq 0 ]
    [[ "$output" == *"define('DB_NAME', 'wordpress');"* ]]
    [[ "$output" == *"define('DB_USER', 'wpuser');"* ]]
    [[ "$output" == *"define('DB_PASSWORD', 's3cr3t');"* ]]
    [[ "$output" == *"define('DB_HOST', '[::1]');"* ]]
    [[ "$output" == *"\$table_prefix = 'wp_';"* ]]
}

@test "config_php carries all eight salt keys" {
    run wordpress_config_php wordpress wpuser pass "[::1]" wp_ "https://x.example.org"
    for key in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
        AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        [[ "$output" == *"define('$key',"* ]]
    done
}

@test "config_php derives the served address from the Host header" {
    run wordpress_config_php wordpress wpuser pass "[::1]" wp_ "https://x.example.org"
    [[ "$output" == *"HTTP_HOST"* ]]
    [[ "$output" == *"define('WP_SITEURL', WP_HOME);"* ]]
    [[ "$output" == *"define('KEEL_WP_FALLBACK_URL', 'https://x.example.org');"* ]]
}

@test "config_php turns off the visitor driven cron and automatic core updates" {
    run wordpress_config_php wordpress wpuser pass "[::1]" wp_ "https://x.example.org"
    [[ "$output" == *"define('DISABLE_WP_CRON', true);"* ]]
    [[ "$output" == *"define('AUTOMATIC_UPDATER_DISABLED', true);"* ]]
    [[ "$output" == *"define('WP_AUTO_UPDATE_CORE', false);"* ]]
}

@test "config_php escapes a password that carries a quote" {
    run wordpress_config_php wordpress wpuser "pa'ss" "[::1]" wp_ "https://x.example.org"
    [ "$status" -eq 0 ]
    [[ "$output" == *"define('DB_PASSWORD', 'pa\\'ss');"* ]]
}

@test "config_php refuses an empty password, host, prefix or url" {
    run wordpress_config_php wordpress wpuser "" "[::1]" wp_ "https://x"
    [ "$status" -ne 0 ]
    run wordpress_config_php wordpress wpuser pass "" wp_ "https://x"
    [ "$status" -ne 0 ]
    run wordpress_config_php wordpress wpuser pass "[::1]" "" "https://x"
    [ "$status" -ne 0 ]
    run wordpress_config_php wordpress wpuser pass "[::1]" wp_ ""
    [ "$status" -ne 0 ]
}

@test "config_php refuses a database name or account that needs quoting" {
    run wordpress_config_php "word press" wpuser pass "[::1]" wp_ "https://x"
    [ "$status" -ne 0 ]
    run wordpress_config_php wordpress "wp-user" pass "[::1]" wp_ "https://x"
    [ "$status" -ne 0 ]
}

@test "config_php fails when the salt source fails" {
    WORDPRESS_RANDOM="false"
    run wordpress_config_php wordpress wpuser pass "[::1]" wp_ "https://x"
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
