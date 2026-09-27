# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of a recipe, docs/org-plan.md section 1).

## Measured 2026-09-27

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| `overlay/usr/lib/inithooks/lib/wordpress.sh` | `tests/wordpress.bats` (40 tests) | 99.00 percent (99/100) under kcov | every function and every branch |
| `overlay/usr/lib/inithooks/firstboot.d/40wordpress` | `tests/hook.bats` (29 tests) | 97.73 percent (43/44) under kcov | the hook itself, run for real |
| `tests/lib/boot-test-lib.sh` | `tests/boot-test.bats` (64 tests) | 98.82 percent (251/254) under kcov | parsing, addresses, deadlines, the container marks, every verdict |
| `conf.d/zzz-keel-archive` | `tests/keel-archive.bats` (12 tests) | 100 percent (24/24) under kcov | every way it enables and every way it refuses |
| `conf.d/zz-project-packages` | `tests/project-packages.bats` (13 tests) | 100 percent (29/29) under kcov | shared with keel-nodebb, where the pattern is maintained |
| `bin/keel-archive-check` | `tests/archive-check.bats` (8 tests) | 100 percent (26/26) under kcov | same |
| `overlay/usr/lib/inithooks/bin/wordpress.py` | none | 0 | dialog wrapper, only reached with a terminal attached |
| `overlay/usr/lib/inithooks/lib/*.php` | the boot test | integration only | two PHP files `wp eval-file` runs; `conf.d/main` has PHP lint them |
| `conf.d/main` | the build | integration only | build time script, 0004 pragmatic limits |
| `tests/boot-test.sh` | itself | integration only | the thin main of the acceptance test: keel and LXC as root |

Total over the six measured shell files: **98.95 percent (472/477)**, 166 bats
tests, none failing. `tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which the workflow
sets to **97**, the lowest measured file. It is only ever raised (decision
0006).

    $ COVERAGE_THRESHOLD=97 tests/coverage.sh
    kcov line coverage (threshold 97 percent):
      99.00  99/100  wordpress.sh
     100.00  24/24  zzz-keel-archive
      97.73  43/44  40wordpress
      98.82  251/254  boot-test-lib.sh
     100.00  29/29  zz-project-packages
     100.00  26/26  keel-archive-check

### The five lines that are not covered, and why

The hook's one uncovered line is `done < <("$INITHOOKS_PATH/bin/wordpress.py"
...)`, the process substitution of the dialog branch, which kcov attributes no
execution to; the branch itself is covered, by two cases that give the hook a
pty with `script` so `[[ -t 0 ]]` is true. keel-mariadb records the same line
for its own hook.

It used to be nine lines, and eight of them were a measurement artefact worth
removing rather than explaining: the hook carried two PHP programs quoted
inside it, and a quoted PHP program is not shell, so nothing could lint it and
kcov could not say whether it ran. They are now
`lib/wordpress-set-password.php` and `lib/wordpress-verify-login.php`, called
with `wp eval-file`.

## What the hook tests cover

The hook is executed for real against scratch directories, with `systemctl`,
`mysqladmin`, `mysql`, `php`, `wp`, `chown` and `openssl` as `PATH` stubs that
log every call, and a scratch `INITHOOKS_PATH` whose `lib` is a symlink to the
real library, so kcov measures the file the appliance ships. No test needs
root, a database, a web server or a network.

What they are really about is the defect this recipe exists to remove. Upstream
installs WordPress at build time with `DB_PASS=turnkey` and
`ADMIN_PASS=turnkey`, so the tests assert that: the declared description
installs with no dialog at all; `wp-config.php` carries the declared
`secrets.db_password` and none of upstream's values; the administrator's
password never appears in any command the hook runs, and the one that does
carry a `--admin_password` carries a throwaway; the declared password is set
and then *authenticated against the site*, with a wrong one required to fail; a
headless boot with nothing declared fails naming the two fields to declare
rather than installing something; a database that refuses the declared password
is reported as `35mysqlpass`'s failure and not as this hook's; an already
installed site is left alone; and the log says how long each password was and
never what it was.

## The appliance gate

`appliance / build-and-boot` runs through the organization's
`test-appliance.yml` on the self-hosted `keel-lxc` runner, which fetches the
published layer from `https://mirror.keellinux.org/layers`, verifies it,
assembles it, boots it in LXC and runs `tests/boot-test.sh`. Nothing is built
there.

