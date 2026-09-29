#!/usr/bin/env bats
# Unit tests of the two operator commands this appliance writes itself:
#
#   overlay/usr/local/bin/keel-wp                 wp-cli as the web user
#   overlay/usr/local/sbin/keel-wordpress-update  the supervised core update
#
# and of the compatibility names beside them, `turnkey-wp` and
# `turnkey-wordpress-update`, which are symlinks to those two (decision 0015).
#
# Both scripts are executed for real against scratch trees. What they hand to
# another program is a stub first in PATH that writes a line per call into a
# log the tests read: `runuser`, `chown`, `install` and `id`. wp-cli is a stub
# named by KEEL_TEST_WP_CLI. No test needs root, a web server, a database or a
# network.
#
# The web user is a sentinel that no account on the machine can be called, and
# never `$(id -un)`. The updater must not read the web user from `USER`, which
# root's login environment sets to `root`, and a test whose expected value
# happens to equal `$USER` cannot tell the two apart.
#
# The symlink is not asserted with `test -L` alone. A link that resolves is not
# a link that works, and docs/traps.md of the handbook records "asserting a
# configuration value is not asserting the behaviour it was supposed to
# produce" as a recurring defect here. So the compatibility name is *run*, and
# it is run through a copy of the overlay made the way the build makes it
# (`cp -TdR`, which is what fab-apply-overlay executes).

bats_require_minimum_version 1.5.0

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    BIN="$REPO/overlay/usr/local/bin"
    SBIN="$REPO/overlay/usr/local/sbin"
    WP="$BIN/keel-wp"
    UPDATE="$SBIN/keel-wordpress-update"

    S="$BATS_TEST_TMPDIR"
    CALLS="$S/calls"
    : > "$CALLS"

    # A name no account on any machine has, so an assertion on it cannot be
    # satisfied by whatever the test runner's own user happens to be.
    WEB_USER=keel-test-web-user

    WPROOT="$S/wordpress"
    mkdir -p "$WPROOT/wp-content" "$WPROOT/wp-includes"
    # The updater refuses a target that is not a WordPress, and this is the
    # file it looks for; conf.d/main asserts the same one after unpacking.
    printf '<?php $wp_version = %s;\n' "'7.1'" > "$WPROOT/wp-includes/version.php"
    : > "$WPROOT/wp-config.php"
    : > "$WPROOT/index.php"

    STUBS="$S/bin"
    mkdir -p "$STUBS"
    _stub runuser
    _stub chown
    _stub install
    # id: root unless a test says otherwise, so the updater's guard can be
    # driven both ways without being root.
    cat > "$STUBS/id" <<EOF
#!/bin/bash
echo "id \$*" >> "$CALLS"
echo "\${KEEL_TEST_UID:-0}"
EOF
    chmod +x "$STUBS/id"
    # wp-cli: logs, and fails the one invocation a test names.
    cat > "$STUBS/wp" <<EOF
#!/bin/bash
echo "wp \$*" >> "$CALLS"
[ "\${KEEL_TEST_WP_FAIL:-}" = "\$*" ] && exit "\${KEEL_TEST_WP_CODE:-1}"
exit 0
EOF
    chmod +x "$STUBS/wp"

    PATH="$STUBS:$PATH"
    export PATH
    # keel-wp's three knobs are the ones it already shipped with and are the
    # appliance's own. The updater's are KEEL_TEST_ prefixed because they exist
    # only for these tests: that script runs as root and rewrites the owner and
    # the mode of every file under its target, so the name that chooses the
    # target must not be one an operator could already have exported.
    export WP_DIR="$WPROOT" WP_USR="$WEB_USER" WP_CACHE="$S/wp-cli-cache"
    export KEEL_TEST_WPROOT="$WPROOT" KEEL_TEST_WP_USER="$WEB_USER"
    export KEEL_TEST_WP_CLI="$STUBS/wp"
}

_stub() {
    cat > "$STUBS/$1" <<EOF
#!/bin/bash
echo "$1 \$*" >> "$CALLS"
exit \${KEEL_TEST_${1^^}_CODE:-0}
EOF
    chmod +x "$STUBS/$1"
}

