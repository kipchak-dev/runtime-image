#!/bin/sh
# Tests pinned-actions.sh (test T5): a pinned line passes; a tag, a branch, a short SHA, a docker:// reference or an
# empty directory fails.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0
try() { # <name> <expected exit> <uses line>
    rm -rf "$W/d"; mkdir -p "$W/d"
    [ -n "$3" ] && printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n      %s\n' "$3" > "$W/d/w.yml"
    s=0; sh "$HERE/pinned-actions.sh" "$W/d" > /dev/null 2>&1 || s=$?
    if [ "$s" -eq "$2" ]; then echo "ok: $1"; else echo "FAIL: $1 (exit $s, expected $2)"; fail=1; fi
}
try "pinned" 0 "- uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0"
try "local action" 0 "- uses: ./.github/actions/build-index"
try "sub-path action pinned" 0 "- uses: github/codeql-action/init@0123456789abcdef0123456789abcdef01234567"
try "tag" 1 "- uses: actions/checkout@v4"
try "branch" 1 "- uses: actions/checkout@main"
try "short sha" 1 "- uses: actions/checkout@3d3c42e"
try "docker reference" 1 "- uses: docker://alpine:3.20"
try "uppercase sha" 1 "- uses: actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1"
try "nothing to check" 1 ""
# The real workflows and actions in this repository.
s=0; sh "$HERE/pinned-actions.sh" "$HERE/.." > /dev/null || s=$?
if [ "$s" -eq 0 ]; then echo "ok: this repository"; else echo "FAIL: this repository"; fail=1; fi
[ "$fail" -eq 0 ] && echo "pinned-actions: every case behaves as stated"
exit "$fail"
