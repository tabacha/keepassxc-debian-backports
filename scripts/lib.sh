# shellcheck shell=bash
# Gemeinsame Hilfsfunktionen. Wird von den anderen Skripten per "source" geladen.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
    [[ -n ${GITHUB_ACTIONS:-} ]] && printf '::error::%s\n' "$*"
    exit 1
}

# In GitHub Actions jeden fehlgeschlagenen Befehl als Annotation melden
# (in der Run-Übersicht sichtbar, auch ohne Zugriff auf das volle Log).
if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    set -E
    # shellcheck disable=SC2154 # rc wird im Trap selbst gesetzt
    trap 'rc=$?; printf "::error file=%s,line=%s::rc=%s bei: %s\n" "${BASH_SOURCE[0]#"$REPO_ROOT"/}" "$LINENO" "$rc" "$BASH_COMMAND"' ERR
fi

load_config() {
    # shellcheck source=../config.env
    . "$REPO_ROOT/config.env"
}

check_suite() {
    [[ ${1:-} == stable || ${1:-} == snapshot ]] || die "suite muss 'stable' oder 'snapshot' sein (war: '${1:-}')"
}

dist_for() {
    case $1 in
        stable)   echo "$DIST_STABLE" ;;
        snapshot) echo "$DIST_SNAPSHOT" ;;
    esac
}

fpr_for() {
    case $1 in
        stable)   echo "$SIGNING_FPR_STABLE" ;;
        snapshot) echo "$SIGNING_FPR_SNAPSHOT" ;;
    esac
}

keep_versions_for() {
    case $1 in
        stable)   echo "$KEEP_VERSIONS_STABLE" ;;
        snapshot) echo "$KEEP_VERSIONS_SNAPSHOT" ;;
    esac
}

pages_url() {
    if [[ -n ${PAGES_URL:-} ]]; then
        echo "${PAGES_URL%/}"
    elif [[ -n ${GITHUB_REPOSITORY:-} ]]; then
        echo "https://${GITHUB_REPOSITORY%%/*}.github.io/${GITHUB_REPOSITORY#*/}"
    else
        echo "https://example.invalid/keepassxc-backports"
    fi
}

# Liest Debian-Versionen von stdin und gibt sie aufsteigend sortiert aus
# (Debian-Versionsvergleich via dpkg, Insertion-Sort – die Listen sind kurz).
sort_debversions() {
    local -a sorted=()
    local v i j
    while read -r v; do
        [[ -n $v ]] || continue
        sorted+=("$v")
        for (( i = ${#sorted[@]} - 1; i > 0; i-- )); do
            j=$((i - 1))
            if dpkg --compare-versions "${sorted[j]}" gt "${sorted[i]}"; then
                local tmp=${sorted[i]}; sorted[i]=${sorted[j]}; sorted[j]=$tmp
            else
                break
            fi
        done
    done
    (( ${#sorted[@]} )) && printf '%s\n' "${sorted[@]}"
    return 0
}

# Schreibt key=value nach $GITHUB_OUTPUT (falls in GitHub Actions) und nach stderr.
gh_output() {
    log "output: $1=$2"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

# Kopiert eine .dsc samt der darin gelisteten Dateien (Ersatz für "dcmd cp",
# damit der Publish-Job ohne devscripts auskommt).
copy_dsc() {   # <dsc> <zielverzeichnis>
    local dsc=$1 dest=$2 dir f
    dir=$(dirname "$dsc")
    cp "$dsc" "$dest/"
    while read -r f; do
        [[ $f =~ ^[A-Za-z0-9][A-Za-z0-9.+~_-]*$ ]] || die "ungültiger Dateiname in $(basename "$dsc"): $f"
        [[ -f $dir/$f ]] || die "$f aus $(basename "$dsc") fehlt"
        cp "$dir/$f" "$dest/"
    done < <(awk '/^Files:/{f=1;next} /^[^ ]/{f=0} f&&NF==3{print $3}' "$dsc")
}

# Liest einen Wert aus einer meta.env-Datei, OHNE sie auszuführen.
meta_get() {
    local file=$1 key=$2
    sed -n "s/^${key}=//p" "$file" | head -n1
}
