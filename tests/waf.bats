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

@test "waf: two rules, ids 10101 and 10102 (Keel's local ids are 10000 to 10199), phase 1, nolog" {
    [ "$(rules | grep -c 'id:')" = 2 ]
    rules | grep -qF 'id:10101,phase:1,pass,nolog,t:none,chain'
    rules | grep -qF 'id:10102,phase:1,pass,nolog,t:none,chain'
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
    [ "$(rules | grep -c 'ruleRemoveTarget')" = 1 ]
    # the second rule changes the limit of the body and nothing else
    [ "$(rules | grep -c 'ctl:')" = 2 ]
}

@test "waf: the file says why, and that the JSON body processor of Coraza is needed" {
    grep -qi 'json' "$RULES"
    grep -qiE 'body processor' "$RULES"
    grep -q 'keel-overlay-coraza 0.1.4' "$RULES"
}
