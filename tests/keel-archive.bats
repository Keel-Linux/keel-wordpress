#!/usr/bin/env bats
# Unit tests of conf.d/zzz-keel-archive, the last conf script of the build: it
# enables the project's signed APT archive and refuses to do so unless the key
# that verifies it is in the image and the build time source is gone. Run
# against scratch trees, so no chroot, no apt and no network.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../conf.d/zzz-keel-archive"
    S="$BATS_TEST_TMPDIR"
    export KEEL_SOURCES="$S/keel.sources"
    export KEEL_KEYRING="$S/keel-archive-keyring.gpg"
    export KEEL_STAGING_LIST="$S/keel-staging.list"
    _keyring
    _sources
    rm -f "$KEEL_STAGING_LIST"
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

# _sources [KEY=VALUE ...]: the deb822 source as the overlay ships it, with
# any field a test wants to change.
_sources() {
    local enabled=no uri=https://archive.keellinux.org suite=trixie
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
# a comment the script must not read as a field
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

@test "the shipped source is enabled and the script says what it enabled" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://archive.keellinux.org trixie enabled"* ]]
    grep -qx "Enabled: yes" "$KEEL_SOURCES"
}

@test "running it twice leaves the source enabled" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^Enabled: yes$' "$KEEL_SOURCES")" -eq 1 ]
}

@test "a missing source file is fatal" {
    rm -f "$KEEL_SOURCES"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not in the image"* ]]
}

@test "a missing keyring is fatal and names the package that carries it" {
    rm -f "$KEEL_KEYRING"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"keel-archive-keyring"* ]]
}

@test "an empty keyring is fatal" {
    : > "$KEEL_KEYRING"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing or empty"* ]]
}

@test "a keyring with no public key in it is fatal" {
    export GPG_TEST_KEYS=0
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"carries no public key"* ]]
    grep -qx "Enabled: no" "$KEEL_SOURCES"
}

@test "a build time source still in the image is fatal" {
    printf 'deb [trusted=yes] file:///srv/keel-apt/repo trixie-staging main\n' \
        > "$KEEL_STAGING_LIST"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zz-project-packages did not run"* ]]
    grep -qx "Enabled: no" "$KEEL_SOURCES"
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
Enabled: no
EOF
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is signed by ''"* ]]
}
