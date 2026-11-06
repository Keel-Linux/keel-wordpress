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

@test "recipe: the cron job waits for the mark of a ready site" {
    job=$(code "$REPO/overlay/etc/cron.d/wordpress-cron" | grep -E '^\*/5')
    [[ "$job" == *"www-data [ -e /var/www/.keel-wordpress-ready ] && "* ]]
    grep -qx 'WORDPRESS_READY="${WORDPRESS_READY:-/var/www/.keel-wordpress-ready}"' \
        "$REPO/overlay/usr/lib/inithooks/lib/wordpress.sh"
}

# The replica of a cloud advanced pair mailed root the errors of a run at
# its first pairing (BR2, 2026-11-06, keel 0.23.89): the job ran at 23:25:01,
# keel set read_only at 23:24:47 and replaced the schema with the copy of the
# primary at 23:25:03. The job now runs only when keel does not say that the
# node is a replica and the server answers that it takes writes (0). A server
# that cannot be asked gets no run: its events would fail too.
@test "recipe: the cron job runs only on a node that keel does not call a replica and whose server takes writes" {
    job=$(code "$REPO/overlay/etc/cron.d/wordpress-cron" | grep -E '^\*/5')
    [[ "$job" == *"SELECT @@global.read_only"* ]]
    [[ "$job" == *"! grep -qx role=replica /var/lib/keel/role"* ]]
    [[ "$job" == *'= 0 ] && /usr/local/bin/wp'* ]]
    [[ "$job" != *'!= 1 ]'* ]]
    # asked with the account of wp-config.php (www-data over the socket)
    [[ "$job" == *"/usr/local/bin/wp --path=/var/www/wordpress eval 'echo (int) \$GLOBALS[\"wpdb\"]->get_var(\"SELECT @@global.read_only\");'"* ]]
    [[ "$job" != *"/usr/bin/mysql"* ]]
    # the schedule part of the line is run by sh: the test of the guard
    run sh -c '[ "$(echo 1)" = 0 ]'
    [ "$status" -ne 0 ]
    run sh -c '[ "$(echo 0)" = 0 ]'
    [ "$status" -eq 0 ]
    run sh -c '[ "$(false)" = 0 ]'
    [ "$status" -ne 0 ]
}

@test "recipe: no file of the overlay is an Apache file" {
    [ ! -e "$REPO/overlay/etc/apache2" ]
}

# a NAME=VALUE line of conf.d/main, the value
pin() {
    sed -n "s|^$1=||p" "$REPO/conf.d/main"
}

