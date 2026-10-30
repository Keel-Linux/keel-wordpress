#!/usr/bin/env bats
# The appliance manifest of Keel WordPress (handbook decisions 0041, 0047 and
# 0059), which the overlay ships as /usr/share/keel/appliances/wordpress.yaml.
# It is built on lnmp, so the image has one manifest that no other manifest
# is built on, and `keel inspect` names the appliance wordpress. The grep
# checks need nothing; the last two tests run keel's own validator when
# KEEL_SRC names a checkout of Keel-Linux/keel and KEEL_MANIFEST_SOURCES
# names the checkouts of keel-core, keel-web, keel-lnmp and common.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MANIFEST="$REPO/overlay/usr/share/keel/appliances/wordpress.yaml"
}

manifest() {
    python3 -c 'import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$MANIFEST" "$1"
}

@test "manifest: the overlay ships it" {
    [ -f "$MANIFEST" ]
}

@test "manifest: an appliance named wordpress, version 1, on lnmp" {
    [ "$(manifest 'm["manifest_version"]')" = 1 ]
    [ "$(manifest 'm["kind"]')" = appliance ]
    [ "$(manifest 'm["name"]')" = wordpress ]
    [ "$(manifest 'm["base"]')" = lnmp ]
}

@test "manifest: the options of the first boot hook, each with a default and a pattern" {
    [ "$(manifest 'sorted(o["name"] for o in m["options"])')" = "['admin_user', 'db_name', 'db_prefix', 'site_title']" ]
    [ "$(manifest '[o["default"] for o in m["options"] if o["name"] == "admin_user"][0]')" = admin ]
    [ "$(manifest '[o["default"] for o in m["options"] if o["name"] == "db_name"][0]')" = wordpress ]
    [ "$(manifest '[o["default"] for o in m["options"] if o["name"] == "db_prefix"][0]')" = wp_ ]
    [ "$(manifest 'all("pattern" in o for o in m["options"] if o["name"] != "site_title")')" = True ]
}

@test "manifest: db_user and db_password are lnmp's: names are unique across the chain" {
    [ "$(manifest 'any(o["name"] == "db_user" for o in m["options"])')" = False ]
    [ "$(manifest 'any(s["name"] == "db_password" for s in m.get("secrets", []))')" = False ]
}

@test "manifest: no process, no port and no overlay of its own" {
    [ "$(manifest 'm.get("processes")')" = None ]
    [ "$(manifest 'm.get("overlays")')" = None ]
}

@test "manifest: the state it replicates is the directories WordPress writes at run time (0050, languages of the 2026-10-24 note)" {
    [ "$(manifest 'm["state"]["replicate"]')" = "['/var/www/wordpress/wp-content/uploads', '/var/www/wordpress/wp-content/themes', '/var/www/wordpress/wp-content/plugins', '/var/www/wordpress/wp-content/languages']" ]
}

@test "manifest: cache, upgrade and upgrade-temp-backup are inside no replicated path, so no exclude is declared" {
    [ "$(manifest 'm["state"].get("exclude")')" = None ]
}

@test "manifest: no tabs, no CRLF" {
    run ! grep -q $'[\t\r]' "$MANIFEST"
}

@test "manifest: the pattern of the login is the rule of lib/wordpress.sh" {
    [ "$(manifest '[o["pattern"] for o in m["options"] if o["name"] == "admin_user"][0]')" = '^[A-Za-z0-9._@+-]+$' ]
    [ "$(manifest '[o["pattern"] for o in m["options"] if o["name"] == "db_name"][0]')" = '^[A-Za-z_][A-Za-z0-9_]*$' ]
}

@test "manifest: keel validates it and resolves it along lnmp, web and core" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run "$REPO/tests/lib/manifest-root.sh" "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    run env PYTHONPATH="$KEEL_SRC" python3 -m keel manifest validate --root "$BATS_TEST_TMPDIR/root" wordpress
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "manifest: the example specs and the boot test's spec hold against it" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run "$REPO/tests/lib/manifest-root.sh" "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    for spec in keel/instance.example.yaml keel/instance.pair.example.yaml tests/instance.yaml; do
        run env PYTHONPATH="$KEEL_SRC" python3 -m keel spec validate --spec "$REPO/$spec" \
            --no-secret-files --root "$BATS_TEST_TMPDIR/root"
        echo "$spec: $output"
        [ "$status" -eq 0 ]
    done
}

@test "manifest: every spec of this repository names the wordpress appliance and its database account" {
    for spec in keel/instance.example.yaml keel/instance.pair.example.yaml tests/instance.yaml; do
        python3 - "$REPO/$spec" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["appliance"]["name"] == "wordpress", "appliance.name"
assert d["app"]["options"]["db_user"] == "wordpress", "app.options.db_user"
assert d["secrets"]["app_password"], "secrets.app_password"
assert d["secrets"]["db_password"], "secrets.db_password"
PY
    done
}

@test "manifest: the pair example is a primary with a VIP, the listen holds the overlay address" {
    run python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
own = d["network"]["overlay"]["wireguard"]["address"].split("/")[0]
assert d["database"]["server"]["role"] == "primary"
assert d["appliance"]["vip"]
listen = d["database"]["server"].get("listen")
sys.exit(0 if listen is None or own in [str(a) for a in listen] else 1)' "$REPO/keel/instance.pair.example.yaml"
    [ "$status" -eq 0 ]
}

# The boot test's spec writes out every overlay of the chain. The chain
# replicates files (Web's state section and this manifest's), so keel spec
# apply refuses a spec that leaves overlays.syncthing out (decisions 0027,
# 0041), and the first boot writes no Monit file (keel#252, 2026-10-30).
@test "manifest: the boot test's spec declares overlays.syncthing" {
    run python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if (d.get("overlays") or {}).get("syncthing") in ("enabled", "disabled") else 1)' "$REPO/tests/instance.yaml"
    [ "$status" -eq 0 ]
}
