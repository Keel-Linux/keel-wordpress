# keel-wordpress: WordPress on nginx and PHP-FPM, built as a layer on the
# lnmp layer (handbook decisions 0047 and 0059):
#
#     bt-layer wordpress --parent lnmp
#
# lnmp brings Keel Web's nginx, PHP-FPM 8.4 and MariaDB 11.8 with the first
# boot hooks of the database and the check page at /keel-check/. The delta
# this recipe produces is the PHP modules WordPress wants, WordPress, wp-cli,
# its route in /etc/nginx/keel-default.d/, its first boot hook and its
# manifest. Apache is not part of it: Keel retired Apache (0059), and
# common's apache.mk, lamp.mk and Adminer are not used.
#
# PHP_* are read by common's conf/php. They are raised over lnmp's because a
# media library is the first thing a WordPress is asked to hold. The route
# of the overlay sets client_max_body_size and fastcgi_read_timeout to the
# same values.
PHP_MEMORY_LIMIT = 256M
PHP_UPLOAD_MAX_FILESIZE = 64M
PHP_POST_MAX_SIZE = 64M
PHP_MAX_EXECUTION_TIME = 120

include $(FAB_PATH)/common/mk/turnkey/php-fpm.mk

# After the mk files, so a file of this overlay wins over a shared one.
COMMON_OVERLAYS += $(CURDIR)/overlay

# 80 and 443 are Web's, 12321 the panel, as in lnmp. 3306 is not opened:
# MariaDB is on the loopback, and on a pair on the mesh (lnmp's manifest says
# mesh). The web shell of the old layer is not in Core any more.
WEBMIN_FW_TCP_INCOMING = 22 80 443 12321

include $(FAB_PATH)/common/mk/turnkey.mk

# The checks conf.d/main runs on the tree: the project packages at the
# archive's candidate (bin/keel-project-packages) and the image as a first
# boot of WordPress starts from (bin/keel-wordpress-image-check). They are
# copied in before the conf scripts run, and conf.d/main removes them again.
KEEL_BUILD_TOOLS ?= /usr/local/lib/keel-build
define _keel_root.patched/pre

	install -D -m 755 $(CURDIR)/bin/keel-project-packages $O/root.patched$(KEEL_BUILD_TOOLS)/keel-project-packages;
	install -D -m 755 $(CURDIR)/bin/keel-wordpress-image-check $O/root.patched$(KEEL_BUILD_TOOLS)/keel-wordpress-image-check;
endef
root.patched/pre += $(_keel_root.patched/pre)
