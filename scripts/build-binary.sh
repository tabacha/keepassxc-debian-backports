#!/bin/bash
# Baut die Binärpakete aus dem Source-Paket – als unprivilegierter Nutzer, mit Tests.
#
# Usage: build-binary.sh <source-dir> <out-dir> <full|any>
#   full = Arch-abhängige + Arch-unabhängige Pakete (-b), z.B. auf amd64
#   any  = nur Arch-abhängige Pakete (-B), z.B. auf arm64
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SRC=${1:?}; OUT=${2:?}; MODE=${3:?}
case $MODE in full) BOPT=-b ;; any) BOPT=-B ;; *) die "Modus muss full|any sein" ;; esac
[[ $EUID -eq 0 ]] || die "muss als root laufen (installiert Build-Abhängigkeiten)"

# Tests dürfen nicht abgeschaltet werden.
[[ " ${DEB_BUILD_OPTIONS:-} " != *nocheck* ]] || die "DEB_BUILD_OPTIONS enthält nocheck"

shopt -s nullglob
dscs=("$SRC"/*.dsc)
[[ ${#dscs[@]} -eq 1 ]] || die "erwarte genau eine .dsc in $SRC"

id builder >/dev/null 2>&1 || useradd --create-home --shell /bin/bash builder
B=$(mktemp -d /tmp/kpxc-build.XXXXXX)
dcmd cp "${dscs[0]}" "$B/"
chown -R builder: "$B"
cd "$B"

runuser -u builder -- dpkg-source -x "$(basename "${dscs[0]}")" src

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get build-dep -y -q --no-install-recommends ./src

log "dpkg-buildpackage $BOPT"
set -o pipefail
runuser -u builder -- env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/home/builder LANG=C.UTF-8 \
    DEB_BUILD_OPTIONS="parallel=$(nproc)" \
    bash -c "cd '$B/src' && dpkg-buildpackage -us -uc $BOPT" 2>&1 | tee "$B/build.log"

# Sicherstellen, dass die Testsuiten wirklich gelaufen und grün sind:
# 2 Varianten (minimal, full) x 2 Läufe (ohne X, mit xvfb) = 4 ctest-Zusammenfassungen.
passed=$(grep -c 'tests passed, 0 tests failed' "$B/build.log" || true)
log "ctest-Zusammenfassungen ohne Fehler: $passed"
grep -E 'tests passed|tests failed out of' "$B/build.log" >&2 || true
(( passed >= 4 )) || die "erwartet mindestens 4 erfolgreiche ctest-Läufe, gefunden: $passed"
if grep -qE '[1-9][0-9]* tests failed out of' "$B/build.log"; then
    die "es sind Tests fehlgeschlagen"
fi

log "lintian"
changes=("$B"/*.changes)
runuser -u builder -- lintian --fail-on error --info --display-info "${changes[@]}"

mkdir -p "$OUT"
for deb in "$B"/*.deb; do
    [[ $deb == *-dbgsym_* ]] && continue
    cp "$deb" "$OUT/"
done
cp "$B"/*.buildinfo "$B"/*.changes "$B/build.log" "$OUT/"
log "Ergebnis:"; ls -l "$OUT" >&2
