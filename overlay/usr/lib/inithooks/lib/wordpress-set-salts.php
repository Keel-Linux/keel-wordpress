<?php
/*
 * The eight salts of WordPress as options of its database, run by
 * firstboot.d/40wordpress through wp eval-file on a primary or a standalone
 * node. wp-config.php of Keel WordPress defines no salt, so wp_salt() of
 * wp-includes/pluggable.php reads the option "{scheme}_{type}" and makes it
 * when it is missing. This makes them at the first boot, on a server that
 * takes writes, and not at the first request, which may come to a read-only
 * replica. On a cloud pair keel seeds the database to the replica and
 * replicates it: both nodes have the same salts (decision of 2026-11-06).
 * An option that exists is kept, so a run again logs nobody out.
 */
foreach (array('auth', 'secure_auth', 'logged_in', 'nonce') as $scheme) {
    foreach (array('key', 'salt') as $type) {
        $name = "{$scheme}_{$type}";
        if (defined(strtoupper($name))) {
            fwrite(STDERR, strtoupper($name) . " is defined in wp-config.php: the salts would differ on each node\n");
            exit(1);
        }
        if ((string) get_site_option($name, '') !== '') {
            continue;
        }
        if (!update_site_option($name, wp_generate_password(64, true, true))) {
            fwrite(STDERR, "cannot store the option $name\n");
            exit(1);
        }
    }
}
echo "the salts are options of the database\n";
