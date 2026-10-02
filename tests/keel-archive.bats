#!/usr/bin/env bats
# Unit tests of conf.d/zzz-keel-archive, the last conf script of the build: the
# image's source for the project's signed APT archive, enabled, and its pin at
# 990 (tracker#23). Keel-Linux/common#30 ships both (overlays/turnkey.d/
# keel-apt); on a bootstrap from before it, this script writes them. Either
# way it refuses unless the key that verifies the archive is in the image and
# the build time source is gone. Run against scratch trees, so no chroot, no
# apt and no network.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../conf.d/zzz-keel-archive"
    S="$BATS_TEST_TMPDIR"
    export KEEL_SOURCES="$S/keel.sources"
    export KEEL_PREFS="$S/keel.pref"
    export KEEL_KEYRING="$S/keel-archive-keyring.gpg"
    export KEEL_STAGING_LIST="$S/keel-staging.list"
    export KEEL_STAGING_KEYRING="$S/keel-staging-keyring.asc"
    _keyring
    _common
    rm -f "$KEEL_STAGING_LIST" "$KEEL_STAGING_KEYRING"
    # gpg is stubbed: a keyring is a file, and what matters to this script is
    # how many public keys the reader says are in it.
    STUBS="$S/bin"
    mkdir -p "$STUBS"
    cat > "$STUBS/gpg" <<EOF
#!/bin/bash
n=\${GPG_TEST_KEYS:-1}
i=0
while [ "\$i" -lt "\$n" ]; do echo "pub:-:255:22:DEADBEEF:1:::-:::cSC:::::ed25519:::0:"; i=\$((i+1)); done
exit 0
EOF
    chmod +x "$STUBS/gpg"
    PATH="$STUBS:$PATH"
    export PATH
}

# _common: the source and the pin as common ships them
_common() {
    cat > "$KEEL_SOURCES" <<EOF
# a comment the script must not read as a field
Types: deb
URIs: https://archive.keellinux.org
Suites: trixie
Components: main
Enabled: yes
Signed-By: $KEEL_KEYRING

Types: deb
URIs: https://archive.keellinux.org
Suites: trixie-testing
Components: main
Enabled: no
Signed-By: $KEEL_KEYRING
EOF
    printf '# a comment\nPackage: *\nPin: release o=Keel Linux\nPin-Priority: 990\n' > "$KEEL_PREFS"
}

# _sources [KEY=VALUE ...]: a one stanza source with any field a test changes
_sources() {
    local enabled=yes uri=https://archive.keellinux.org suite=trixie
    local signed=$KEEL_KEYRING pair
    for pair in "$@"; do
        case "$pair" in
            Enabled=*) enabled=${pair#*=} ;;
            URIs=*) uri=${pair#*=} ;;
            Suites=*) suite=${pair#*=} ;;
            Signed-By=*) signed=${pair#*=} ;;
        esac
    done
    cat > "$KEEL_SOURCES" <<EOF
Types: deb
URIs: $uri
Suites: $suite
Components: main
Enabled: $enabled
Signed-By: $signed
EOF
}

_keyring() {
    printf 'not really a keyring, but not empty either\n' > "$KEEL_KEYRING"
}

# _without_common: a tree from a bootstrap before common shipped the files
_without_common() {
    rm -f "$KEEL_SOURCES" "$KEEL_PREFS"
}

@test "common's source and pin are verified and left byte for byte" {
    cp "$KEEL_SOURCES" "$S/sources.before"
    cp "$KEEL_PREFS" "$S/prefs.before"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://archive.keellinux.org trixie enabled"* ]]
    [[ "$output" == *"pinned at 990"* ]]
    cmp "$S/sources.before" "$KEEL_SOURCES"
    cmp "$S/prefs.before" "$KEEL_PREFS"
}

