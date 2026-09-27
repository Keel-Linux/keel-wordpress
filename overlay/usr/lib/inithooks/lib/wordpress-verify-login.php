<?php
/**
 * Ask the site itself whether the administrator can log in.
 *
 * Run by firstboot.d/40wordpress as "wp eval-file", after the password has
 * been set and before Apache is allowed to serve anything. The wrong password
 * is tried too: a check that only ever tries the right one cannot tell a
 * working login from a site that lets anybody in.
 */

$login = getenv('WP_KEEL_USER');
$password = getenv('WP_KEEL_PASS');
if ($login === false || $password === false || $password === '') {
    fwrite(STDERR, "WP_KEEL_USER and WP_KEEL_PASS must both be set\n");
    exit(1);
}
$good = wp_authenticate($login, $password);
if (is_wp_error($good)) {
    fwrite(STDERR, $good->get_error_message() . "\n");
    exit(1);
}
$bad = wp_authenticate($login, $password . '-wrong');
if (!is_wp_error($bad)) {
    fwrite(STDERR, "the site accepted a password that is not the declared one\n");
    exit(1);
}
