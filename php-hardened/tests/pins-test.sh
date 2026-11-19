#!/bin/sh
# Every builder must use the same inputs. The base images are the Dockerfile's ARG defaults, so each must be pinned by
# digest, the Dockerfile frontend too, and every FROM must name either an earlier stage or one of those arguments. The
# PHP lines come from build.env alone, so the workflow names none of its own. Each check has a control.
#
#   sh php-hardened/tests/pins-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0

check_frontend() { sed -n '1p' "$1" | grep -Eq '^# syntax=[^@]+@sha256:[0-9a-f]{64}$'; }
check_base_args() {
    for a in FRANKENPHP_BUILDER DEBIAN_IMAGE ALPINE_IMAGE COMPOSER_IMAGE; do
        grep -Eq "^ARG $a=[^@[:space:]]+@sha256:[0-9a-f]{64}\$" "$1" || return 1
    done
}
# A FROM names an earlier stage, an argument from the pinned set (or RUNTIME_SOURCE, which defaults to a stage and is
# set to a digest by the builders), or scratch. Anything else is an unpinned image.
check_from() {
    awk '
        /^FROM / {
            ref = $2
            for (i = 2; i <= NF; i++) if ($i !~ /^--/) { ref = $i; break }
            ok = (ref == "scratch") || (ref in stages) \
                || ref ~ /^\$\{(FRANKENPHP_BUILDER|DEBIAN_IMAGE|ALPINE_IMAGE|COMPOSER_IMAGE|RUNTIME_SOURCE)\}$/
            if (!ok) { print "unpinned FROM: " $0; bad = 1 }
            if (tolower($(NF-1)) == "as") stages[$NF] = 1
        }
        END { exit bad }' "$1"
}
check_runtime_source_default() { grep -qx 'ARG RUNTIME_SOURCE=runtime' "$1"; }
check_lines_from_env() {
    grep -q '\. php-hardened/build.env' "$2" && grep -q 'for line in \$PHP_LINES' "$2" \
        && ! grep -Eq '"?8\.[0-9]+"?[[:space:]]*,[[:space:]]*"?8\.[0-9]+' "$2" \
        && grep -Eq '^PHP_LINES="[0-9. ]+"$' "$3"
}

D="$HERE/Dockerfile"; B="$REPO/.github/workflows/build.yml"; E="$HERE/build.env"
try() { if "$2" "$D" "$B" "$E" > /dev/null; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
try "the Dockerfile frontend is pinned by digest" check_frontend
try "every base image argument is pinned by digest" check_base_args
try "every FROM is a stage, a pinned argument or scratch" check_from
try "RUNTIME_SOURCE defaults to the runtime stage" check_runtime_source_default
try "the workflow takes the PHP lines from build.env only" check_lines_from_env

control() { # <name> <check> <file: D, B or E> <sed expression>
    cp "$D" "$W/Dockerfile"; cp "$B" "$W/build.yml"; cp "$E" "$W/build.env"
    case "$3" in D) f="$W/Dockerfile"; o="$D" ;; B) f="$W/build.yml"; o="$B" ;; E) f="$W/build.env"; o="$E" ;; esac
    sed -i "$4" "$f"
    if cmp -s "$f" "$o"; then echo "FAIL: control $1 changed nothing"; fail=1; return; fi
    if "$2" "$W/Dockerfile" "$W/build.yml" "$W/build.env" > /dev/null; then echo "FAIL: control $1 still passes"; fail=1
    else echo "ok: control $1"; fi
}
control "an unpinned FROM" check_from D 's/^FROM \${DEBIAN_IMAGE} AS build$/FROM debian:trixie-slim AS build/'
control "a base image by tag" check_base_args D 's/^\(ARG DEBIAN_IMAGE=[^@]*\)@sha256:[0-9a-f]*$/\1/'
control "an unpinned frontend" check_frontend D '1s/@sha256:[0-9a-f]*$//'
control "PHP lines written into the workflow" check_lines_from_env B 's/for line in \$PHP_LINES; do/for line in 8.4 8.5; do/'

[ "$fail" -eq 0 ] && echo "pins: every check and control behaves as stated"
exit "$fail"
