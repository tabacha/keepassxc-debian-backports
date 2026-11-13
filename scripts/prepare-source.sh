#!/bin/bash
# Erzeugt das Debian-Source-Paket für eine Suite.
#
# Usage: prepare-source.sh <stable|snapshot> <outdir>
#
# Ablauf:
#   1. Upstream-Version bestimmen (stable: Datei VERSION, snapshot: neuestes GitHub-Release)
#   2. Passendes Debian-Source-Paket aus trixie/forky/sid holen (apt prüft die Hashes
#      gegen die signierten Release-Dateien des Debian-Archivs).
#      Gibt es dort (noch) keins: neuestes Debian-Packaging + Upstream-Tarball via uscan,
#      das die Upstream-GPG-Signatur prüft (Key-Fingerprint gegen config.env gepinnt).
#   3. packaging/*.patch auf debian/ anwenden, patches/ als quilt-Patches anhängen,
#      alle Patches strikt (fuzz=0) anwenden.
#   4. Changelog-Eintrag mit Backport-Version, Source-Paket bauen.
#
# Ergebnis in <outdir>: *.dsc, *.orig.tar.*, *.debian.tar.*, meta.env
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config

SUITE=${1:-}; OUT=${2:-}
check_suite "$SUITE"
[[ -n $OUT ]] || die "usage: $0 <stable|snapshot> <outdir>"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
DIST=$(dist_for "$SUITE")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 1. Upstream-Version
if [[ $SUITE == stable ]]; then
    UP=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
    REVISION=$(tr -d '[:space:]' < "$REPO_ROOT/REVISION")
    [[ $REVISION =~ ^[1-9][0-9]*$ ]] || die "REVISION ungültig: '$REVISION'"