# _runuser_command: the string keel-wp handed to runuser, which is the whole
# of what it asked the web user to run.
_runuser_command() {
    sed -n 's/^runuser [^ ]* -s [^ ]* -c //p' "$CALLS"
}

# --- keel-wp: the wrapper an operator types ----------------------------------

@test "keel-wp is the real command and turnkey-wp is a relative symlink to it" {
    [ -f "$WP" ] && [ ! -L "$WP" ]
    [ -x "$WP" ]
    [ -L "$BIN/turnkey-wp" ]
    # Relative, not absolute: an absolute link does not resolve inside
    # fab-chroot, so conf.d/main would not find it at build time.
    [ "$(readlink "$BIN/turnkey-wp")" = keel-wp ]
}

@test "keel-wordpress-update is the real command and the turnkey name links to it" {
    [ -f "$UPDATE" ] && [ ! -L "$UPDATE" ]
    [ -x "$UPDATE" ]
    [ -L "$SBIN/turnkey-wordpress-update" ]
    [ "$(readlink "$SBIN/turnkey-wordpress-update")" = keel-wordpress-update ]
}

@test "keel-wp runs wp-cli as the web user, with an explicit path, never as root" {
    run "$WP" option get siteurl
    [ "$status" -eq 0 ]
    grep -q "^runuser $WEB_USER -s /bin/bash -c " "$CALLS"
    [[ "$(_runuser_command)" == *"/usr/local/bin/wp --path='$WPROOT'"* ]]
    [[ "$(_runuser_command)" != *--allow-root* ]]
}

@test "keel-wp passes its arguments through to wp-cli" {
    run "$WP" option get siteurl
    [ "$status" -eq 0 ]
    [[ "$(_runuser_command)" == *"option get siteurl"* ]]
}

@test "keel-wp quotes an argument that carries a space" {
    run "$WP" post create --post_title='TurnKey v19 acceptance' --porcelain
    [ "$status" -eq 0 ]
    [[ "$(_runuser_command)" == *"--post_title=TurnKey\\ v19\\ acceptance"* ]]
}

@test "keel-wp quotes an argument that would otherwise end the command" {
    run "$WP" eval "echo 'x'; rm -rf /"
    [ "$status" -eq 0 ]
    [[ "$(_runuser_command)" != *"; rm -rf /"* ]]
}

@test "keel-wp creates the wp-cli cache directory when it is not there" {
    [ ! -d "$WP_CACHE" ]
    run "$WP" core version
    [ "$status" -eq 0 ]
    [ -d "$WP_CACHE" ]
    grep -q "^chown -R $WEB_USER:$WEB_USER $WP_CACHE\$" "$CALLS"
}

@test "keel-wp leaves an existing cache directory alone and still owns it" {
    mkdir -p "$WP_CACHE"
    : > "$WP_CACHE/already-here"
    run "$WP" core version
    [ "$status" -eq 0 ]
    [ -f "$WP_CACHE/already-here" ]
    grep -q "^chown -R $WEB_USER:$WEB_USER $WP_CACHE\$" "$CALLS"
}

@test "keel-wp hands back the exit code runuser gave it" {
    KEEL_TEST_RUNUSER_CODE=3 run "$WP" core verify-checksums
    [ "$status" -eq 3 ]
}

@test "keel-wp fails when the cache cannot be owned" {
    KEEL_TEST_CHOWN_CODE=1 run "$WP" core version
    [ "$status" -eq 1 ]
    grep -q '^chown ' "$CALLS"
    [ -z "$(_runuser_command)" ]
}

@test "DEBUG makes keel-wp trace the command it runs" {
    # kcov measures bash by turning xtrace on itself: it points BASH_ENV at a
    # helper that sets its own PS4 and BASH_XTRACEFD, so under coverage the
    # script's own trace goes to kcov's reader and never to this test. This
    # one run is therefore left uninstrumented, with the ordinary prefix and
    # stderr to trace to. Every line it executes is covered by the tests
    # above, so nothing is lost from the measurement.
    run env -u BASH_ENV DEBUG=1 PS4='+ ' BASH_XTRACEFD=2 "$WP" core version
    [ "$status" -eq 0 ]
    [[ "$output" == *"+ runuser"* ]]
}

