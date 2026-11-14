#!/bin/bash
# Fügt gebaute Pakete in das APT-Repo (Arbeitskopie des gh-pages-Branches) ein,
# erzeugt die Indizes neu und signiert die Release-Datei der Suite.
#
# Usage: publish.sh <deb-dir> <source-dir> <pages-dir>
#
# Umgebung:
#   REPO_SIGNING_KEY         ASCII-armored Secret-Subkey (aus der GitHub-Environment)
#   REPO_SIGNING_PASSPHRASE  optional
#
# Führt keinen Code aus den Paketen aus; liest nur deren Metadaten.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config

DEBS=$(cd "${1:?}" && pwd); SRC=$(cd "${2:?}" && pwd); PAGES=$(cd "${3:?}" && pwd)
META="$SRC/meta.env"
SUITE=$(meta_get "$META" SUITE); check_suite "$SUITE"
DIST=$(dist_for "$SUITE")
VERSION=$(meta_get "$META" PACKAGE_VERSION)
FPR=$(fpr_for "$SUITE")
KEEP=$(keep_versions_for "$SUITE")
PUBKEY="$REPO_ROOT/keys/repo-$SUITE.asc"

[[ $FPR =~ ^[0-9A-F]{40}$ ]] || die "Fingerprint für $SUITE in config.env fehlt/ungültig"
[[ -s $PUBKEY ]] || die "$PUBKEY fehlt"
[[ -n ${REPO_SIGNING_KEY:-} ]] || die "REPO_SIGNING_KEY ist nicht gesetzt"
[[ $(meta_get "$META" DIST) == "$DIST" ]] || die "meta.env passt nicht zur Konfiguration"

