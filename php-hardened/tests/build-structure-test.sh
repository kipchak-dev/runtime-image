#!/bin/sh
# Static checks of how the binary is built (kipchak-runtime build-time plan, tests T1 and T5), with no Docker and no
# network. Each check is then run against a copy with its safeguard removed, which must fail: the negative controls.
#
#   sh php-hardened/tests/build-structure-test.sh
#
# The sed expressions match the files' text literally, so their dollar signs must not expand.
# The checks are called through try() and control(), which shellcheck cannot follow.
# shellcheck disable=SC2016,SC2317
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0

# The RUN instruction of the binary stage that runs PHASE=<phase>, joined onto one line.
run_of() { # <Dockerfile> <phase>
    awk '/^FROM .* AS binary$/{s=1} s&&/^FROM /&&!/AS binary$/{s=0} s' "$1" \
        | awk '/^RUN /{if (r) print r; r=$0; next} r&&/^\t/{r=r " " $0; next} r{print r; r=""} END{if (r) print r}' \
        | grep -F "PHASE=$2 " || true
}
check_network_none() { run_of "$1" compile | grep -q -- '^RUN --network=none '; }
check_download_secret() { run_of "$1" download | grep -q -- '--mount=type=secret,id=github_token'; }
check_compile_no_secret() { r="$(run_of "$1" compile)"; [ -n "$r" ] && ! printf '%s' "$r" | grep -q -- 'type=secret'; }
check_token_not_arg_env() { ! grep -q -i -E '^[[:space:]]*(ARG|ENV)[[:space:]].*(github_token|GITHUB_TOKEN)' "$1"; }
check_download_only_in_script() { grep -q '^SPC_DOWNLOAD_ONLY=1 ./bin/spc craft craft.yml$' "$2"; }
check_no_build_false() { ! grep -qx "  build: false" "$2"; }
check_compile_offline_go() { grep -q '^export GOPROXY=off ' "$2"; }

try() { # <name> <check> <Dockerfile> <script>
    if "$2" "$3" "$4"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi
}
D="$HERE/Dockerfile"; S="$HERE/build-frankenphp.sh"
try "the compile step has no network" check_network_none "$D" "$S"
try "the download step takes the token as a secret mount" check_download_secret "$D" "$S"
try "the compile step has no secret" check_compile_no_secret "$D" "$S"
try "the token is in no ARG or ENV" check_token_not_arg_env "$D" "$S"
try "the download phase stops before compiling" check_download_only_in_script "$D" "$S"
try "no craft-options build: false, which craft ignores" check_no_build_false "$D" "$S"
try "Go reads only its module cache in the compile" check_compile_offline_go "$D" "$S"

control() { # <name> <check> <file: D or S> <sed expression>
    cp "$D" "$W/Dockerfile"; cp "$S" "$W/build-frankenphp.sh"
    case "$3" in D) f="$W/Dockerfile" ;; S) f="$W/build-frankenphp.sh" ;; esac
    sed -i "$4" "$f"
    if cmp -s "$f" "$( [ "$3" = D ] && echo "$D" || echo "$S")"; then echo "FAIL: control $1 changed nothing"; fail=1; return; fi
    if "$2" "$W/Dockerfile" "$W/build-frankenphp.sh"; then echo "FAIL: control $1 still passes"; fail=1
    else echo "ok: control $1"; fi
}
control "compile with the network" check_network_none D 's/^RUN --network=none \\$/RUN \\/'
control "download without the secret" check_download_secret D '/PHASE=download/,$!{/--mount=type=secret,id=github_token/d}'
control "a secret on the compile" check_compile_no_secret D 's/^RUN --network=none \\$/RUN --network=none --mount=type=secret,id=github_token \\/'
control "the token as an ARG" check_token_not_arg_env D 's/^ARG TARGETARCH$/ARG TARGETARCH\nARG GITHUB_TOKEN/'
control "the token as an ENV" check_token_not_arg_env D 's/^ARG TARGETARCH$/ARG TARGETARCH\nENV github_token=x/'
control "a download phase that builds" check_download_only_in_script S 's/^SPC_DOWNLOAD_ONLY=1 \.\/bin\/spc craft craft.yml$/.\/bin\/spc craft craft.yml/'
control "build: false again" check_no_build_false S "s/^craft-options:\$/craft-options:\n  build: false/"
control "Go free to download in the compile" check_compile_offline_go S 's/^export GOPROXY=off /export GOFLAGS_UNUSED=1 /'

[ "$fail" -eq 0 ] && echo "build-structure: every check and control behaves as stated"
exit "$fail"