# --- the compatibility names, run rather than inspected ----------------------

@test "turnkey-wp runs the same command keel-wp does" {
    [ -L "$BIN/turnkey-wp" ]
    run "$BIN/turnkey-wp" option get siteurl
    [ "$status" -eq 0 ]
    grep -q "^runuser $WEB_USER -s /bin/bash -c " "$CALLS"
    [[ "$(_runuser_command)" == *"--path='$WPROOT'"* ]]
    [[ "$(_runuser_command)" == *"option get siteurl"* ]]
}

@test "the overlay copy the build makes keeps turnkey-wp a working link" {
    # cp -TdR is exactly what fab-apply-overlay runs (cmd_apply_overlay in
    # fab), so this is the build's own copy step and not an imitation of it.
    # Twice, because the Makefile applies this overlay twice: once through
    # COMMON_OVERLAYS and once as the product-local ROOT_OVERLAY. A second
    # copy over an existing link must leave a link and not a copy of its
    # target.
    root="$S/root.patched"
    mkdir -p "$root"
    cp -TdR "$REPO/overlay" "$root"
    cp -TdR "$REPO/overlay" "$root"
    [ -L "$root/usr/local/bin/turnkey-wp" ]
    [ "$(readlink "$root/usr/local/bin/turnkey-wp")" = keel-wp ]
    [ -x "$root/usr/local/bin/keel-wp" ]
    run "$root/usr/local/bin/turnkey-wp" option get siteurl
    [ "$status" -eq 0 ]
    [[ "$(_runuser_command)" == *"option get siteurl"* ]]
}

@test "the overlay copy keeps turnkey-wordpress-update a working link" {
    root="$S/root.patched"
    mkdir -p "$root"
    cp -TdR "$REPO/overlay" "$root"
    cp -TdR "$REPO/overlay" "$root"
    [ -L "$root/usr/local/sbin/turnkey-wordpress-update" ]
    run "$root/usr/local/sbin/turnkey-wordpress-update"
    [ "$status" -eq 0 ]
    grep -q "^wp --allow-root --path=$WPROOT core update\$" "$CALLS"
}

@test "it is -L that would flatten the link, and -d is not what prevents it" {
    # What the overlay step has to avoid is dereferencing. -P is already the
    # default under -R, so a plain -R keeps the link, and -d only adds
    # --preserve=links, which is about hard links and does nothing here. That
    # is asserted rather than left in a comment, because the comment above
    # says the build's flags are safe and this is the reason they are.
    plain="$S/plain"; deref="$S/deref"
    cp -TR "$REPO/overlay" "$plain"
    cp -TLR "$REPO/overlay" "$deref"
    # -R without -d: still a link, and still a working command.
    [ -L "$plain/usr/local/bin/turnkey-wp" ]
    run "$plain/usr/local/bin/turnkey-wp" core version
    [ "$status" -eq 0 ]
    # -L: a second regular file, and the compatibility name stops being a link
    # to anything. This is the flag that would break the property.
    [ ! -L "$deref/usr/local/bin/turnkey-wp" ]
    [ -f "$deref/usr/local/bin/turnkey-wp" ]
    [ ! -L "$deref/usr/local/sbin/turnkey-wordpress-update" ]
}

@test "turnkey-wordpress-update refuses a non-root caller under its own name" {
    [ -L "$SBIN/turnkey-wordpress-update" ]
    KEEL_TEST_UID=1000 run "$SBIN/turnkey-wordpress-update"
    [ "$status" -eq 1 ]
    [[ "$output" == *"turnkey-wordpress-update must run as root"* ]]
}

# --- keel-wordpress-update: the supervised core update -----------------------

@test "keel-wordpress-update refuses a caller who is not root" {
    KEEL_TEST_UID=1000 run "$UPDATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-wordpress-update must run as root"* ]]
    run ! grep -q '^wp ' "$CALLS"
}