### What the boot test proved against the published layer, 2026-09-27

Against the chain the mirror serves (`core` `7acf2c53`, `mariadb` `0adca434`,
`wordpress` `c9e33fa1`), in a container on `lxcbr0`, every first boot hook from
`01ipconfig` to `98finalize` completed, including `35mysqlpass` of the parent
layer and `40wordpress`:

```
boot-test: port 443 answered 200, title 'Keel WordPress boot test'
boot-test: port 80 answered 200, title 'Keel WordPress boot test'
boot-test: the installer is not offered and the page is a WordPress site
boot-test: wp-config.php names 'wordpress' as 'wordpress' on the local database
boot-test: wp-config.php carries the declared secrets.db_password
boot-test: the database answered: wordpress@localhost	1	1
boot-test: the wordpress database, the wp_users table and the wordpress account all exist
boot-test: the login was accepted and set a wordpress_logged_in_ cookie
boot-test: /wp-admin/ answered 200 with the dashboard for the logged in admin
boot-test: a wrong password was refused
boot-test: https://archive.keellinux.org trixie is enabled and verified with /usr/share/keyrings/keel-archive-keyring.gpg
boot-test: apt-get update read https://archive.keellinux.org trixie and verified its signature
boot-test: apt takes inithooks from https://archive.keellinux.org at priority 1001, candidate 2.3.6+keel5
boot-test: keel-transition is not in the image, which is what makes the next step a proof
boot-test: apt fetched, verified and installed keel-transition 0.1.1 from https://archive.keellinux.org
diff: 6 same, 0 drift, 1 unknown, 5 not declared, 4 not compared
boot-test: wordpress boot test passed
```

The one `unknown` is `network.interfaces.eth0.ipv6.method`, declared `auto`:
`inet6 dhcp` is written for `auto` and for `dhcp` alike and there is no lease to
read offline, which is the documented limitation the other appliances record
too. Exit 13, which the shared verdict reads as no drift.

### How the update half is proved, and how it was proved wrong first

The first version of this test required the archive to offer a **newer**
version of a package the image carries. That is not a property of the
appliance. It is a property of what the archive holds on the day the test
runs, and the only two ways to keep it true are to invent a release or to ship
the image deliberately stale so the archive is always ahead. Both would be
lies told to make a test pass.

The second is also dangerous here, and measuring it is what settled the
argument. `/etc/apt/preferences.d/keel` pins our origin at **1001**, the
priority that downgrades as well as upgrades. With the image one release ahead
of the archive:

```
Installed: 0.1.1
Candidate: 0.1.0
The following packages will be DOWNGRADED:
  keel-archive-keyring
```

and `keel-archive-keyring 0.1.0` ships only the **revoked** signing subkey
`694DE5E8`, so the appliance would have lost the ability to verify the archive
at all. The rule that follows is the one the policy check now guards: **an
image must not carry a project package the signed archive has not got.**

So the test asserts the path instead of the increment, and all three are true
today: `apt-get update` verifies the archive's signature; `apt-cache policy`
shows a project package the image carries with our archive as the source of
its candidate, at the appliance's own pin priority; and `apt-get install
keel-transition`, a project package the image has not got, fetches, verifies
and installs from our archive. apt refuses an unverifiable archive before it
downloads anything, so the last one is the signature check passing on the
bytes that were installed and not only on an index.

Two packages were built and published along the way, both merged work that had
never reached a machine, which is the trap docs/traps.md records:
`keel-archive-keyring 0.1.1` with the rotated key, and `inithooks
2.3.6+keel5`, the fix for a log line killing the hook that renders the conf.

## Plan

- Require `tests / coverage`, `package / changelog` and
  `appliance / build-and-boot` on `master`.
- Rebuild on the `apache-php` layer when it lands, which changes the parent and
  the digest and nothing else here.
- Measure `conf.d/main`. A build time script that runs inside a chroot as root
  is the case decision 0003 splits: the decisions it makes are already in
  `lib/wordpress.sh` and measured, and what is left is the downloads, the SQL
  and the apt calls.
- Move `bin/wordpress.py` to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
