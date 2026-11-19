#!/bin/sh
# Shows that triggers.sh passes this repository's workflows and fails each way a workflow could let untrusted code
# publish.
set -eu
here="$(cd "$(dirname "$0")/../.." && pwd)"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
fail=0
sh "$here/.github/lint/triggers.sh" "$here/.github/workflows" > /dev/null || { echo "FAIL: the repository's workflows"; fail=1; }
control() { # <name> <file to write in a copy of the workflows> <content>
    rm -rf "$w/wf"; cp -R "$here/.github/workflows" "$w/wf"
    printf '%s\n' "$3" > "$w/wf/$2"
    if sh "$here/.github/lint/triggers.sh" "$w/wf" > /dev/null 2>&1; then echo "FAIL: control $1 still passes"; fail=1
    else echo "ok: control $1"; fi
}
control "packages: write on pull_request" pr.yml 'on:
  pull_request:
permissions:
  packages: write'
control "id-token: write on pull_request" pr.yml 'on: [push, pull_request]
jobs:
  x:
    permissions:
      id-token: write'
control "pull_request_target" prt.yml 'on:
  pull_request_target:'
control "build.yml on pull_request" build.yml 'on:
  push:
  pull_request:
  schedule:
  workflow_dispatch:'
[ "$fail" = 0 ] && echo "triggers-test: the check and every control behave as stated"
exit "$fail"
