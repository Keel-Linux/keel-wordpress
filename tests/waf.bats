#!/usr/bin/env bats
# The exclusion of the WordPress REST API for Coraza (handbook decision 0030,
# overlay coraza). In the cloud modes Coraza reads the JSON body of a request
# as the name of one argument, because the overlay did not select the JSON
# body processor (Keel-Linux/common#59, fixed in keel-overlay-coraza 0.1.4).
# Now the fields of the post are json.content, json.title and json.excerpt,
# and the Core Rule Set still blocks the HTML of the blocks of the editor in
# them (rules 941160, 941180, 942190 and others). The file is read by the
# rule set before its own rules, from the plugins directory that the
# coreruleset package provides. These read the file; the cross-site release
# test saves a post through the REST API, behind Anubis and Coraza.

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    RULES="$REPO/overlay/etc/coreruleset/plugins/keel-wordpress-before.conf"
}

rules() {
    grep -vE '^\s*(#|$)' "$RULES"
}

@test "waf: the file is a before-plugin of the Core Rule Set, loaded by coreruleset.load" {
    [ -f "$RULES" ]
    [[ "$(basename "$RULES")" == *-before.conf ]]
}

@test "waf: four rules, ids 10101 to 10104 (Keel's local ids are 10000 to 10199), nolog" {
    [ "$(rules | grep -c 'id:')" = 4 ]
    rules | grep -qF 'id:10101,phase:1,pass,nolog,t:none,chain'
    rules | grep -qF 'id:10102,phase:1,pass,nolog,t:none,chain'
    rules | grep -qF 'id:10103,phase:2,pass,nolog,t:none,t:normalisePath,chain'
    rules | grep -qF 'id:10104,phase:2,pass,nolog,t:none,t:normalisePath,chain'
}

# keel-overlay-coraza 0.1.4 refuses a JSON body of more than 256 KiB
# (Keel-Linux/common#61). A block editor save of a long post is larger. A
# later ctl in phase 1 sets the limit again, to 1 MiB, for these writes.
@test "waf: a JSON write to /wp-json/ may be 1 MiB, and no more" {
    rules | grep -qF 'ctl:requestBodyLimit=1048576'
    [ "$(rules | grep -c 'requestBodyLimit')" = 1 ]
    run bash -c "grep -vE '^\s*#' '$RULES' | grep -E 'requestBodyAccess|requestBodyLimit=[0-9]{8,}'"
    [ "$status" -ne 0 ]
}

@test "waf: it looks at writes to /wp-json/ with a JSON content type, and nothing else" {
    rules | grep -qF 'SecRule REQUEST_METHOD "@rx ^(?:POST|PUT|PATCH)$"'
    rules | grep -qF 'SecRule REQUEST_FILENAME "@beginsWith /wp-json/"'
    rules | grep -qF 'SecRule REQUEST_HEADERS:Content-Type "@rx ^application/json"'
}

@test "waf: it removes the content fields of the post as a target of the Core Rule Set rules, and no rule" {
    rules | grep -qF 'ctl:ruleRemoveTargetByTag=OWASP_CRS;ARGS:/^json\.(?:content|title|excerpt)(?:\.raw)?$/'
    run bash -c "grep -vE '^\s*#' '$RULES' | grep -E 'ruleRemoveById|ruleEngine|SecRuleRemove'"
    [ "$status" -ne 0 ]
}

@test "waf: every other argument and every name keeps its rules" {
    run bash -c "grep -vE '^\s*#' '$RULES' | grep -E 'ARGS_NAMES|OWASP_CRS;ARGS[,\"]'"
    [ "$status" -ne 0 ]
    [ "$(rules | grep -c 'ruleRemoveTargetByTag')" = 1 ]
    # the second rule changes the limit of the body and nothing else
    [ "$(rules | grep -c 'ctl:requestBodyLimit')" = 1 ]
    # the login rules lift two rules from redirect_to and nothing else
    [ "$(rules | grep -o 'ctl:[^,"]*' | sort | uniq -c | wc -l)" = 4 ]
    [ "$(rules | grep -c 'ctl:ruleRemoveTargetById=931100;ARGS:redirect_to,ctl:ruleRemoveTargetById=932130;ARGS:redirect_to"')" = 2 ]
}

# Opened by IP before the name points to the machine (decision 0079), the
# login form's redirect_to names an IP, and CRS 931100 and 932130 refused
# the login with 403 (BR1 and BR2, 2026-11-06). Measured on those nodes
# with the rules in place: the login by IPv6 and by IPv4 passed; another
# host, a longer name that starts with the address, an SQL injection in
# redirect_to and two redirect_to were still refused with 403.
@test "waf: the login by IP lifts 931100 and 932130 from redirect_to, on /wp-login.php only" {
    [ "$(rules | grep -cF 'SecRule REQUEST_FILENAME "@streq /wp-login.php"')" = 2 ]
    [ "$(rules | grep -cF 'SecRule &ARGS:redirect_to "@eq 1"')" = 2 ]
    [ "$(rules | grep -cF 'capture,chain')" = 2 ]
    rules | grep -qF 'SecRule ARGS:redirect_to "@beginsWith https://%{tx.0}/"'
    rules | grep -qF 'SecRule ARGS:redirect_to "@beginsWith http://%{tx.0}/"'
}

@test "waf: the Host of a login rule is a name or an address, with a port, and nothing else" {
    re=$(rules | sed -n 's/.*SecRule REQUEST_HEADERS:Host "@rx \(.*\)" \\$/\1/p' | sort -u)
    [ "$(printf '%s\n' "$re" | wc -l)" = 1 ]
    for good in example.org 10.0.0.1 '[2001:db8::1]' '[2001:db8::1]:8443' example.org:443; do
        printf '%s\n' "$good" | grep -qP "$re" || { echo "refused: $good"; return 1; }
    done
    for bad in 'example.org/x' 'a b' 'example.org:443:1' '[2001:db8::1' 'user@example.org'; do
        if printf '%s\n' "$bad" | grep -qP "$re"; then echo "taken: $bad"; return 1; fi
    done
}

@test "waf: the file says why, and that the JSON body processor of Coraza is needed" {
    grep -qi 'json' "$RULES"
    grep -qiE 'body processor' "$RULES"
    grep -q 'keel-overlay-coraza 0.1.4' "$RULES"
}
