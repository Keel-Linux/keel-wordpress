#!/usr/bin/env bats
# The route of the WordPress site (handbook decision 0059, point 4). keel-web
# includes /etc/nginx/keel-default.d/*.conf in its default site and in the
# server behind Anubis, and that site already has "location /" and a root of
# its own. So the WordPress routes are regular expressions, which nginx
# tries after the prefixes and in file order, and each one names its root.
# These read the file; the build runs nginx -t on it, and the booted
# image serves it.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ROUTE="$REPO/overlay/etc/nginx/keel-default.d/60-keel-wordpress.conf"
}

route() {
    grep -vE '^\s*(#|$)' "$ROUTE"
}

# the line number of the first line of the route that matches
at() {
    route | grep -nF -- "$1" | head -1 | cut -d: -f1
}

@test "route: the file is in keel-web's include directory, after the check page" {
    [ -f "$ROUTE" ]
    [ "$(basename "$ROUTE")" \> "50-keel-lnmp.conf" ]
}

@test "route: it is no server and listens on nothing" {
    run bash -c "grep -vE '^\s*(#|$)' '$ROUTE' | grep -cE '^\s*(server|listen|server_name)\b'"
    [ "$output" = 0 ]
}

@test "route: no location that the default site of keel-web already has" {
    run bash -c "grep -vE '^\s*(#|$)' '$ROUTE' | grep -E 'location (\^~ |= )?/ \{'"
    [ "$status" -ne 0 ]
    run bash -c "grep -vE '^\s*(#|$)' '$ROUTE' | grep -E 'location (= )?/(404|50x)\.html|keel-health'"
    [ "$status" -ne 0 ]
}

@test "route: the catch-all is a regular expression and it is the last location" {
    route | grep -qxF 'location ~ ^/ {'
    last=$(route | grep -E '^location ' | tail -1)
    [ "$last" = 'location ~ ^/ {' ]
}

@test "route: the site root is the WordPress tree, in every location that serves files" {
    n=$(route | grep -cE '^location ')
    r=$(route | grep -cF 'root /var/www/wordpress;')
    d=$(route | grep -cF 'deny all;')
    # a location that only denies needs no root: the others do
    [ "$r" -ge 2 ]
    [ "$n" -gt "$r" ]
    [ "$d" -ge 5 ]
}

@test "route: pretty permalinks fall back to index.php with the query string" {
    route | grep -qF 'try_files $uri $uri/ /index.php?$args;'
}

@test "route: PHP goes to PHP-FPM through Debian's socket, and only .php files run" {
    route | grep -qF 'include snippets/fastcgi-php.conf;'
    route | grep -qF 'fastcgi_pass unix:/run/php/php-fpm.sock;'
    route | grep -qxF 'location ~ \.php$ {'
    run bash -c "grep -vE '^\s*(#|$)' '$ROUTE' | grep -c 'fastcgi_pass'"
    [ "$output" = 1 ]
}

@test "route: wp-config.php and its sample are refused" {
    route | grep -qF 'location ~* ^/wp-config(?:-sample)?\.php$ {'
}

@test "route: PHP in the directories the web user writes is refused" {
    route | grep -qF 'location ~* ^/wp-content/(?:uploads|cache|upgrade|upgrade-temp-backup)/.*\.(?:php|phtml|phar)$ {'
}

@test "route: the PHP files of wp-includes and wp-admin/includes are refused, one level only" {
    route | grep -qF 'location ~* ^/wp-(?:includes|admin/includes)/[^/]*\.php$ {'
}

@test "route: hidden files and directories are refused, .well-known is not" {
    route | grep -qF 'location ~ /\.(?!well-known/) {'
}

@test "route: the denies come before the PHP handler and the catch-all" {
    php=$(at 'location ~ \.php$ {')
    all=$(at 'location ~ ^/ {')
    for rule in 'wp-config' 'uploads|cache' 'wp-(?:includes' '/\.(?!well-known/)' '\.(?:log|bak'; do
        n=$(at "$rule")
        [ -n "$n" ]
        [ "$n" -lt "$php" ]
    done
    [ "$php" -lt "$all" ]
}

@test "route: xmlrpc.php is reachable, as it was under Apache" {
    run bash -c "grep -vE '^\s*#' '$ROUTE' | grep -i xmlrpc"
    [ "$status" -ne 0 ]
}

@test "route: the body limit and the PHP time limit follow the Makefile" {
    route | grep -qF 'client_max_body_size 64m;'
    route | grep -qF 'fastcgi_read_timeout 120s;'
}

@test "route: log, backup and dump files are refused" {
    route | grep -qF 'location ~* \.(?:log|bak|orig|swp|sql)$ {'
}

@test "route: the three headers every response of the site carries" {
    route | grep -qxF 'add_header X-Content-Type-Options nosniff always;'
    route | grep -qxF 'add_header X-Frame-Options SAMEORIGIN always;'
    route | grep -qxF 'add_header Referrer-Policy strict-origin-when-cross-origin always;'
}

@test "route: a location with a directive that adds a header would drop these three" {
    run bash -c "grep -vE '^\s*(#|$)' '$ROUTE' | grep -c '^\s\+add_header'"
    [ "$output" = 0 ]
}

@test "route: nothing of Apache and no .htaccess rule" {
    run bash -c "grep -vE '^\s*#' '$ROUTE' | grep -iE 'apache|htaccess'"
    [ "$status" -ne 0 ]
}
