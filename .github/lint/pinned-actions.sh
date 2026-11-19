#!/bin/sh
# Fails when any "uses:" line under the given directory names a remote action by anything other than a full
# 40-character commit SHA. Local actions (./...) are allowed. Test: sh .github/lint/pinned-actions-test.sh
#
#   sh .github/lint/pinned-actions.sh .github
set -eu
dir="${1:?usage: pinned-actions.sh <directory>}"
files="$(find "$dir" -type f \( -name '*.yml' -o -name '*.yaml' \))"
[ -n "$files" ] || { echo "no workflow or action file found under $dir" >&2; exit 1; }
# shellcheck disable=SC2086
uses="$(grep -n -E '^[[:space:]]*(-[[:space:]]+)?uses:' $files || true)"
[ -n "$uses" ] || { echo "no uses: line found under $dir; nothing was checked" >&2; exit 1; }
bad="$(printf '%s\n' "$uses" | grep -v -E 'uses:[[:space:]]*["'"'"']?(\./[^[:space:]]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40})["'"'"']?([[:space:]]+#.*)?$' || true)"
if [ -n "$bad" ]; then
    echo "These actions are not pinned by a full commit SHA:" >&2
    printf '%s\n' "$bad" >&2
    exit 1
fi
echo "$(printf '%s\n' "$uses" | wc -l | tr -d ' ') uses: lines, all pinned by a full commit SHA or local"