@test "keel-wordpress-update refuses a target that is not a WordPress" {
    rm -f "$WPROOT/wp-includes/version.php"
    run "$UPDATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a WordPress installation"* ]]
    run ! grep -q '^wp ' "$CALLS"
    run ! grep -q '^chown ' "$CALLS"
}

@test "keel-wordpress-update updates core and then verifies the checksums" {
    run "$UPDATE"
    [ "$status" -eq 0 ]
    grep -q "^wp --allow-root --path=$WPROOT core update\$" "$CALLS"
    grep -q "^wp --allow-root --path=$WPROOT core verify-checksums\$" "$CALLS"
}

@test "keel-wordpress-update stops when the update fails" {
    KEEL_TEST_WP_FAIL="--allow-root --path=$WPROOT core update" \
        run "$UPDATE"
    [ "$status" -eq 1 ]
    grep -q "^wp --allow-root --path=$WPROOT core update\$" "$CALLS"
    run ! grep -q 'verify-checksums' "$CALLS"
}

@test "keel-wordpress-update stops when the checksums do not verify" {
    KEEL_TEST_WP_FAIL="--allow-root --path=$WPROOT core verify-checksums" \
        run "$UPDATE"
    [ "$status" -eq 1 ]
    grep -q "^wp --allow-root --path=$WPROOT core verify-checksums\$" "$CALLS"
    run ! grep -q '^chown -R root:root' "$CALLS"
}

@test "keel-wordpress-update puts the ownership boundary back" {
    run "$UPDATE"
    [ "$status" -eq 0 ]
    grep -q "^chown -R root:root $WPROOT\$" "$CALLS"
    grep -q "^chown root:$WEB_USER $WPROOT/wp-config.php\$" "$CALLS"
    [ "$(stat -c %a "$WPROOT/wp-config.php")" = 640 ]
    [ "$(stat -c %a "$WPROOT/index.php")" = 644 ]
    [ "$(stat -c %a "$WPROOT")" = 755 ]
}

@test "keel-wordpress-update leaves the five runtime directories to the web server" {
    run "$UPDATE"
    [ "$status" -eq 0 ]
    for dir in uploads cache upgrade plugins themes; do
        grep -q "^install -d -o $WEB_USER -g $WEB_USER -m 0755 $WPROOT/wp-content/$dir\$" \
            "$CALLS"
        grep -q "^chown -R $WEB_USER:$WEB_USER $WPROOT/wp-content/$dir\$" "$CALLS"
    done
}

# --- the two names that must not come from the caller's environment ----------

@test "USER in the environment does not decide who owns wp-content" {
    # The file this replaced opened `USER=www-data`, a plain assignment that
    # masks the inherited value. Reading `${USER:-www-data}` instead would take
    # root's login environment, where USER is root, and hand every runtime
    # directory to root:root: uploads and plugin installs would fail from the
    # first supervised update onwards, with nothing pointing back at it.
    USER=root run "$UPDATE"
    [ "$status" -eq 0 ]
    grep -q "^chown -R $WEB_USER:$WEB_USER $WPROOT/wp-content/uploads\$" "$CALLS"
    run ! grep -q '^chown -R root:root .*wp-content' "$CALLS"
    grep -q "^chown root:$WEB_USER $WPROOT/wp-config.php\$" "$CALLS"
}

@test "WPROOT in the environment does not decide what this script rewrites" {
    # It runs as root and rewrites the owner and the mode of every file under
    # its target, so the variable that chooses that target is deliberately not
    # a name an operator could already be exporting. conf.d/main of this very
    # repository uses WPROOT for this same path.
    WPROOT=/ WP_USER=root WP_CLI=/bin/true run "$UPDATE"
    [ "$status" -eq 0 ]
    grep -q "^chown -R root:root $KEEL_TEST_WPROOT\$" "$CALLS"
    run ! grep -qx 'chown -R root:root /' "$CALLS"
    grep -q "^wp --allow-root --path=$KEEL_TEST_WPROOT core update\$" "$CALLS"
}
