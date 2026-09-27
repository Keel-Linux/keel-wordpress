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

# The project's own packages (inithooks, confconsole, keel and, new here,
# keel-archive-keyring) come from the build host's APT repository during the
# build only. The repository is copied into the bootstrap and listed as a
# [trusted=yes] file source, because the staging distribution is unsigned;
# conf.d/zz-project-packages checks what was installed against that copy and
# removes both from the image, and conf.d/zzz-keel-archive then enables the
# signed repository the appliance uses at run time. Same block as
# keel-nodebb, which is where the pattern is maintained.
KEEL_APT_REPO ?= /srv/keel-apt/repo
KEEL_APT_DIST ?= trixie-staging
KEEL_ARCHIVE_CHECK = $(CURDIR)/bin/keel-archive-check $(KEEL_APT_REPO)

# The copy is made fresh and then proved: bin/keel-archive-check compares the
# copied package index with the live one and stops the build when they differ.
define _keel_bootstrap/post

	mkdir -p $O/bootstrap/srv/keel-apt/repo;
	rm -rf $O/bootstrap/srv/keel-apt/repo/dists $O/bootstrap/srv/keel-apt/repo/pool;
	cp -a $(KEEL_APT_REPO)/dists $(KEEL_APT_REPO)/pool $O/bootstrap/srv/keel-apt/repo/;
	$(KEEL_ARCHIVE_CHECK) $O/bootstrap $(KEEL_APT_DIST) $(FAB_ARCH) bootstrap;
	echo "deb [trusted=yes] file:///srv/keel-apt/repo $(KEEL_APT_DIST) main" > $O/bootstrap/etc/apt/sources.list.d/keel-staging.list;
	fab-chroot $O/bootstrap "apt-get update";
endef
bootstrap/post += $(_keel_bootstrap/post)

# bootstrap is a stamped target, so a second build of the same product reuses
# the copy the first one made and a check in bootstrap/post does not run at
# all. On 2026-09-26 "make clean" failed on a busy deck, the stamps survived,
# and the rebuild installed the packages the archive had held that morning
# without a word. So the tree that is about to be configured is checked on
# every build, whether or not this build made the bootstrap.
define _keel_root.patched/pre

	$(KEEL_ARCHIVE_CHECK) $O/root.patched $(KEEL_APT_DIST) $(FAB_ARCH) root.patched;
endef
root.patched/pre += $(_keel_root.patched/pre)
