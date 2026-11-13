#!/bin/bash
# Lokaler Build mit Docker oder Podman – dieselben Schritte wie in der CI.
#
# Usage: scripts/local-build.sh <stable|snapshot> [full|any]
# Ergebnis: out/<suite>/source, out/<suite>/debs
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
SUITE=${1:-stable}; MODE=${2:-full}
check_suite "$SUITE"

ENGINE=${ENGINE:-$(command -v podman || command -v docker || true)}
[[ -n $ENGINE ]] || die "weder podman noch docker gefunden"

OUT="$REPO_ROOT/out/$SUITE"
rm -rf "$OUT"; mkdir -p "$OUT"

# shellcheck disable=SC2016 # $HOST_UID wird im Container expandiert
run() {   # <beschreibung> <kommando>
    log "$1"
    "$ENGINE" run --rm \
        -v "$REPO_ROOT:/repo:ro" -v "$OUT:/out" \
        -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        "$DEBIAN_IMAGE" bash -euo pipefail -c "$2"' ; chown -R "$HOST_UID:$HOST_GID" /out'
}

run "Source-Paket" "/repo/scripts/install-deps.sh source && /repo/scripts/prepare-source.sh $SUITE /out/source"
run "Binärpakete + Tests" "/repo/scripts/install-deps.sh binary && /repo/scripts/build-binary.sh /out/source /out/debs $MODE"
run "Smoke-Test (frischer Container)" "/repo/scripts/install-deps.sh smoke && /repo/scripts/smoke-test.sh /out/debs"
log "Fertig: $OUT"
