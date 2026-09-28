# Tests

What a test means for an appliance recipe is written in `COVERAGE.md`: the
recipe builds, the result boots in an LXC container, its first boot completes
the WordPress installation headless from an instance description, the site
answers over IPv6 on both ports, the administrator really logs in, the
appliance can update itself from our signed archive, and the machine matches
the spec.

## Layout

- `boot-test.sh`: the boot test. `test-appliance.yml` (reusable workflow of
  `keel-linux/.github`) runs it on the self-hosted LXC runner after pulling the
  layers from `https://mirror.keellinux.org/layers` and checking them with
  `keel verify`. It is the thin main: assemble, mark the tree as a container,
  install the spec, the secrets and the conf, start the container, wait, then
  the proofs. It builds nothing, so it needs no fab, deck or buildtasks.
- `lib/boot-test-lib.sh`: the logic (argument parsing, address discovery from
  `lxc-info`, waiting with a deadline, the container marks, the secret and spec
  paths, and every verdict), as functions with no side effects, per decision
  0004. Same shape as the ones in keel-core, keel-nodebb and the two database
  appliances.
- `boot-test.bats`: unit tests of that library. `lxc-info` is a stub first in
  `PATH`; the clock and `sleep` are functions. No root, no network, no LXC.
- `wordpress.bats`: unit tests of
  `overlay/usr/lib/inithooks/lib/wordpress.sh`, the logic behind the first boot
  hook `40wordpress`.
- `hook.bats`: the hook itself, executed for real against scratch directories
  with `systemctl`, `mysqladmin`, `mysql`, `php`, `wp`, `chown` and `openssl`
  as `PATH` stubs that log every call, and a scratch `INITHOOKS_PATH` whose
  `lib` is a symlink to the real library, so kcov measures the file the
  appliance ships.
- `wrappers.bats`: unit tests of the two operator commands this overlay
  writes, `overlay/usr/local/bin/keel-wp` and
  `overlay/usr/local/sbin/keel-wordpress-update`, and of the `turnkey-wp` and
  `turnkey-wordpress-update` symlinks beside them (decision 0015 of the
  handbook). `runuser`, `chown`, `install` and `id` are `PATH` stubs that log
  every call, and wp-cli is a stub named by `WP_CLI`, so no test needs root, a
  web server or a network. The compatibility names are run rather than
  inspected, once through a copy of the overlay made with `cp -TdR`, which is
  what `fab-apply-overlay` executes.
- `keel-archive.bats`: unit tests of `conf.d/zzz-keel-archive`, the last conf
  script, which enables the project's signed APT archive and refuses to unless
  the key is in the image and the build time source is gone.
- `archive-check.bats`: unit tests of `bin/keel-archive-check`, which the
  Makefile runs twice per build so that the copy of the project archive inside
  the build tree is the archive as it is at build time.
- `project-packages.bats`: unit tests of `conf.d/zz-project-packages`, which
  checks each project package against that archive. `dpkg`, `dpkg-query` and
  `apt-cache` are `PATH` stubs reading fixtures, so no chroot and no apt are
  needed.
- `coverage.sh`: runs the bats files under kcov and fails when any measured
  file is below `COVERAGE_THRESHOLD` (default 95).
- `instance.yaml`: the spec the test container boots from. Not a real site: the
  description an operator starts from is `keel/instance.example.yaml`.

## Unit tests and coverage

Debian packages `bats` (1.11) and `kcov` (43); no root:

    bats tests/wordpress.bats
    bats tests/hook.bats
    bats tests/wrappers.bats
    bats tests/boot-test.bats
    bats tests/keel-archive.bats
    COVERAGE_THRESHOLD=95 tests/coverage.sh

`COVERAGE_DIR=coverage tests/coverage.sh` keeps the kcov reports, one directory
per measured file.

## The boot test by hand

Needs root, `keel` on `PATH`, LXC (`lxc-start`, `lxc-info`, `lxc-attach`,
`lxc-stop`), `curl`, and a bridge with IPv6 router advertisements or DHCPv6.

    tests/boot-test.sh wordpress \
        --layers-dir https://mirror.keellinux.org/layers --bridge lxcbr0

`--layers-dir` is a directory or an http(s) URL, so on the build host it is
`/mnt/builds/layers` and on a runner it is the mirror. The other useful options
are `--bridge`, `--cache-dir`, `--lxc-path`, `--name`, `--timeout`,
`--skip-update` (leaves out the two APT proofs, for a host with no outbound
network) and `--keep` (leaves the container running; then `lxc-attach -n
<name>`). `tests/boot-test.sh --help` lists them all.

A bridge, not macvlan: the host has to be able to reach the container, because
that is where the HTTP and login proofs run from, and a host cannot talk to its
own macvlan children. A long lived demo container is the other way round, and
uses macvlan so it gets an address on the public prefix.

What it proves, in order:

