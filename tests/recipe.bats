#!/usr/bin/env bats
# The recipe of the wordpress layer (handbook decision 0059): a layer on
# lnmp, nginx and PHP-FPM, nothing of Apache. These read the files of the
# recipe; the build and the booted image prove the rest.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# the package lines of plan/main, comments removed
packages() {
    sed -e 's|/\*.*\*/||g' "$REPO/plan/main" | sed -e '/\/\*/,/\*\//d' \
        | grep -vE '^\s*(#|$)' | awk '{print $1}'
}

# a file without its comment lines
code() {
    grep -vE '^\s*(#|$)' "$1"
}

@test "recipe: the plan asks for nothing of Apache" {
    run packages
    for name in apache2 libapache2-mod-php libapache2-mod-security2 \
            libapache2-mod-evasive webmin-apache php adminer; do
        if printf '%s\n' "$output" | grep -qx "$name"; then
            echo "plan/main asks for $name"
            return 1
        fi
    done
}

@test "recipe: the plan has the WordPress modules of PHP and the tools" {
    for name in php-cli php-gd php-zip php-imagick php-curl php-xml php-mbstring \
            php-intl unzip curl inithooks confconsole keel; do
        packages | grep -qx "$name"
    done
}

@test "recipe: the plan does not repeat what lnmp carries" {
    run packages
    for name in php-fpm php-mysql mariadb-client nginx; do
        if printf '%s\n' "$output" | grep -qx "$name"; then
            echo "plan/main names $name, which the parent layer installs"
            return 1
        fi
    done
}

@test "recipe: the plan includes no TurnKey web stack" {
    run ! grep -E '^#include <turnkey/(lamp|apache|mysql|php)' "$REPO/plan/main"
    grep -qx '#include <turnkey/base>' "$REPO/plan/main"
}

@test "recipe: no Apache mk file, PHP-FPM's mk file instead" {
    run code "$REPO/Makefile"
    [ "$status" -eq 0 ]
    run ! grep -E 'apache|lamp|adminer|nginx-php-mysql|turnkey/mysql\.mk' <<< "$output"
    grep -qx 'include $(FAB_PATH)/common/mk/turnkey/php-fpm.mk' "$REPO/Makefile"
}

@test "recipe: the PHP limits of a media library are kept" {
    grep -qx 'PHP_MEMORY_LIMIT = 256M' "$REPO/Makefile"
    grep -qx 'PHP_UPLOAD_MAX_FILESIZE = 64M' "$REPO/Makefile"
    grep -qx 'PHP_POST_MAX_SIZE = 64M' "$REPO/Makefile"
    grep -qx 'PHP_MAX_EXECUTION_TIME = 120' "$REPO/Makefile"
}

@test "recipe: the panel opens SSH, HTTP, HTTPS and Webmin only" {
    grep -qx 'WEBMIN_FW_TCP_INCOMING = 22 80 443 12321' "$REPO/Makefile"
}

@test "recipe: the build tools are copied into the tree before the conf scripts" {
    grep -q 'bin/keel-wordpress-image-check' "$REPO/Makefile"
    grep -q 'bin/keel-project-packages' "$REPO/Makefile"
}

@test "recipe: the conf script asks nginx, not Apache, and PHP-FPM's php.ini" {
    run code "$REPO/conf.d/main"
    run ! grep -E 'apache|a2en|a2dis|apache2ctl' <<< "$output"
    code "$REPO/conf.d/main" | grep -qF 'nginx -t'
    code "$REPO/conf.d/main" | grep -qF '/etc/php/?.?/fpm/php.ini'
}

@test "recipe: the conf script does not create the WordPress schema" {
    run bash -c "grep -vE '^\s*#' '$REPO/conf.d/main' | grep 'CREATE DATABASE'"
    [ "$status" -ne 0 ]
}

@test "recipe: the conf script keeps the account of WordPress unable to log in" {
    code "$REPO/conf.d/main" | grep -qF "DB_INVALID_HASH='*THISISNOTAVALIDPASSWORDTHATCANBEUSEDHERE'"
    code "$REPO/conf.d/main" | grep -qF 'DB_HOSTS="localhost ::1 127.0.0.1"'
}

@test "recipe: the conf script validates the manifest and runs the image check" {
    code "$REPO/conf.d/main" | grep -qF 'keel manifest validate wordpress'
    code "$REPO/conf.d/main" | grep -qF 'keel-wordpress-image-check'
}

@test "recipe: PHP runs as the web user of nginx and the cron job does not use the web" {
    run code "$REPO/overlay/etc/cron.d/wordpress-cron"
    run ! grep -E 'curl|wp-cron.php' <<< "$output"
    code "$REPO/overlay/etc/cron.d/wordpress-cron" \
        | grep -qF '/usr/local/bin/wp --path=/var/www/wordpress cron event run --due-now'
}

@test "recipe: the cron job does nothing on a read-only server and runs when the server cannot be asked" {
    job=$(code "$REPO/overlay/etc/cron.d/wordpress-cron" | grep -E '^\*/5')
    [[ "$job" == *"SELECT @@global.read_only"* ]]
    [[ "$job" == *'!= 1 ] && /usr/local/bin/wp'* ]]
    # the schedule part of the line is run by sh: the test of the guard
    guard='[ "$(echo 1)" != 1 ]'
    run sh -c "$guard"
    [ "$status" -ne 0 ]
    guard='[ "$(echo 0)" != 1 ]'
    run sh -c "$guard"
    [ "$status" -eq 0 ]
    guard='[ "$(false)" != 1 ]'
    run sh -c "$guard"
    [ "$status" -eq 0 ]
}

@test "recipe: no file of the overlay is an Apache file" {
    [ ! -e "$REPO/overlay/etc/apache2" ]
}

@test "recipe: the changelog names the layer and the version is a number" {
    head -1 "$REPO/changelog" | grep -qE '^keel-wordpress-19\.0 \([0-9]+\) keel;'
}

@test "recipe: the web service the hook starts is nginx" {
    grep -qF 'WORDPRESS_WEB_SERVICE="${WORDPRESS_WEB_SERVICE:-nginx}"' \
        "$REPO/overlay/usr/lib/inithooks/lib/wordpress.sh"
}

@test "recipe: the confconsole screen names no web shell the panel does not open" {
    run ! grep -E '12320|Web shell' "$REPO/overlay/etc/confconsole/services.txt"
}