@test "recipe: the WordPress pin is a release and a SHA-256" {
    [[ "$(pin WP_VERSION)" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
    [[ "$(pin WP_ARCHIVE_SHA256)" =~ ^[0-9a-f]{64}$ ]]
}

@test "recipe: the WordPress pin is not older than the release of 2026-11-06" {
    # The dashboard of an image from 7.1 said "WordPress 7.1.4 is available!
    # Please update now" (commissioning test of the ISO on BR1, 2026-11-06).
    # A new image carries the release that was current when it was built.
    floor=7.1.4
    [ "$(printf '%s\n' "$floor" "$(pin WP_VERSION)" | sort -V | head -n 1)" = "$floor" ]
}

@test "recipe: the conf script checks the archive digest, then the per file checksums" {
    grep -qF 'echo "$WP_ARCHIVE_SHA256  $WP_ARCHIVE" | sha256sum --check --strict' \
        "$REPO/conf.d/main"
    grep -qF 'keel-wp core verify-checksums --version="$WP_VERSION"' \
        "$REPO/conf.d/main"
}

@test "recipe: the conf script asks for the whole release in version.php" {
    # a prefix match lets the tree of 7.1.4 pass for a pin of 7.1
    grep -qF "grep -q \"wp_version = '\${WP_VERSION}'\"" "$REPO/conf.d/main"
}

@test "recipe: the boot test and the notes name the pinned release and its digest" {
    version=$(pin WP_VERSION)
    digest=$(pin WP_ARCHIVE_SHA256)
    grep -qxF "package_source=official WordPress $version archive pinned by SHA-256" \
        "$REPO/tests/v19.sh"
    grep -qF "integrity_evidence=WordPress $version archive SHA-256 $digest plus" \
        "$REPO/tests/v19.sh"
    grep -qF "exact WordPress $version archive SHA-256" "$REPO/docs/v19.0-testing.md"
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

@test "recipe: the confconsole screen names no check page: the product ships none" {
    run ! grep -iE 'check page|keel-check' "$REPO/overlay/etc/confconsole/services.txt"
}

@test "recipe: the conf script removes the stack check of lnmp, then the image check proves it" {
    local main="$REPO/conf.d/main" rm_line check_line path
    for path in /usr/lib/inithooks/firstboot.d/40lnmp-check \
            /etc/nginx/keel-default.d/50-keel-lnmp.conf \
            /usr/share/keel-lnmp/www; do
        grep -qF "$path" "$main"
    done
    rm_line=$(grep -n '^rm -rf .*40lnmp-check' "$main" | head -1 | cut -d: -f1)
    check_line=$(grep -n '^/usr/local/lib/keel-build/keel-wordpress-image-check' "$main" | head -1 | cut -d: -f1)
    [ -n "$rm_line" ]
    [ "$rm_line" -lt "$check_line" ]
}

@test "recipe: the overlay ships no file of the stack check" {
    [ ! -e "$REPO/overlay/usr/lib/inithooks/firstboot.d/40lnmp-check" ]
    [ ! -e "$REPO/overlay/etc/nginx/keel-default.d/50-keel-lnmp.conf" ]
    [ ! -e "$REPO/overlay/usr/share/keel-lnmp" ]
}

@test "recipe: the overlay ships no console.sh: it is inithooks' file" {
    [ ! -e "$REPO/overlay/usr/lib/inithooks/lib/console.sh" ]
}

@test "recipe: the boot test reads the manifest from the assembled rootfs" {
    # The spec names the appliance, and the host that runs the boot test
    # (the runner of the image gate) holds no manifest of it: the layer ships
    # it, so keel spec apply reads it under --root.
    run python3 - "$REPO/tests/boot-test.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read().replace("\\\n", " ")
text = re.sub(r"[ \t]+", " ", text)
assert re.search(r'keel spec apply --spec "[^"]+" --root "\$BT_ROOTFS" ', text), "spec apply has no --root"
assert re.search(r'keel diff --root "\$BT_ROOTFS" ', text), "diff has no --root"
PY
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "recipe: the boot test does not ask the archive: the runner of the image gate has no route to it" {
    # The proofs of the update path need the network of the host, and the
    # runner of the gate has none that reaches archive.keellinux.org (image
    # gate run 15: "apt-get update could not fetch"). The apt files are
    # Core's, and its boot test owns the update path. This test keeps the
    # file checks: the sources are enabled and signed, and nothing of the
    # build is left in the image.
    run grep -nE 'apt-get (update|download|-y install)|apt-cache policy' "$REPO/tests/boot-test.sh"
    [ "$status" -ne 0 ]
    grep -q 'bt_sources_verdict' "$REPO/tests/boot-test.sh"
    grep -q 'bt_build_leftovers_verdict' "$REPO/tests/boot-test.sh"
}

# keel-web 0.4.0 (decision 0079) moved the include of keel-default.d and
# keel-front.d into snippets that the sites include; the build of the
# wordpress layer on 0.4.0 failed on the old check (2026-11-06).
@test "recipe: the routes are checked through the snippets of keel-web 0.4.0" {
    code "$REPO/conf.d/main" | grep -qF "grep -qxF 'include /etc/nginx/keel-default.d/*.conf;' \"\$SNIPPETS/keel-web-site.conf\""
    code "$REPO/conf.d/main" | grep -qF "grep -qxF 'include /etc/nginx/keel-front.d/*.conf;' \"\$SNIPPETS/keel-web-front.conf\""
    code "$REPO/conf.d/main" | grep -qF 'include $SNIPPETS/keel-web-site.conf;" /etc/nginx/sites-available/keel-default'
    code "$REPO/conf.d/main" | grep -qF 'include $SNIPPETS/keel-web-front.conf;" /etc/nginx/sites-available/default-anubis'
    [ "$(code "$REPO/conf.d/main" | grep -c 'keel-web 0.4.0 is the least')" -eq 2 ]
}

# On the read-only replica of a cloud pair a login cannot be recorded, and
# the login page came back empty after a good password (BR2, 2026-11-06).
@test "recipe: the replica notice is a must-use plugin of the image" {
    f="$REPO/overlay/usr/share/keel-wordpress/mu-plugins/keel-replica.php"
    [ -f "$f" ]
    code "$REPO/conf.d/main" | grep -qF 'install -D -m 0644 /usr/share/keel-wordpress/mu-plugins/keel-replica.php'
    grep -qF '"$WPROOT/wp-content/mu-plugins/keel-replica.php"' "$REPO/conf.d/main"
    # it asks the server, shows the notice and refuses a login only when read only
    grep -qF "get_var('SELECT @@global.read_only')" "$f"
    grep -qF "add_filter('login_message'" "$f"
    grep -qF "}, 100);" "$f"
    grep -qF 'This node is the replica of a cloud pair.' "$f"
    grep -qF "defined('ABSPATH') || exit;" "$f"
}

