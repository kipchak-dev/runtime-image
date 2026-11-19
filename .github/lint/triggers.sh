#!/bin/sh
# Fails when a workflow that runs on pull requests could publish. In a public repository, a pull request's code is
# untrusted: a workflow triggered by pull_request may hold no write permission and no token for signing, and
# pull_request_target, which runs with the base repository's permissions, is never used. The build workflow runs only
# on a push, the schedule and a manual run. Test: sh .github/lint/triggers-test.sh
#
#   sh .github/lint/triggers.sh .github/workflows
set -eu
dir="${1:?usage: triggers.sh <workflow directory>}"
fail=0
found=0
for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    found=1
    if grep -q 'pull_request_target' "$f"; then
        echo "$f: pull_request_target is not allowed" >&2; fail=1
    fi
    if grep -Eq '^[[:space:]]*pull_request:?[[:space:]]*$|^[[:space:]]*-[[:space:]]*pull_request[[:space:]]*$|on:.*pull_request' "$f" \
        && grep -Eq '^[[:space:]]*(packages|id-token|attestations|contents|actions|deployments|statuses|checks|pages|security-events):[[:space:]]*write' "$f"; then
        echo "$f: runs on pull requests and grants a write permission" >&2; fail=1
    fi
    if grep -Eq '(^|[^a-z_])write-all' "$f"; then
        echo "$f: write-all is not allowed" >&2; fail=1
    fi
done
[ "$found" = 1 ] || { echo "no workflow found in $dir; nothing was checked" >&2; exit 1; }
b="$dir/build.yml"
[ -f "$b" ] || { echo "$b is missing" >&2; exit 1; }
triggers="$(awk '/^on:/{f=1; next} f && /^[^[:space:]]/{f=0} f && /^  [a-z_]+:/{sub(/^  /,""); sub(/:.*/,""); print}' "$b" | sort | tr '\n' ' ')"
[ "$triggers" = "push schedule workflow_dispatch " ] \
    || { echo "$b: triggers are '$triggers', expected push, schedule and workflow_dispatch only" >&2; fail=1; }
[ "$fail" = 0 ] && echo "triggers: no workflow that runs on pull requests can publish"
exit "$fail"
