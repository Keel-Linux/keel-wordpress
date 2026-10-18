#!/usr/bin/env bats
# bin/keel-wordpress-image-check, which conf.d/main runs at the end of the
# build on the image tree (handbook decision 0059): it changes nothing and
# fails the build when the image is not what a first boot of Keel WordPress
# starts from. Here it runs against a scratch tree named by KEEL_CONF_ROOT.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CHECK="$REPO/bin/keel-wordpress-image-check"
    T="$BATS_TEST_TMPDIR/tree"
    export KEEL_CONF_ROOT="$T"
    mkdir -p "$T/etc/systemd/system/multi-user.target.wants" "$T/var/lib/dpkg" \
        "$T/etc/nginx/keel-default.d" "$T/usr/share/keel/appliances" \
        "$T/etc/php/8.4/fpm" "$T/var/www/wordpress/wp-includes" \
        "$T/var/www/wordpress/wp-content" "$T/etc/cron.d" "$T/var/lib/mysql/mysql"
    ln -s /dev/null "$T/etc/systemd/system/mariadb.socket"
    ln -s /dev/null "$T/etc/systemd/system/mariadb-extra.socket"
    ln -s /usr/lib/systemd/system/php8.4-fpm.service \
        "$T/etc/systemd/system/multi-user.target.wants/php8.4-fpm.service"
    printf 'Package: nginx\nStatus: install ok installed\n\nPackage: php8.4-fpm\nStatus: install ok installed\n\n' \
        > "$T/var/lib/dpkg/status"
    cp "$REPO/overlay/etc/nginx/keel-default.d/60-keel-wordpress.conf" "$T/etc/nginx/keel-default.d/"
    cp "$REPO/overlay/etc/cron.d/wordpress-cron" "$T/etc/cron.d/"
    cp "$REPO/overlay/usr/share/keel/appliances/wordpress.yaml" "$T/usr/share/keel/appliances/"
    : > "$T/usr/share/keel/appliances/lnmp.yaml"
    : > "$T/var/www/wordpress/wp-includes/version.php"
    printf 'allow_url_fopen = On\n' > "$T/etc/php/8.4/fpm/php.ini"
}

@test "an image as the recipe leaves it passes" {
    run "$CHECK"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "apache2 in the image fails the build" {
    printf 'Package: apache2\nStatus: install ok installed\n\n' >> "$T/var/lib/dpkg/status"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"apache2 is installed"* ]]
}

@test "mod_php and mod_security2 in the image fail the build, each said" {
    printf 'Package: libapache2-mod-php8.4\nStatus: install ok installed\n\n' >> "$T/var/lib/dpkg/status"
    printf 'Package: libapache2-mod-security2\nStatus: install ok installed\n\n' >> "$T/var/lib/dpkg/status"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"libapache2-mod-php8.4 is installed"* ]]
    [[ "$output" == *"libapache2-mod-security2 is installed"* ]]
}

@test "a package that was removed is not installed" {
    printf 'Package: apache2\nStatus: deinstall ok config-files\n\n' >> "$T/var/lib/dpkg/status"
    run "$CHECK"
    [ "$status" -eq 0 ]
}

@test "a socket unit of MariaDB that is not masked fails the build" {
    rm "$T/etc/systemd/system/mariadb-extra.socket"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mariadb-extra.socket is not masked"* ]]
}

@test "PHP-FPM not enabled fails the build" {
    rm "$T/etc/systemd/system/multi-user.target.wants/php8.4-fpm.service"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"php8.4-fpm.service is not enabled"* ]]
}

@test "a missing route, manifest or WordPress tree fails the build, each said" {
    rm "$T/etc/nginx/keel-default.d/60-keel-wordpress.conf" \
        "$T/usr/share/keel/appliances/wordpress.yaml" \
        "$T/var/www/wordpress/wp-includes/version.php"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"60-keel-wordpress.conf"* ]]
    [[ "$output" == *"wordpress.yaml"* ]]
    [[ "$output" == *"version.php"* ]]
}

@test "the manifest of lnmp must be there: the chain is not complete without it" {
    rm "$T/usr/share/keel/appliances/lnmp.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"lnmp.yaml"* ]]
}

@test "the manifest of a database layer beside wordpress.yaml fails the build" {
    : > "$T/usr/share/keel/appliances/mariadb.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mariadb.yaml is in the image"* ]]
}

@test "a wp-config.php in the image fails the build: it holds a credential" {
    : > "$T/var/www/wordpress/wp-config.php"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"wp-config.php is in the image"* ]]
}

@test "a WordPress schema in the data directory fails the build: it would block a replica" {
    mkdir "$T/var/lib/mysql/wordpress"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/lib/mysql/wordpress is in the image"* ]]
}

@test "a cron job that goes through the web server fails the build" {
    echo '*/5 * * * * www-data /usr/bin/curl http://[::1]/wp-cron.php' > "$T/etc/cron.d/wordpress-cron"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"wordpress-cron"* ]]
}

@test "an allow_url_fopen that is off in PHP-FPM fails the build" {
    printf 'allow_url_fopen = Off\n' > "$T/etc/php/8.4/fpm/php.ini"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"allow_url_fopen"* ]]
}

@test "a credential file of MariaDB fails the build" {
    mkdir -p "$T/root"
    : > "$T/root/.my.cnf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/root/.my.cnf is in the image"* ]]
}

@test "every problem is reported, not only the first" {
    printf 'Package: apache2\nStatus: install ok installed\n\n' >> "$T/var/lib/dpkg/status"
    rm "$T/etc/systemd/system/mariadb.socket"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"apache2 is installed"* ]]
    [[ "$output" == *"mariadb.socket is not masked"* ]]
}