GNUPGHOME=$(mktemp -d); export GNUPGHOME
cleanup() { gpgconf --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"; }
trap cleanup EXIT

# Öffentlichen Schlüssel aus dem Repo prüfen: genau ein Primärschlüssel, gepinnter Fingerprint
mapfile -t fprs < <(gpg --show-keys --with-colons "$PUBKEY" | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10;p=0}')
[[ ${#fprs[@]} -eq 1 && ${fprs[0]} == "$FPR" ]] || die "$PUBKEY passt nicht zu $FPR"
gpg --dearmor < "$PUBKEY" > "$GNUPGHOME/trusted.gpg"

# ---------------------------------------------------------------- Pool aktualisieren
POOL_REL="pool/$DIST/k/keepassxc"
POOL="$PAGES/$POOL_REL"
mkdir -p "$POOL/src"

shopt -s nullglob
debs=("$DEBS"/*.deb)
(( ${#debs[@]} )) || die "keine .deb-Dateien in $DEBS"
for deb in "${debs[@]}"; do
    name=$(basename "$deb")
    [[ $name =~ ^keepassxc(-full|-minimal)?_[A-Za-z0-9.+~%-]+_(amd64|arm64|all)\.deb$ ]] \
        || die "unerwarteter Dateiname: $name"
    [[ $(dpkg-deb -f "$deb" Version) == "$VERSION" ]] || die "$name hat nicht die Version $VERSION"
    if [[ -e $POOL/$name ]]; then
        cmp -s "$deb" "$POOL/$name" || die "$name existiert bereits mit anderem Inhalt (REVISION hochzählen)"
        log "unverändert: $name"
    else
        cp "$deb" "$POOL/$name"; log "neu: $name"
    fi
done

# Source-Paket: eigenes Verzeichnis pro Version (orig-Tarballs können sich sonst überschneiden)
SRCDIR="$POOL/src/${VERSION#*:}"
if [[ -d $SRCDIR ]]; then
    die "Source-Paket $VERSION existiert bereits"
fi
mkdir -p "$SRCDIR"
dscs=("$SRC"/*.dsc)
[[ ${#dscs[@]} -eq 1 ]] || die "erwarte genau eine .dsc"
copy_dsc "${dscs[0]}" "$SRCDIR"

# ---------------------------------------------------------------- Alte Versionen entfernen
mapfile -t versions < <(
    for deb in "$POOL"/*.deb; do dpkg-deb -f "$deb" Version; done | sort -u | sort_debversions
)
if (( ${#versions[@]} > KEEP )); then
    for v in "${versions[@]:0:${#versions[@]}-KEEP}"; do
        log "entferne alte Version $v"
        for deb in "$POOL"/*.deb; do
            [[ $(dpkg-deb -f "$deb" Version) == "$v" ]] && rm -f "$deb"
        done
        rm -rf "${POOL:?}/src/${v#*:}"
    done
fi
shopt -u nullglob

# ---------------------------------------------------------------- Indizes
cd "$PAGES"
D="dists/$DIST"
rm -rf "$D"
for arch in $ARCHES; do
    mkdir -p "$D/main/binary-$arch"
    apt-ftparchive --arch "$arch" packages "$POOL_REL" > "$D/main/binary-$arch/Packages"
done
mkdir -p "$D/main/source"
apt-ftparchive sources "$POOL_REL/src" > "$D/main/source/Sources"
find "$D" -name Packages -o -name Sources | while read -r f; do
    gzip -9nk "$f"; xz -9k "$f"
done

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="$REPO_ORIGIN" \
    -o APT::FTPArchive::Release::Label="$REPO_ORIGIN ($SUITE)" \
    -o APT::FTPArchive::Release::Suite="$DIST" \
    -o APT::FTPArchive::Release::Codename="$DIST" \
    -o APT::FTPArchive::Release::Architectures="$ARCHES" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="KeePassXC-Backports für Debian 13 ($SUITE)" \
    release "$D" > "$GNUPGHOME/Release"
mv "$GNUPGHOME/Release" "$D/Release"

# ---------------------------------------------------------------- Signieren
printf '%s\n' "$REPO_SIGNING_KEY" | gpg --batch --quiet --import
gpg_sign=(gpg --batch --yes --pinentry-mode loopback --local-user "$FPR" --digest-algo SHA512)
if [[ -n ${REPO_SIGNING_PASSPHRASE:-} ]]; then
    printf '%s' "$REPO_SIGNING_PASSPHRASE" > "$GNUPGHOME/pass"
    gpg_sign+=(--passphrase-file "$GNUPGHOME/pass")
fi
"${gpg_sign[@]}" --clearsign --output "$D/InRelease" "$D/Release"
"${gpg_sign[@]}" --armor --detach-sign --output "$D/Release.gpg" "$D/Release"

# Gegen den im Repo eingecheckten öffentlichen Schlüssel prüfen
gpgv --keyring "$GNUPGHOME/trusted.gpg" "$D/InRelease"
gpgv --keyring "$GNUPGHOME/trusted.gpg" "$D/Release.gpg" "$D/Release"
log "Signatur ok"

# ---------------------------------------------------------------- Schlüssel, State, Startseite
mkdir -p keys state
cp "$PUBKEY" "keys/keepassxc-backports-$SUITE.asc"
cp "$GNUPGHOME/trusted.gpg" "keys/keepassxc-backports-$SUITE.gpg"
for k in UPSTREAM_VERSION DEBIAN_BASE SOURCE_ORIGIN PACKAGE_VERSION INPUT_HASH PATCHES; do
    printf '%s=%s\n' "$k" "$(meta_get "$META" "$k")"
done > "state/$SUITE.env"
printf 'PUBLISHED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "state/$SUITE.env"
touch .nojekyll

URL=$(pages_url)

# Fertige deb822-Quelldatei mit eingebettetem Schlüssel (Signed-By inline, apt >= 2.3).
# Nutzer brauchen nur: sudo curl -fsSLo /etc/apt/sources.list.d/<datei> $URL/<datei>
# Format: jede Schlüsselzeile mit einem Leerzeichen eingerückt, Leerzeilen als " .".
SOURCES="keepassxc-backports-$SUITE.sources"
{
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: main\nSigned-By:\n' "$URL" "$DIST"
    sed -e 's/[[:space:]]*$//' -e 's/^$/./' -e 's/^/ /' "$PUBKEY"
} > "$SOURCES"

# Startseite: zeigt die Befehle für alle bereits veröffentlichten Suites
{
    cat <<EOF
<!doctype html>
<html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>KeePassXC Backports</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem}pre{background:#f4f4f4;padding:1rem;overflow-x:auto}</style>
<h1>KeePassXC-Backports für Debian 13 (trixie)</h1>
EOF
    for s in stable snapshot; do
        f="keepassxc-backports-$s.sources"
        [[ -f $f ]] || continue
        case $s in
            stable)   echo "<h2>Stable</h2><p>Geprüfte Versionen, freigegeben nach Review.</p>" ;;
            snapshot) echo "<h2>Snapshot</h2><p>Jeweils neuestes KeePassXC-Release, täglich automatisch gebaut.</p>" ;;
        esac
        printf '<pre>sudo curl -fsSLo /etc/apt/sources.list.d/%s \\\n  %s/%s\nsudo apt update\nsudo apt install keepassxc-full</pre>\n' "$f" "$URL" "$f"
    done
    echo '<p><code>keepassxc-minimal</code> statt <code>keepassxc-full</code>: ohne Browser-Integration, SSH-Agent und Secret Service.</p>'
    echo '<p>Quellcode, Patches und Build-Logs: <a href="https://github.com/'"${GITHUB_REPOSITORY:-tabacha/keepassxc-debian-backports}"'">GitHub</a></p>'
    echo '</html>'
} > index.html
log "Suite $DIST veröffentlicht: $VERSION"
