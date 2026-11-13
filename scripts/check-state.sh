#!/bin/bash
# Vergleicht die Eingaben eines Builds mit dem zuletzt veröffentlichten Stand
# (state/<suite>.env im gh-pages-Branch). Setzt den Output changed=true|false.
#
# Usage: check-state.sh <meta.env>
#
# Die veröffentlichte Datei wird NICHT ausgeführt, nur gezielt geparst.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

META=${1:?usage: $0 <meta.env>}
SUITE=$(meta_get "$META" SUITE); check_suite "$SUITE"
HASH=$(meta_get "$META" INPUT_HASH)
VER=$(meta_get "$META" PACKAGE_VERSION)

[[ -n ${GITHUB_REPOSITORY:-} ]] || { gh_output changed true; exit 0; }

url="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/gh-pages/state/${SUITE}.env"
if ! published=$(curl -fsSL --proto '=https' "$url" 2>/dev/null); then
    log "Noch kein veröffentlichter Stand für $SUITE"
    gh_output changed true
    exit 0
fi

pub_hash=$(sed -n 's/^INPUT_HASH=\([0-9a-f]\{64\}\)$/\1/p' <<< "$published" | head -n1)
pub_ver=$(sed -n 's/^PACKAGE_VERSION=\([A-Za-z0-9.+~:-]*\)$/\1/p' <<< "$published" | head -n1)
log "veröffentlicht: $pub_ver ($pub_hash)"
log "dieser Build:   $VER ($HASH)"

if [[ $pub_hash == "$HASH" ]]; then
    log "Keine Änderungen gegenüber dem veröffentlichten Stand – nichts zu tun."
    gh_output changed false
    exit 0
fi

if [[ $SUITE == stable && $pub_ver == "$VER" ]]; then
    die "Eingaben haben sich geändert, aber die Version $VER ist bereits veröffentlicht. REVISION hochzählen."
fi
gh_output changed true
