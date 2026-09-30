# candidate-source.awk: succeeds when the version table of "apt-cache policy"
# lists `uri` at priority `pin` inside the block of `version`, the candidate.
#
# The number on a version line is only the highest priority of that version's
# sources, so it does not say which source the version comes from; the source
# lines under the version do. apt marks the installed version with *** in front
# of it (a current appliance: " *** 2.3.6+keel5 1001"); the marker is dropped.
#
# awk -v version=V -v pin=P -v uri=U -f candidate-source.awk POLICY_FILE
{ if ($1 == "***") { $1 = ""; $0 = $0 } }
$1 == "Version" && $2 == "table:" { table = 1; next }
!table { next }
NF == 2 && $2 ~ /^-?[0-9]+$/ && $1 !~ /^-?[0-9]+$/ { cur = $1; next }
cur == version && $1 == pin && $2 == uri { found = 1 }
END { exit !found }
