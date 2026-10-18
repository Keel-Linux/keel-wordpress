#!/usr/bin/env bats
# The exclusion of the WordPress REST API for Coraza (handbook decision 0030,
# overlay coraza). In the cloud modes Coraza reads the JSON body of a request
# as the name of one argument, because the overlay does not select the JSON
# body processor, and the Core Rule Set then blocks the HTML of every block
# of the editor (rule 941180, "<!--" in ARGS_NAMES). The file is read by the
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

@test "waf: one rule, id 10101 (Keel's local ids are 10000 to 10199), phase 1, nolog" {
    [ "$(rules | grep -c 'id:')" = 1 ]
    rules | grep -qF 'id:10101,phase:1,pass,nolog,t:none,chain'
}

@test "waf: it looks at writes to /wp-json/ with a JSON content type, and nothing else" {
    rules | grep -qF 'SecRule REQUEST_METHOD "@rx ^(?:POST|PUT|PATCH)$"'
    rules | grep -qF 'SecRule REQUEST_FILENAME "@beginsWith /wp-json/"'
    rules | grep -qF 'SecRule REQUEST_HEADERS:Content-Type "@rx ^application/json"'
}

@test "waf: it removes the arguments as a target of the Core Rule Set rules, and no rule" {
    rules | grep -qF 'ctl:ruleRemoveTargetByTag=OWASP_CRS;ARGS,'
    rules | grep -qF 'ctl:ruleRemoveTargetByTag=OWASP_CRS;ARGS_NAMES'
    run bash -c "grep -vE '^\s*#' '$RULES' | grep -E 'ruleRemoveById|ruleEngine|SecRuleRemove'"
    [ "$status" -ne 0 ]
}

@test "waf: the file says why, and what to do when the JSON processor arrives" {
    grep -qi 'json' "$RULES"
    grep -qiE 'body processor' "$RULES"
}