@test "without common's files it writes the source, enabled, and the pin at 990" {
    _without_common
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://archive.keellinux.org trixie enabled"* ]]
    awk 'BEGIN { RS = "" } /Suites: trixie\n/ && /Enabled: yes/ { f = 1 } END { exit !f }' "$KEEL_SOURCES"
    awk 'BEGIN { RS = "" } /Suites: trixie-testing/ && /Enabled: no/ { f = 1 } END { exit !f }' "$KEEL_SOURCES"
    grep -qx "Signed-By: $KEEL_KEYRING" "$KEEL_SOURCES"
    grep -qx 'Pin: release o=Keel Linux' "$KEEL_PREFS"
    grep -qx 'Pin-Priority: 990' "$KEEL_PREFS"
}

@test "running it twice leaves the same bytes" {
    _without_common
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    cp "$KEEL_SOURCES" "$S/sources.first"
    cp "$KEEL_PREFS" "$S/prefs.first"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    cmp "$S/sources.first" "$KEEL_SOURCES"
    cmp "$S/prefs.first" "$KEEL_PREFS"
}

@test "it never turns on the testing track" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    awk 'BEGIN { RS = "" } /Suites: trixie-testing/ && /Enabled: no/ { f = 1 } END { exit !f }' "$KEEL_SOURCES"
}

@test "a Keel pin at 1001 is refused (tracker#23)" {
    printf 'Package: *\nPin: release o=Keel Linux\nPin-Priority: 1001\n' > "$KEEL_PREFS"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"1001"* ]]
    [[ "$output" == *"990"* ]]
}

@test "a pin file with no Keel pin at 990 in it is refused" {
    printf 'Package: *\nPin: release o=Debian\nPin-Priority: 500\n' > "$KEEL_PREFS"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"990"* ]]
}

@test "a disabled stable source is refused" {
    _sources Enabled=no
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not enabled"* ]]
}

@test "a missing keyring is fatal, names the package that carries it, and writes nothing" {
    _without_common
    rm -f "$KEEL_KEYRING"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"keel-archive-keyring"* ]]
    [ ! -e "$KEEL_SOURCES" ]
    [ ! -e "$KEEL_PREFS" ]
}

@test "an empty keyring is fatal" {
    : > "$KEEL_KEYRING"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing or empty"* ]]
}

@test "a keyring with no public key in it is fatal, and writes nothing" {
    _without_common
    export GPG_TEST_KEYS=0
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"carries no public key"* ]]
    [ ! -e "$KEEL_SOURCES" ]
}

@test "a build time source still in the image is fatal, and writes nothing" {
    _without_common
    printf 'deb [signed-by=/etc/apt/keyrings/keel-staging-keyring.asc] file:///srv/keel-apt/repo trixie-staging main\n' \
        > "$KEEL_STAGING_LIST"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zz-project-packages did not run"* ]]
    [ ! -e "$KEEL_SOURCES" ]
}

@test "the build time staging keyring still in the image is fatal" {
    # It verified the archive during the build and it signs whatever the build
    # host produced, so it is not an appliance's business (tracker#7).
    printf 'the staging public key\n' > "$KEEL_STAGING_KEYRING"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not reach an appliance"* ]]
}

@test "a staging suite is refused by name" {
    export KEEL_ARCHIVE_SUITE=trixie-staging
    _sources "Suites=trixie-staging"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsigned staging distribution"* ]]
}

@test "a suite that is not the expected one is refused" {
    _sources "Suites=sid"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"names the suite 'sid'"* ]]
}

@test "another archive is refused" {
    _sources "URIs=https://apt.example.org"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"names 'https://apt.example.org'"* ]]
}

@test "another keyring in Signed-By is refused" {
    _sources "Signed-By=/usr/share/keyrings/debian-archive-keyring.gpg"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is signed by"* ]]
}

@test "a source with no Signed-By at all is refused" {
    cat > "$KEEL_SOURCES" <<EOF
Types: deb
URIs: https://archive.keellinux.org
Suites: trixie
Components: main
Enabled: yes
EOF
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is signed by ''"* ]]
}
