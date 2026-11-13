#!/bin/bash
# Öffnet einen PR "VERSION -> <neue Upstream-Version>", wenn der Snapshot
# eine neuere Version erfolgreich gebaut, getestet und veröffentlicht hat.
#
# Usage: promote.sh <upstream-version>
# Benötigt: gh, git, GH_TOKEN (contents: write, pull-requests: write)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
UP=${1:?}
[[ $UP =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ungültige Version: $UP"
cd "$REPO_ROOT"

CUR=$(tr -d '[:space:]' < VERSION)
if [[ $(printf '%s\n%s\n' "$CUR" "$UP" | sort -V | tail -n1) == "$CUR" ]]; then
    log "VERSION ($CUR) ist aktuell – kein PR nötig"; exit 0
fi

BRANCH="promote/$UP"
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null; then
    log "Branch $BRANCH existiert bereits – nichts zu tun"; exit 0
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git switch -c "$BRANCH"
echo "$UP" > VERSION
echo 1 > REVISION
git add VERSION REVISION
git commit -m "Stable auf KeePassXC $UP anheben"
git push origin "$BRANCH"

gh pr create --base main --head "$BRANCH" \
    --title "Stable: KeePassXC $UP" \
    --body "KeePassXC $UP wurde in der Snapshot-Suite gebaut, getestet und veröffentlicht.

Vor dem Merge:
- [ ] Upstream-Changelog gelesen: https://github.com/keepassxreboot/keepassxc/releases/tag/$UP
- [ ] Snapshot-Paket selbst ausprobiert
- [ ] Prüfen, ob eigene Patches in \`patches/\` noch nötig sind

Hinweis: PRs, die mit dem GITHUB_TOKEN erstellt werden, starten keine Workflows.
Damit die PR-Checks laufen, den PR einmal schließen und wieder öffnen."
