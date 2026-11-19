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
check_compile_offline_go() { l="$(grep '^GOPROXY=' "$2")"; case "$l" in 'GOPROXY="file://'*) ! printf '%s' "$l" | grep -q -E 'https?:' ;; *) false ;; esac && grep -q '^export GOPROXY GOFLAGS=-mod=mod ' "$2"; }
check_sumdb_kept() { [ "$(grep -c 'GOSUMDB=off' "$2")" -eq 1 ] && grep -q '^		export GOSUMDB=off$' "$2"; }
check_no_placeholder_versions() { grep -qF "if grep -q 'v0\.0\.0-00010101000000-000000000000' /out/build-info.txt; then" "$2" && grep -qx 'for m in github.com/dunglas/frankenphp github.com/dunglas/frankenphp/caddy; do' "$2"; }
check_set_check_requires_sumdb() { grep -q 'SET_CHECK=1 REQUIRE_SUMDB=1 bash /usr/local/bin/build-frankenphp.sh' "$1" && grep -q 'REQUIRE_SUMDB=1 requires them.* exit 1$' "$2" && grep -q 'if \[ "\${REQUIRE_SUMDB:-0}" = 1 \]; then' "$2"; }
check_notes_carried() { grep -qF 'cp "${note}" "${SET}/gosumdb/${name}.latest"' "$2" && grep -qF 'tree note (${kept}) is older than a cached answer' "$2" && grep -qx '		from_set && restore_sumdb_notes' "$2"; }
check_after_compile_sumdb() { [ "$(grep -c 'GOSUMDB=off' "$3")" -eq 1 ] && grep -qx '		export GOSUMDB=off' "$3" && grep -qF 'cp "${gopath_file%.gopath}.latest"' "$3"; }
check_github_retry() { grep -qF 'asking again without it' "$2" && grep -qF 'downloading again without it' "$2" && grep -qF "'https://api.github.com/') && preg_grep" "$2"; }
check_caddy_pinned() { grep -qF '*" Caddy ${caddy_version} "*) ;;' "$2" && grep -q '^mkdir -p /out && printf .%s\\n. "${caddy_version}" > /out/caddy-version$' "$2"; }

try() { # <name> <check> <Dockerfile> <script>
    if "$2" "$3" "$4" "$A"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi
}
D="$HERE/Dockerfile"; S="$HERE/build-frankenphp.sh"; A="$HERE/after-compile.sh"
try "the compile step has no network" check_network_none "$D" "$S"
try "the download step takes the token as a secret mount" check_download_secret "$D" "$S"
try "the compile step has no secret" check_compile_no_secret "$D" "$S"
try "the token is in no ARG or ENV" check_token_not_arg_env "$D" "$S"
try "the download phase stops before compiling" check_download_only_in_script "$D" "$S"
try "no craft-options build: false, which craft ignores" check_no_build_false "$D" "$S"
try "Go reads only its module cache in the compile" check_compile_offline_go "$D" "$S"
try "checksums stay checked, except for a set without records" check_sumdb_kept "$D" "$S"
try "the Caddy release is recorded and asserted" check_caddy_pinned "$D" "$S"
try "our set check refuses a set without checksum records" check_set_check_requires_sumdb "$D" "$S"
try "no module is recorded without a version" check_no_placeholder_versions "$D" "$S"
try "the set carries each client's tree note, no older than its answers, and a rebuild restores it" check_notes_carried "$D" "$S"
try "the licence step checks checksums too, except for a set without records" check_after_compile_sumdb "$D" "$S"
try "a token GitHub refuses is retried without it, for api.github.com only" check_github_retry "$D" "$S"

control() { # <name> <check> <file: D, S or A> <sed expression>
    cp "$D" "$W/Dockerfile"; cp "$S" "$W/build-frankenphp.sh"; cp "$A" "$W/after-compile.sh"
    case "$3" in D) f="$W/Dockerfile"; o="$D" ;; S) f="$W/build-frankenphp.sh"; o="$S" ;; A) f="$W/after-compile.sh"; o="$A" ;; esac
    sed -i "$4" "$f"
    if cmp -s "$f" "$o"; then echo "FAIL: control $1 changed nothing"; fail=1; return; fi
    if "$2" "$W/Dockerfile" "$W/build-frankenphp.sh" "$W/after-compile.sh"; then echo "FAIL: control $1 still passes"; fail=1
    else echo "ok: control $1"; fi
}
control "compile with the network" check_network_none D 's/^RUN --network=none \\$/RUN \\/'
control "download without the secret" check_download_secret D '/PHASE=download/,$!{/--mount=type=secret,id=github_token/d}'
control "a secret on the compile" check_compile_no_secret D 's/^RUN --network=none \\$/RUN --network=none --mount=type=secret,id=github_token \\/'
control "the token as an ARG" check_token_not_arg_env D 's/^ARG TARGETARCH$/ARG TARGETARCH\nARG GITHUB_TOKEN/'
control "the token as an ENV" check_token_not_arg_env D 's/^ARG TARGETARCH$/ARG TARGETARCH\nENV github_token=x/'
control "a download phase that builds" check_download_only_in_script S 's/^SPC_DOWNLOAD_ONLY=1 \.\/bin\/spc craft craft.yml$/.\/bin\/spc craft craft.yml/'
control "build: false again" check_no_build_false S "s/^craft-options:\$/craft-options:\n  build: false/"
control "Go free to download in the compile" check_compile_offline_go S 's|^GOPROXY="file://|GOPROXY="https://proxy.golang.org,file://|'
control "checksums switched off in the compile" check_sumdb_kept S 's|^export GOPROXY GOFLAGS=-mod=mod |export GOPROXY GOSUMDB=off GOFLAGS=-mod=mod |'
control "no Caddy assertion" check_caddy_pinned S '/^\t\*" Caddy \${caddy_version} "\*) ;;$/d'
control "set check without REQUIRE_SUMDB" check_set_check_requires_sumdb D 's/SET_CHECK=1 REQUIRE_SUMDB=1 /SET_CHECK=1 /'
control "REQUIRE_SUMDB ignored" check_set_check_requires_sumdb S '/REQUIRE_SUMDB=1 requires them/s/exit 1/:/'
control "placeholder versions allowed" check_no_placeholder_versions S '/^if grep -q .v0.*build-info.txt; then$/s/if grep -q/if false \&\& grep -q/'
control "FrankenPHP modules not fetched" check_no_placeholder_versions S 's/^for m in github.com\/dunglas\/frankenphp github.com\/dunglas\/frankenphp\/caddy; do$/for m in; do/'
control "tree notes not restored" check_notes_carried S '/^\t\tfrom_set \&\& restore_sumdb_notes$/d'
control "a stale tree note accepted" check_notes_carried S '/tree note (\${kept}) is older than a cached answer/d'
control "the licence step unchecked" check_after_compile_sumdb A 's|^\texport GOPROXY=file:///sources/gomod GOFLAGS=-mod=mod GOTOOLCHAIN=local$|\texport GOPROXY=file:///sources/gomod GOSUMDB=off GOFLAGS=-mod=mod GOTOOLCHAIN=local|'
control "no anonymous retry for downloads" check_github_retry S '/downloading again without it/d'
control "no Caddy record" check_caddy_pinned S '/^mkdir -p \/out && printf .%s\\n. "\${caddy_version}" > \/out\/caddy-version$/d'

[ "$fail" -eq 0 ] && echo "build-structure: every check and control behaves as stated"
exit "$fail"
