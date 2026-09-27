WordPress - Blog Publishing Platform
====================================

`WordPress`_ is a state-of-the-art publishing platform with a focus on
aesthetics, web standards, and usability. It is one of the worlds most
popular blog publishing applications, includes tons of powerful core
functionality, extendable via literally thousands of plugins, and
supports full theming.

This appliance includes all the standard features in `TurnKey Core`_,
and on top of that:

- WordPress configurations:
   
   - Installed from upstream source code to /var/www/wordpress
   - Integrated upgrade mechanism: get WordPress updates straight from
     WordPress' creator Automattic.
   - Uploading of media such as images, videos, etc.
   - Permalinks configuration supported through admin console
     (convenience)
   - Plugin and theme management remains available through WordPress. These
     directories intentionally contain web-writable executable code; install
     only updates and extensions you trust.
   - WordPress core is root-owned and does not update automatically. Apply a
     supervised core update as ``root`` with ``turnkey-wordpress-update``.
     The command verifies official WordPress core checksums and restores the
     appliance ownership boundary after updating.
               
- Landing page provides links to `WordPress plugin search`_, plus a number of
  useful and popular Wordpress plugins (none pre-installed):
   
   - `Yost SEO`_: Optimizes your WordPress blog for search engines and XML
     sitemaps.
   - `NextGEN Gallery`_: Easy to use image gallery with thumbnail & slideshow
     options.
   - `JetPack by WordPress.com`_: Jetpack adds powerful features previously
     only available to WordPress.com users including customization,
     traffic, mobile, content, and performance tools.
   - `WP Super Cache`_: Accelerates your blog by serving 99% of your
     visitors via static HTML files.
   - `Social Media Share Buttons & Icons`_: Promote your content by adding
     links to social sharing and bookmarking sites.
   - `Simple Tags`_: automatically adds tags and related posts to your
     content.
   - `BackupWordPress`_: easily backup your core WordPress tables.
   - `Google Analytics Dashboard for WordPress`_: track visitors, AdSense
     clicks, outgoing links, and search queries.
   - `WP-Polls`_: Adds an easily customizable AJAX poll system to your
     blog.
   - `WP-PageNavi`_: Adds more advanced paging navigation.
   - `Ozh admin dropdown menu`_: Creates a drop down menu with all admin
     links.
   - `Contact Form 7`_: Customizable contact forms supporting AJAX,
     CAPTCHA and Akismet integration.
   - `Seriously Simple Podcasting`_: Simple Podcasting from your WordPress
     site.

- SSL support out of the box.
- `Adminer`_ administration frontend for MySQL (listening on port
  12322 - uses SSL).
- Postfix MTA (bound to localhost) to allow sending of email (e.g.,
  password recovery).
- Webmin modules for configuring Apache2, PHP, MySQL (MariaDB) and Postfix.

See the `WordPress docs`_ for further details (including multisite
howto).

Keel Linux: the layer, the first boot and the update path
---------------------------------------------------------

This appliance is built as a Keel layer, not as a whole root filesystem::

    bt-layer wordpress --parent mariadb

**The parent is the published ``mariadb`` layer today, and it will move.** That
layer is already built, tested and published, so what this recipe adds is
Apache, PHP and WordPress and nothing else. An ``apache-php`` layer is being
extracted; when it lands, this appliance's parent becomes that layer and the
``wordpress`` layer is rebuilt on it. Nobody should be surprised by that: layers
are content addressed, so a new parent means a new digest and a cheap rebuild,
and ``.github/workflows/tests.yml`` and this section are the two places that
name the parent.

Nothing is decided at build time
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Upstream's ``conf.d/main`` installs WordPress while the image is being built,
with ``DB_PASS=turnkey`` and ``ADMIN_PASS=turnkey`` written in the recipe. A
layer is published once and reused by every machine built on it, so those are
the same two passwords on every one of them. This recipe leaves the layer with
no credential at all: no ``wp-config.php``, and a database account created with
a password hash that no input produces.

The installation happens on the first boot, from
``/etc/keel/instance.yaml``, and the WordPress installer is never offered to a
visitor. ``firstboot.d/40wordpress`` reads:

===========================  ==================================================
``app.options.site_title``   the site title
``app.options.admin_user``   the WordPress administrator's login
``secrets.app_password``     that administrator's password
``secrets.db_password``      the database password, which the parent layer's
                             ``35mysqlpass`` has already given to the database
``app.options.db_user``      the database account (the same field the parent
                             layer reads, so one declaration serves both)
``app.options.db_name``      the database
``app.email``                the administrator's address
``app.domain``              the site URL recorded at install time
===========================  ==================================================

Every secret is a file reference in the instance description, never a literal.
Neither password is ever an argument of another process: ``wp-config.php`` is
written by a shell function, and the administrator's password is set through
the environment of one ``wp-cli`` call. The hook finishes by asking the site to
authenticate that account, and to refuse a wrong password, before it lets
Apache serve anything.

``wp-config.php`` derives ``WP_HOME`` and ``WP_SITEURL`` from the ``Host``
header of each request rather than reading them from the database, so the site
answers on whatever address or name reaches it. A WordPress whose recorded site
URL is not the one it is reached by answers a permanent redirect to the
recorded one, which for an appliance reached by its IPv6 literal means sending
the visitor to a name that does not resolve. The recorded URL is the fallback
for WP-CLI and ``wp-cron``, which carry no ``Host`` header.

The salts in ``wp-config.php`` are generated on the machine rather than fetched
from WordPress's API, because a first boot must not need the internet.

