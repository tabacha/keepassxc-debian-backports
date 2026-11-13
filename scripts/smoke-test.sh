#!/bin/bash
# Installations- und Funktionstest in einem FRISCHEN debian:trixie-Container.
#
# Usage: smoke-test.sh <deb-dir>
#
#  1. keepassxc-full aus Debian 13 installieren, damit eine Datenbank anlegen
#  2. Upgrade auf die gebauten Pakete, alte Datenbank lesen, neue anlegen
#  3. Wechsel auf keepassxc-minimal, Datenbanken erneut lesen
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

DEBS=$(cd "${1:?usage: $0 <deb-dir>}" && pwd)
[[ $EUID -eq 0 ]] || die "muss als root laufen"
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q --no-install-recommends)

shopt -s nullglob
full=("$DEBS"/keepassxc-full_*.deb)
minimal=("$DEBS"/keepassxc-minimal_*.deb)
[[ ${#full[@]} -eq 1 && ${#minimal[@]} -eq 1 ]] || die "keepassxc-full/-minimal .deb nicht gefunden in $DEBS"
EXPECTED=$(dpkg-deb -f "${full[0]}" Version)

T=$(mktemp -d)
PW='correct horse battery staple'
SECRET="s3cr3t-$RANDOM"

create_db() {   # <db> <entry> <secret>
    printf '%s\n%s\n' "$PW" "$PW" | keepassxc-cli db-create -p "$1" >/dev/null
    printf '%s\n%s\n%s\n' "$PW" "$3" "$3" | keepassxc-cli add -q -u alice -p "$1" "$2"
}
check_db() {    # <db> <entry> <secret>
    local got
    got=$(printf '%s\n' "$PW" | keepassxc-cli show -q -s -a Password "$1" "$2")
    [[ $got == "$3" ]] || die "Passwort in $1/$2 stimmt nicht (bekommen: '$got')"
    log "OK: $1/$2 lesbar"
}
check_version() {   # <paket>
    local v
    v=$(dpkg-query -W -f '${Version}' "$1")
    [[ $v == "$EXPECTED" ]] || die "$1 hat Version $v, erwartet $EXPECTED"
    keepassxc-cli --version
    QT_QPA_PLATFORM=offscreen keepassxc --version
    log "OK: $1 $v"
}

apt-get update -q

log "1. Debian-13-Version installieren"
"${APT[@]}" install keepassxc-full
keepassxc-cli --version
create_db "$T/old.kdbx" Alt "$SECRET-alt"
check_db "$T/old.kdbx" Alt "$SECRET-alt"

log "2. Upgrade auf $EXPECTED"
"${APT[@]}" install "${full[0]}"
check_version keepassxc-full
check_db "$T/old.kdbx" Alt "$SECRET-alt"
create_db "$T/new.kdbx" Neu "$SECRET-neu"
check_db "$T/new.kdbx" Neu "$SECRET-neu"
keepassxc-cli generate -L 32 >/dev/null
keepassxc-cli diceware -W 6 >/dev/null

log "3. Wechsel auf keepassxc-minimal"
"${APT[@]}" remove keepassxc-full
"${APT[@]}" install "${minimal[0]}"
check_version keepassxc-minimal
check_db "$T/old.kdbx" Alt "$SECRET-alt"
check_db "$T/new.kdbx" Neu "$SECRET-neu"

transitional=("$DEBS"/keepassxc_*_all.deb)
if (( ${#transitional[@]} )); then
    log "4. Übergangspaket keepassxc"
    "${APT[@]}" install "${transitional[0]}"
    dpkg-query -W keepassxc keepassxc-minimal
fi

rm -rf "$T"
log "Smoke-Test bestanden"