else
    auth=()
    [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    UP=$(curl -fsSL --proto '=https' --tlsv1.2 "${auth[@]}" \
            -H 'Accept: application/vnd.github+json' \
            https://api.github.com/repos/keepassxreboot/keepassxc/releases/latest \
         | jq -r '.tag_name')
    REVISION=0
fi
[[ $UP =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Upstream-Version ungültig: '$UP'"
log "Suite $SUITE ($DIST), Upstream-Version $UP"

# ---------------------------------------------------------------- 2. Debian-Quellen
if [[ -z ${KPXC_SKIP_APT_SETUP:-} ]]; then
    # apt verlangt für dieselbe Quelle (hier: trixie) exakt denselben Signed-By-Wert.
    # Das Image nutzt je nach Stand .pgp oder .gpg – daher den vorhandenen Wert übernehmen.
    KEYRING=$(sed -n 's/^Signed-By:[[:space:]]*\(\/[^[:space:]]*\)[[:space:]]*$/\1/p' \
                  /etc/apt/sources.list.d/debian.sources 2>/dev/null | head -n1)
    if [[ -z $KEYRING ]]; then
        for KEYRING in /usr/share/keyrings/debian-archive-keyring.pgp \
                       /usr/share/keyrings/debian-archive-keyring.gpg; do
            [[ -e $KEYRING ]] && break
        done
    fi
    [[ $KEYRING == /usr/share/keyrings/debian-archive-keyring.* && -e $KEYRING ]] \
        || die "Debian-Archiv-Keyring nicht gefunden (Signed-By: '$KEYRING')"
    log "Archiv-Keyring: $KEYRING"
    cat > /etc/apt/sources.list.d/kpxc-deb-src.sources <<EOF
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: trixie forky sid
Components: main
Signed-By: $KEYRING
EOF
    apt-get update -q
fi

ALL_VERSIONS=$(apt-cache showsrc keepassxc | sed -n 's/^Version: //p' | sort_debversions)
[[ -n $ALL_VERSIONS ]] || die "keine Debian-Quellen für keepassxc gefunden"
log "Debian-Versionen verfügbar: $(echo "$ALL_VERSIONS" | tr '\n' ' ')"

upstream_of() {   # 1:2.8.0+dfsg1-1 -> 2.8.0
    local v=${1#*:}; v=${v%-*}; echo "${v%%+*}"
}

DEBVER=""
while read -r v; do
    [[ $(upstream_of "$v") == "$UP" ]] && DEBVER=$v
done <<< "$ALL_VERSIONS"

fetch_debian_source() {   # <version> <zielverzeichnis>
    local v=$1 dest=$2
    ( cd "$WORK" && apt-get source -q --download-only "keepassxc=$v" )
    dpkg-source --skip-patches -x "$WORK/keepassxc_${v#*:}.dsc" "$dest"
}

cd "$WORK"
if [[ -n $DEBVER ]]; then
    ORIGIN=debian
    log "Nutze Debian-Source-Paket $DEBVER"
    fetch_debian_source "$DEBVER" "$WORK/src"
else
    ORIGIN=upstream
    BASE=$(echo "$ALL_VERSIONS" | tail -n1)
    log "Kein Debian-Paket für $UP – nutze Packaging von $BASE mit Upstream-Tarball"
    fetch_debian_source "$BASE" "$WORK/base"

    # Upstream-Signaturprüfung erzwingen und den Key pinnen
    grep -q 'pgpsigurlmangle' "$WORK/base/debian/watch" \
        || die "debian/watch prüft keine Upstream-Signatur"
    keyfile="$WORK/base/debian/upstream/signing-key.asc"
    [[ -s $keyfile ]] || die "debian/upstream/signing-key.asc fehlt"
    mapfile -t fprs < <(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
                        | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10;p=0}')
    [[ ${#fprs[@]} -eq 1 && ${fprs[0]} == "$UPSTREAM_KEY_FPR" ]] \
        || die "Upstream-Signing-Key passt nicht zum gepinnten Fingerprint (gefunden: ${fprs[*]:-keiner})"

    ( cd "$WORK/base" && uscan --download-version "$UP" --destdir "$WORK" --verbose )

    ORIG=""
    for f in "$WORK"/keepassxc_"$UP"*.orig.tar.*; do
        [[ -e $f && $f != *.asc ]] && ORIG=$f
    done
    [[ -n $ORIG ]] || die "uscan hat kein orig-Tarball erzeugt"
    NEWUP=$(basename "$ORIG"); NEWUP=${NEWUP#keepassxc_}; NEWUP=${NEWUP%.orig.tar.*}

    mkdir "$WORK/src"
    tar -xf "$ORIG" -C "$WORK/src" --strip-components=1
    cp -a "$WORK/base/debian" "$WORK/src/debian"
    DEBVER="${NEWUP}-0"
    ( cd "$WORK/src" && DEBFULLNAME="$MAINTAINER_NAME" DEBEMAIL="$MAINTAINER_EMAIL" \
        dch --check-dirname-level=0 --force-bad-version --newversion "$DEBVER" --distribution UNRELEASED \
            "New upstream release $UP (automatisch, noch nicht in Debian paketiert)." )
fi

# ---------------------------------------------------------------- 3. Patches
cd "$WORK/src"
PATCHES_APPLIED=()

shopt -s nullglob
for p in "$REPO_ROOT"/packaging/*.patch; do
    log "Packaging-Patch: $(basename "$p")"
    patch -p1 --fuzz=0 --forward --no-backup-if-mismatch < "$p" \
        || die "Packaging-Patch $(basename "$p") lässt sich nicht sauber anwenden"
    PATCHES_APPLIED+=("packaging/$(basename "$p")")
done
shopt -u nullglob

mkdir -p debian/patches/kpxc-backports
touch debian/patches/series
add_series() {   # <series-datei> <patch-verzeichnis>
    local series=$1 dir=$2 name
    [[ -f $series ]] || return 0
    while read -r name _; do
        [[ -z $name || $name == \#* ]] && continue
        [[ $name =~ ^[A-Za-z0-9._-]+\.(patch|diff)$ ]] || die "ungültiger Patchname in $series: $name"
        [[ -f $dir/$name ]] || die "Patch $dir/$name aus $series fehlt"
        [[ -e debian/patches/kpxc-backports/$name ]] && die "Patchname doppelt: $name"
        cp "$dir/$name" "debian/patches/kpxc-backports/$name"
        echo "kpxc-backports/$name" >> debian/patches/series
        PATCHES_APPLIED+=("${dir#"$REPO_ROOT"/}/$name")
        log "Quellcode-Patch: ${dir#"$REPO_ROOT"/}/$name"
    done < "$series"
}
add_series "$REPO_ROOT/patches/series" "$REPO_ROOT/patches"
add_series "$REPO_ROOT/patches/$SUITE/series" "$REPO_ROOT/patches/$SUITE"
rmdir debian/patches/kpxc-backports 2>/dev/null || true

# Alle Patches (Debian + eigene) strikt anwenden – bricht ab, wenn einer nicht passt.
rc=0
QUILT_PATCHES=debian/patches QUILT_PC=.pc quilt --quiltrc=/dev/null push -a --fuzz=0 || rc=$?
[[ $rc -eq 0 || $rc -eq 2 ]] || die "quilt: Patches lassen sich nicht sauber anwenden (rc=$rc)"

# ---------------------------------------------------------------- 4. Changelog + Source-Paket
if [[ $SUITE == stable ]]; then
    NEWVER="${DEBVER}~${VERSION_TAG}+${REVISION}"
else
    NEWVER="${DEBVER}~${VERSION_TAG}+0~snap$(date -u +%Y%m%d%H%M)"
fi
log "Paketversion: $NEWVER"

export DEBFULLNAME="$MAINTAINER_NAME" DEBEMAIL="$MAINTAINER_EMAIL"
dch --check-dirname-level=0 --force-bad-version --force-distribution \
    --newversion "$NEWVER" --distribution "$DIST" --urgency medium \
    "Automatischer Backport für Debian 13 (trixie), Suite $SUITE."
dch --check-dirname-level=0 -a "Basis: $ORIGIN $DEBVER."
for p in "${PATCHES_APPLIED[@]}"; do
    dch --check-dirname-level=0 -a "Patch: $p"
done

cd "$WORK"
dpkg-source -b src
DSC="$WORK/keepassxc_${NEWVER#*:}.dsc"
[[ -f $DSC ]] || die "dsc nicht erzeugt"
dcmd cp "$DSC" "$OUT/"

# Fingerprint aller Eingaben (ohne Zeitstempel) – entscheidet, ob neu gebaut werden muss.
INPUT_HASH=$(
    {
        echo "suite=$SUITE upstream=$UP debian=$DEBVER origin=$ORIGIN revision=$REVISION"
        cd "$REPO_ROOT"
        find patches packaging config.env -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum
    } | sha256sum | cut -d' ' -f1
)

cat > "$OUT/meta.env" <<EOF
SUITE=$SUITE
DIST=$DIST
UPSTREAM_VERSION=$UP
DEBIAN_BASE=$DEBVER
SOURCE_ORIGIN=$ORIGIN
PACKAGE_VERSION=$NEWVER
INPUT_HASH=$INPUT_HASH
PATCHES=${PATCHES_APPLIED[*]}
EOF
log "Fertig:"; ls -l "$OUT" >&2
cat "$OUT/meta.env" >&2
