# keel-wordpress: WordPress on Apache and PHP, built as a layer on the
# published mariadb layer.
#
#     bt-layer wordpress --parent mariadb
#
# Compatible with TurnKey Linux appliances: this is turnkeylinux-apps/wordpress
# with the database half taken out, because the database is already a layer of
# its own that is built, tested and published (keel-mariadb). The delta this
# recipe produces is Apache, PHP, WordPress and nothing else.
#
# Why not lamp.mk: it pulls Adminer in, and Adminer brings a second first boot
# hook at 35 that also reads DB_PASS, for an account this appliance does not
# use. The panel core already carries administers the database through
# webmin-mysql, which the parent layer installs. So the three mk files LAMP is
# made of are included directly and Adminer is left out, the same way the
# parent layer leaves it out (its README.rst says why).
#
# PHP_* are read by common/conf/php. They are raised over the Debian defaults
# because a media library is the first thing a WordPress is asked to hold.
PHP_MEMORY_LIMIT = 256M
PHP_UPLOAD_MAX_FILESIZE = 64M
PHP_POST_MAX_SIZE = 64M
PHP_MAX_EXECUTION_TIME = 120

# The ports the appliance answers on: 80 and 443 are the site, 12320 the web
# shell core carries, 12321 Webmin. 3306 is deliberately absent, although the
# parent layer opened it: this appliance reaches its own database over the
# loopback and nothing outside it has any business there.
WEBMIN_FW_TCP_INCOMING = 22 80 443 12320 12321

include $(FAB_PATH)/common/mk/turnkey/apache.mk
include $(FAB_PATH)/common/mk/turnkey/php.mk
include $(FAB_PATH)/common/mk/turnkey/mysql.mk

# After the mk files above, so a file of this overlay wins over a shared one.
COMMON_OVERLAYS += $(CURDIR)/overlay

include $(FAB_PATH)/common/mk/turnkey.mk

# The project's own packages (inithooks, confconsole, keel and keel-archive-
# keyring) come from the build host's APT repository during the build only.
# The repository is copied into the bootstrap and the build verifies it there,
# the way an appliance verifies the release archive (tracker#7): the public
# half of the staging key is installed as a keyring, the source entry names it
# through signed-by, nothing in the tree says trusted=yes, and apt runs with
# --error-on=any, so a signature that cannot be checked fails the build
# instead of warning about it and carrying on. conf.d/zz-project-packages
# checks what was installed against that copy and removes the copy, the source
# entry and the keyring from the image, and conf.d/zzz-keel-archive then
# enables the signed repository the appliance uses at run time.
#
# None of the three build time files is for an installed appliance, because
# the staging key signs whatever the build host produced. The removelist at
# common/removelists-final/turnkey takes all three out of the image as well,
# whatever a recipe does. Same block as keel-nodebb, which is where the pattern is maintained.
KEEL_APT_REPO ?= /srv/keel-apt/repo
KEEL_APT_DIST ?= trixie-staging
# Beside the repository rather than inside it: bin/publish of keel-linux/apt
# installs the public half of whichever key it signed a distribution with
# here, so the key a build verifies with cannot drift from the key the archive
# was signed with.
KEEL_APT_KEYRING ?= /srv/keel-apt/keys/keel-staging-keyring.asc
# Where that key goes in the build tree, and which key has to be in it: the
# staging signing subkey (handbook decision 0011). A keyring is only a promise
# until the key inside it is named, so bin/keel-archive-check fails the build
# when the keyring it finds holds some other key.
KEEL_APT_KEYRING_PATH ?= /etc/apt/keyrings/keel-staging-keyring.asc
KEEL_APT_KEY ?= 8CFD1A4841448B2227341CEB202CACBD0E97090A
KEEL_STAGING_LIST ?= /etc/apt/sources.list.d/keel-staging.list
KEEL_ARCHIVE_CHECK = KEEL_ARCHIVE_KEY=$(KEEL_APT_KEY) \
	KEEL_ARCHIVE_KEYRING=$(KEEL_APT_KEYRING_PATH) \
	KEEL_ARCHIVE_LIST=$(KEEL_STAGING_LIST) \
	$(CURDIR)/bin/keel-archive-check $(KEEL_APT_REPO)

# The copy is made fresh and then proved: bin/keel-archive-check compares the
# copied package index with the live one, verifies the signature on the copied
# InRelease against the keyring, refuses any trusted=yes, and stops the build
# when one of them is wrong.
define _keel_bootstrap/post

	mkdir -p $O/bootstrap/srv/keel-apt/repo $O/bootstrap$(dir $(KEEL_APT_KEYRING_PATH));
	rm -rf $O/bootstrap/srv/keel-apt/repo/dists $O/bootstrap/srv/keel-apt/repo/pool;
	cp -a $(KEEL_APT_REPO)/dists $(KEEL_APT_REPO)/pool $O/bootstrap/srv/keel-apt/repo/;
	install -m 644 $(KEEL_APT_KEYRING) $O/bootstrap$(KEEL_APT_KEYRING_PATH);
	echo "deb [signed-by=$(KEEL_APT_KEYRING_PATH)] file:///srv/keel-apt/repo $(KEEL_APT_DIST) main" > $O/bootstrap$(KEEL_STAGING_LIST);
	$(KEEL_ARCHIVE_CHECK) $O/bootstrap $(KEEL_APT_DIST) $(FAB_ARCH) bootstrap;
	fab-chroot $O/bootstrap "apt-get update --error-on=any";
endef
bootstrap/post += $(_keel_bootstrap/post)

# bootstrap is a stamped target, so a second build of the same product reuses
# the copy the first one made and a check in bootstrap/post does not run at
# all. On 2026-09-26 "make clean" failed on a busy deck, the stamps survived,
# and the rebuild installed the packages the archive had held that morning
# without a word. So the tree that is about to be configured is checked on
# every build, whether or not this build made the bootstrap. That check
# verifies the signature with gpgv too, which is what proves this tree at a
# step where no apt-get update runs.
define _keel_root.patched/pre

	$(KEEL_ARCHIVE_CHECK) $O/root.patched $(KEEL_APT_DIST) $(FAB_ARCH) root.patched;
endef
root.patched/pre += $(_keel_root.patched/pre)