1. `keel pull` and `keel assemble` the chain (core, mariadb, wordpress) into
   `<lxc-path>/<name>/rootfs`.
2. Marks the tree as a container build, which is what `bt_mark_container` does
   and what buildtasks' `patches/container/conf` does for a real container
   image: the marker `var/lib/turnkey-info/inithooks.service/lxc` that `keel
   inspect` reads to call the machine a container (`network.managed_by: host`),
   `REDIRECT_OUTPUT=true` in `etc/default/inithooks`, and a drop-in giving
   `inithooks.service` `StandardOutput=journal`. Without the last two the hooks
   write to `/dev/tty1`, which nobody reads in a container, and the first hook
   that prints more than the terminal buffer holds blocks there forever.
3. Writes a random `root_password`, `db_password` and `app_password` under
   `etc/keel/secrets` (mode 0600) and installs `tests/instance.yaml` at
   `etc/keel/instance.yaml` and `etc/inithooks.yaml`.
4. Renders the spec into the rootfs `etc/inithooks.conf` with `keel spec
   apply`, from a copy whose secret references point inside the rootfs. Without
   the conf the first boot is not headless: `30rootpass`, `35mysqlpass` and
   `40wordpress` open a dialog and wait forever.
5. Writes an LXC config for that rootfs on the bridge and starts the container.
6. Waits for a global IPv6 address (`lxc-info -i`), then for the first boot to
   finish: `RUN_FIRSTBOOT=false` in the rootfs copy of
   `/etc/default/inithooks`, and then confconsole or an SSH banner.
7. **The site**: `https://[address]/` answers 200 with a `<title>`, and so does
   `http://[address]/`. Neither is allowed to redirect.
8. **Not the installer**: the page carries none of the four markers of the
   WordPress installer or of its "there is no wp-config.php" screen, and it
   does carry something only a served WordPress page has.
9. **wp-config.php**: it names the `wordpress` database and the `wordpress`
   account, points at the local database, carries the declared
   `secrets.db_password` and none of upstream's build time values.
10. **The database**: from inside the container, with the secret the container
    already holds, the `wordpress` account connects on `[::1]:3306` and the
    database and its `wp_users` table are both there.
11. **The login**: a POST to `wp-login.php` with the declared password gets a
    redirect and a `wordpress_logged_in_` cookie; `/wp-admin/` then answers 200
    with the dashboard for that cookie; and a wrong password is refused with
    the form and no cookie. Fetching the login page proves nothing, and a check
    that only ever tries the right password cannot tell a working login from a
    site that lets anybody in.
12. **The update path**, in four steps, none of which needs a newer version to
    exist on the day the test runs. The shipped `keel.sources` is enabled for
    the signed `trixie` distribution with our keyring; `apt-get update` inside
    the container reads `https://archive.keellinux.org` and says nothing that
    means it could not verify the signature; `apt-cache policy inithooks` shows
    our archive as the source of the candidate, at the 1001 the appliance's own
    pin file sets; `apt-get download keel-transition`, a project package the
    image has not got, brings it down from our archive against the digest the
    signed index carries; and `apt-get install --reinstall` of a project
    package the image has downloads it again and puts it through dpkg. apt
    refuses an archive it cannot verify before it asks for a single byte, so
    the last two are the signature reaching real files and not only an index.

    All four stay inside our archive on purpose. The CI runner has no IPv4
    route out, so a container there reaches ours, which is IPv6, and nothing of
    Debian's; installing `keel-transition` outright also wants `gpgv`, which a
    Debian 13 image does not carry because apt verifies with `sqv`, so that
    step would be measuring the runner's network rather than the appliance.
13. `keel diff --root <rootfs> --spec tests/instance.yaml`; exit 0 or 13 (no
    drift) passes.

### Measured against the published layer, 2026-09-27

On the build host, in a container on `lxcbr0`, with `--layers-dir
https://mirror.keellinux.org/layers`, so the chain under test is the one the
mirror serves:

```
boot-test: container address fc42:5009:ba4b:5ab0:...
boot-test: first boot finished
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
boot-test: the keel-transition archive is 13836 bytes
boot-test: apt fetched keel-transition from https://archive.keellinux.org, against the digest of the signed index
boot-test: apt fetched and reinstalled keel-archive-keyring 0.1.1 from https://archive.keellinux.org, dpkg configured
diff: 6 same, 0 drift, 1 unknown, 5 not declared, 4 not compared
boot-test: wordpress boot test passed
boot-test: wordpress boot test passed
```

Every first boot hook from `01ipconfig` to `98finalize` completed, including
`35mysqlpass` of the parent layer and `40wordpress`.

The one `unknown` is `network.interfaces.eth0.ipv6.method`, declared `auto`:
`inet6 dhcp` is written for `auto` and for `dhcp` alike and there is no lease to
read offline, which is the documented limitation the other appliances record
too. Exit 13, which the shared verdict reads as no drift.
