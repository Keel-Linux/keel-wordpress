# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of a recipe, docs/org-plan.md section 1).

## Measured 2026-09-27

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| `overlay/usr/lib/inithooks/lib/wordpress.sh` | `tests/wordpress.bats` (40 tests) | 99.00 percent (99/100) under kcov | every function and every branch |
| `overlay/usr/lib/inithooks/firstboot.d/40wordpress` | `tests/hook.bats` (29 tests) | 97.73 percent (43/44) under kcov | the hook itself, run for real |
| `tests/lib/boot-test-lib.sh` | `tests/boot-test.bats` (57 tests) | 98.75 percent (237/240) under kcov | parsing, addresses, deadlines, the container marks, every verdict |
| `conf.d/zzz-keel-archive` | `tests/keel-archive.bats` (12 tests) | 100 percent (24/24) under kcov | every way it enables and every way it refuses |
| `conf.d/zz-project-packages` | `tests/project-packages.bats` (13 tests) | 100 percent (29/29) under kcov | shared with keel-nodebb, where the pattern is maintained |
| `bin/keel-archive-check` | `tests/archive-check.bats` (8 tests) | 100 percent (26/26) under kcov | same |
| `overlay/usr/lib/inithooks/bin/wordpress.py` | none | 0 | dialog wrapper, only reached with a terminal attached |
| `overlay/usr/lib/inithooks/lib/*.php` | the boot test | integration only | two PHP files `wp eval-file` runs; `conf.d/main` has PHP lint them |
| `conf.d/main` | the build | integration only | build time script, 0004 pragmatic limits |
| `tests/boot-test.sh` | itself | integration only | the thin main of the acceptance test: keel and LXC as root |

Total over the six measured shell files: **98.92 percent (458/463)**, 159 bats
tests. `tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which the workflow
sets to **97**, the lowest measured file. It is only ever raised (decision
0006).

    $ COVERAGE_THRESHOLD=97 tests/coverage.sh
    kcov line coverage (threshold 97 percent):
      99.00  99/100  wordpress.sh
     100.00  24/24  zzz-keel-archive
      97.73  43/44  40wordpress
      98.75  237/240  boot-test-lib.sh
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

### What the boot test proved on the build host, 2026-09-27

Against the published chain (`core` `7acf2c53`, `mariadb` `0adca434`,
`wordpress`), in a container on `lxcbr0`, every first boot hook from
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
diff: 6 same, 0 drift, 1 unknown, 5 not declared, 4 not compared
```

The one `unknown` is `network.interfaces.eth0.ipv6.method`, declared `auto`:
`inet6 dhcp` is written for `auto` and for `dhcp` alike and there is no lease to
read offline, which is the documented limitation the other appliances record
too. Exit 13, which the shared verdict reads as no drift.

### The one step that has not run green, and why it is not the appliance

`apt-get upgrade` installing a newer project package. The appliance carries
`keel-archive-keyring 0.1.1` and `inithooks 2.3.6+keel4`; the archive offers
`0.1.0` and `+keel4`, so there is nothing newer to upgrade to and the verdict
says exactly that rather than passing quietly:

```
boot-test: the archive offers keel-archive-keyring 0.1.0, which is not newer than 0.1.1
```

Two package versions close it and both are built and waiting in
`/srv/keel-apt/incoming` on the build host:

- **`keel-archive-keyring 0.1.1`** (from `keel-transition` `0.1.1`, merged on
  `main`, never built until tonight). This one is not cosmetic: `0.1.0` ships
  only the **revoked** signing subkey `694DE5E8`, so `gpgv` answers `Can't
  check signature: No public key` against the live archive and an appliance
  carrying it could not verify anything. `0.1.1` carries the current subkey
  `03041024F4B2C0C2F42DDDEA04906EAB77513310` and verifies the archive's
  `InRelease` with a good signature. It was published to `trixie-staging`,
  which is why the layer was rebuilt and now carries it; it has not been
  included into the signed `trixie`.
- **`inithooks 2.3.6+keel5`**, merged on `master` on 2026-09-27 at 03:23 and
  never built: the fix for "a log line must never be able to kill the job"
  (docs/traps.md), which is the hook that renders the conf dying when both
  candidate description paths exist. The archive still offers `+keel4`.

Including those two into `trixie` needs `bin/publish` on the build host, which
is the archive publication step. Once they are there the proof runs with no
change to this repository.

## Plan

- Include the two packages above into `trixie` and rerun the boot test, so
  `apt-get upgrade` is proved and not only `apt-get update`.
- Require `tests / coverage` and `package / changelog` on `master`, and
  `appliance / build-and-boot` once it has run green against the published
  layer.
- Rebuild on the `apache-php` layer when it lands, which changes the parent and
  the digest and nothing else here.
- Measure `conf.d/main`. A build time script that runs inside a chroot as root
  is the case decision 0003 splits: the decisions it makes are already in
  `lib/wordpress.sh` and measured, and what is left is the downloads, the SQL
  and the apt calls.
- Move `bin/wordpress.py` to the same pattern as `bin/setpass.py` in inithooks
  and test it with a Dialog stub when the inithooks fork gains one.
