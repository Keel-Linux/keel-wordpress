<?php
/**
 * Plugin Name: Keel replica notice
 * Description: On the replica of a cloud pair the database is read only, so
 * WordPress cannot record a login (its session token is a row of
 * wp_usermeta). Without this file the login page came back empty after a
 * good password, with no word of why (BR2, 2026-11-06). The login page now
 * says that this node is the replica, and a login is refused with that
 * message once the password is checked. On the primary and on a node of
 * the simple mode the database is writable, and nothing changes.
 * Version: 1
 * License: GPL-2.0-or-later
 */

defined('ABSPATH') || exit;

const KEEL_REPLICA_MESSAGE = 'This node is the replica of a cloud pair. Its database is read only, so a login cannot be recorded here. Log in on the primary node.';

/** True when the database server of this node is read only, asked once. */
function keel_replica_read_only()
{
    static $read_only = null;
    if ($read_only === null) {
        global $wpdb;
        $read_only = ((int) $wpdb->get_var('SELECT @@global.read_only')) === 1;
    }
    return $read_only;
}

add_filter('login_message', function ($message) {
    if (!keel_replica_read_only()) {
        return $message;
    }
    return $message . '<div id="keel-replica" class="notice notice-warning message"><p>'
        . esc_html(KEEL_REPLICA_MESSAGE) . '</p></div>';
});

// After the password check of WordPress (priority 20): a good password on
// the replica gets the message, not a silent return to the form.
add_filter('authenticate', function ($user) {
    if (!keel_replica_read_only() || !($user instanceof WP_User)) {
        return $user;
    }
    return new WP_Error('keel_replica', esc_html(KEEL_REPLICA_MESSAGE));
}, 100);