What our archive updates, and what it does not
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The appliance ships ``/etc/apt/sources.list.d/keel.sources`` **enabled** for
the signed ``trixie`` distribution of ``https://archive.keellinux.org``, with
``Signed-By`` naming ``/usr/share/keyrings/keel-archive-keyring.gpg`` from the
``keel-archive-keyring`` package, and ``/etc/apt/preferences.d/keel`` pins that
origin at 1001. So on a booted appliance::

    apt-get update      # reads our archive and verifies its signature
    apt-get upgrade     # takes newer Debian and newer project packages
    apt-get install keel-transition   # installs a project package from us

covers two things:

- **the system**, from Debian and Debian security, as any Debian machine does;
- **the project's own packages**: ``inithooks``, ``confconsole``, ``keel``,
  ``keel-archive-keyring``, ``keel-transition``, ``fab``.

The boot test proves that path rather than proving that a newer version
happens to exist on the day it runs. It asserts that ``apt-get update``
verifies our archive's signature, that ``apt-cache policy`` shows a project
package the image carries with our archive as the source of its candidate at
that pin priority, and that ``apt-get install`` of ``keel-transition``, which
the image does not carry, fetches it from our archive, verifies it and
installs it. apt refuses an unverifiable archive before it downloads anything,
so the third one is the signature check passing on the bytes that were
installed and not only on an index.

It does **not** cover WordPress core, and saying otherwise would be a lie in
the documentation. Nobody packages WordPress for Debian and we do not package
it either: it is unpacked from a release archive pinned by digest in
``conf.d/main`` and verified a second time against WordPress's own per file
checksums. WordPress core therefore updates through WordPress's own mechanism,
either from the dashboard or, preferably on this appliance, with::

    turnkey-wordpress-update

which runs ``wp core update``, verifies WordPress's checksums again and puts
the ownership boundary back: core and ``wp-config.php`` root owned, and only
``wp-content/uploads``, ``cache``, ``upgrade``, ``plugins`` and ``themes``
writable by the web server. Automatic core updates are off in
``wp-config.php`` for the same reason: a supervised update keeps that
boundary, an unsupervised one does not.

One consequence of the pin worth knowing, because it is a priority that
downgrades as well as upgrades: an image must not carry a project package that
the signed archive has not got. If it does, ``apt-get upgrade`` replaces the
newer installed package with the archive's older one. The boot test's policy
check is where that shows up.

Plugins and themes are WordPress's business and are installed through
WordPress. Those two directories are deliberately web writable, which means
they hold executable code the web server can change: install only what you
trust.

Ports, and what listens
~~~~~~~~~~~~~~~~~~~~~~~~

80 and 443 are the site, on both address families; 12320 is the web shell and
12321 Webmin, both from Core. 3306 is **closed**, although the parent layer
opens it: this appliance reaches its own database over the loopback, and
``wp-config.php`` names ``[::1]``. ``/etc/cron.d/wordpress-cron`` reaches
``wp-cron.php`` over the IPv6 loopback literal, because on Debian
``localhost`` is an IPv4 name only.

Adminer, ``lighttpd`` and the rest of ``turnkey/lamp`` are left out. The
database is administered through ``webmin-mysql`` in the panel Core already
carries, and Adminer would bring a second first boot hook at 35 reading the
same ``DB_PASS`` for an account this appliance does not use. The parent layer's
own ``admin`` database account is left unable to authenticate unless an
instance declares it, which is the state that layer publishes it in.

Running one
~~~~~~~~~~~~

``keel/instance.example.yaml`` is the description to start from, and
``tests/README.md`` is how to boot and check one by hand. The appliance's own
view of itself, on the machine::

    keel diff --spec /etc/keel/instance.yaml


Credentials *(passwords set at first boot)*
-------------------------------------------

Every password comes from the instance description; none is set here and none
is typed at a console on a headless first boot.

-  Webmin and SSH: username **root**, from ``secrets.root_password``
-  the WordPress database account: username **wordpress**
   (``app.options.db_user``), from ``secrets.db_password``
-  WordPress: username **admin** (``app.options.admin_user``), from
   ``secrets.app_password``

Adminer is not installed, so it has no account here.


.. _WordPress: https://wordpress.org
.. _TurnKey Core: https://www.turnkeylinux.org/core
.. _WordPress plugin search: https://wordpress.org/plugins/
.. _Yost SEO: https://wordpress.org/plugins/wordpress-seo/
.. _NextGEN Gallery: https://wordpress.org/plugins/nextgen-gallery/
.. _JetPack by WordPress.com: https://wordpress.org/plugins/jetpack/
.. _WP Super Cache: https://wordpress.org/plugins/wp-super-cache/
.. _Social Media Share Buttons & Icons: https://wordpress.org/plugins/ultimate-social-media-icons/
.. _Simple Tags: https://wordpress.org/plugins/simple-tags/
.. _BackupWordPress: https://wordpress.org/plugins/backupwordpress/
.. _Google Analytics Dashboard for WordPress: https://wordpress.org/plugins/google-analytics-for-wordpress/
.. _WP-Polls: https://wordpress.org/plugins/wp-polls/
.. _WP-PageNavi: http://wordpress.org/plugins/wp-pagenavi/
.. _Ozh admin dropdown menu: https://wordpress.org/plugins/ozh-admin-drop-down-menu/
.. _Contact Form 7: https://wordpress.org/plugins/contact-form-7/
.. _Seriously Simple Podcasting: https://wordpress.org/plugins/seriously-simple-podcasting/
.. _Adminer: https://www.adminer.org/
.. _WordPress docs: https://www.turnkeylinux.org/docs/wordpress
