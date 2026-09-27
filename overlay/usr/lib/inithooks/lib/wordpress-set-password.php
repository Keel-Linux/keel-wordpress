<?php
/**
 * Give the WordPress administrator the declared password.
 *
 * Run by firstboot.d/40wordpress as "wp eval-file". The login and the
 * password come from the environment and never from an argument, because an
 * argument is readable by every process on the machine while the command
 * runs.
 */

$login = getenv('WP_KEEL_USER');
$password = getenv('WP_KEEL_PASS');
if ($login === false || $password === false || $password === '') {
    fwrite(STDERR, "WP_KEEL_USER and WP_KEEL_PASS must both be set\n");
    exit(1);
}
$user = get_user_by('login', $login);
if (!$user) {
    fwrite(STDERR, "no WordPress account named '$login'\n");
    exit(1);
}
wp_set_password($password, $user->ID);
clean_user_cache($user->ID);
