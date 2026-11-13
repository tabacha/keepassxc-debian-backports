#!/bin/bash
# PR-Prüfung: Wer Patches/Packaging/Konfiguration ändert, ohne VERSION zu ändern,
# muss REVISION hochzählen. Bei neuer VERSION muss REVISION wieder 1 sein.
#
# Usage: check-revision.sh <base-sha> <head-sha>
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
BASE=${1:?}; HEAD=${2:?}
cd "$REPO_ROOT"

get() { git show "$1:$2" 2>/dev/null | tr -d '[:space:]'; }
v_base=$(get "$BASE" VERSION); v_head=$(get "$HEAD" VERSION)
r_base=$(get "$BASE" REVISION); r_head=$(get "$HEAD" REVISION)

[[ $v_head =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION ungültig: '$v_head'"
[[ $r_head =~ ^[1-9][0-9]*$ ]] || die "REVISION ungültig: '$r_head'"

if [[ $v_head != "$v_base" ]]; then
    [[ $r_head == 1 ]] || die "Neue VERSION $v_head: REVISION muss 1 sein (ist $r_head)"
    log "VERSION $v_base -> $v_head, REVISION 1 – ok"
    exit 0
fi

if git diff --quiet "$BASE" "$HEAD" -- patches packaging config.env; then
    log "Keine Änderungen an patches/, packaging/, config.env – ok"
    exit 0
fi

[[ $r_base =~ ^[0-9]+$ ]] || r_base=0
(( r_head > r_base )) || die "patches/, packaging/ oder config.env geändert: REVISION hochzählen ($r_base -> $((r_base + 1)))"
log "REVISION $r_base -> $r_head – ok"
