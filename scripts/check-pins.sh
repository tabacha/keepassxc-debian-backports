#!/bin/bash
# PR-Prüfung: alle Actions auf Commit-SHA gepinnt, alle Container-Images
# auf den Digest aus config.env.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config
cd "$REPO_ROOT/.github/workflows"
rc=0

while IFS= read -r line; do
    ref=${line#*uses:}; ref=${ref%%#*}; ref=$(echo "$ref" | tr -d " \"'")
    [[ $ref == ./* ]] && continue
    if [[ ! $ref =~ @[0-9a-f]{40}$ ]]; then
        echo "nicht auf SHA gepinnt: $ref"; rc=1
    fi
done < <(grep -h 'uses:' ./*.yml)

while IFS= read -r line; do
    img=${line#*:}; img=$(echo "${img%%#*}" | tr -d " \"'")
    if [[ $img != "$DEBIAN_IMAGE" ]]; then
        echo "Image weicht von config.env ab: $img"; rc=1
    fi
done < <(grep -hE '^\s+(image|container):\s*\S*debian' ./*.yml)

(( rc == 0 )) && log "Pins ok"
exit $rc
