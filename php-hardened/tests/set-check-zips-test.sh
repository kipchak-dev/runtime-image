#!/bin/sh
# Tests what the set-check stage relies on (architect AM2, Amendment 3.1): offline, from a file:// proxy holding the
# set's module records, the command set-check runs (build-frankenphp.sh: go list -deps over the build environment, with
# GOFLAGS=-mod=mod and the checksum database on) fails when a module the build selects has no zip, and passes when only
# a module used to resolve requirements has none. So a set missing a selected zip cannot pass set-check, and sumdb-prove
# may accept a missing zip for a version outside the build list. Network and a go command required once, to fetch the
# two modules; the checks themselves run offline.
#
#   sh php-hardened/tests/set-check-zips-test.sh [GO]
set -eu
GO="${1:-go}"
W="$(mktemp -d)"; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
fail=0
SELECTED=github.com/pkg/errors; SELECTED_V=v0.9.1   # imported by the main package
REQONLY=golang.org/x/text; REQONLY_V=v0.14.0        # required in go.mod, imported by nothing

# The build environment: a main package that imports one module and requires another it never imports.
mkdir -p "$W/app"
printf 'module example.com/setcheck\n\ngo 1.22\n\nrequire (\n\t%s %s\n\t%s %s\n)\n' \
    "$SELECTED" "$SELECTED_V" "$REQONLY" "$REQONLY_V" > "$W/app/go.mod"
printf 'package main\n\nimport "github.com/pkg/errors"\n\nfunc main() { _ = errors.New("x") }\n' > "$W/app/main.go"

# The records, fetched once with the network, as the download phase keeps them.
(cd "$W/app" && env GOPATH="$W/gopath" GOMODCACHE="$W/mod" GOFLAGS= GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org \
    GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE= "$GO" mod download "$SELECTED@$SELECTED_V" "$REQONLY@$REQONLY_V" > /dev/null)
records() { # records DIR: the set's module records, as the set writer prepares them
    mkdir -p "$1"; cp -R "$W/mod/cache/download/." "$1/"; chmod -R u+w "$1"
    find "$1" -name '*.lock' -delete
    touch "$1/sumdb/sum.golang.org/supported"
}
check() { # check RECORDS: set-check's command, offline from the records alone
    c="$(mktemp -d -p "$W")"; cp -R "$W/app/." "$c/"
    mkdir -p "$c/gopath/pkg/sumdb/sum.golang.org"; cp "$W/gopath/pkg/sumdb/sum.golang.org/latest" "$c/gopath/pkg/sumdb/sum.golang.org/latest"
    (cd "$c" && env GOPATH="$c/gopath" GOMODCACHE="$c/mod" GOFLAGS=-mod=mod GOTOOLCHAIN=local GOPROXY="file://$1" \
        GOSUMDB=sum.golang.org GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= \
        HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
        CGO_ENABLED=0 "$GO" list -deps -f '{{with .Module}}{{.Path}}@{{.Version}}{{end}}' . > "$c/out" 2>&1)
}
zip_of() { printf '%s/%s/@v/%s.zip' "$1" "$2" "$3"; }

records "$W/full"
if check "$W/full"; then echo "ok: with every zip, set-check's command passes offline"
else echo "FAIL: with every zip, set-check's command fails:"; tail -n 3 "$c/out"; fail=1; fi

records "$W/no-reqonly"; rm -f "$(zip_of "$W/no-reqonly" "$REQONLY" "$REQONLY_V")" "$(zip_of "$W/no-reqonly" "$REQONLY" "$REQONLY_V")hash"
if check "$W/no-reqonly"; then echo "ok: without the zip of a module only required ($REQONLY), it passes: only its go.mod is read"
else echo "FAIL: without a requirement-only zip, it fails:"; tail -n 3 "$c/out"; fail=1; fi

records "$W/no-selected"; rm -f "$(zip_of "$W/no-selected" "$SELECTED" "$SELECTED_V")" "$(zip_of "$W/no-selected" "$SELECTED" "$SELECTED_V")hash"
if check "$W/no-selected"; then echo "FAIL: without the zip of a selected module ($SELECTED), set-check's command still passes"; fail=1
elif grep -q "$SELECTED_V.zip" "$c/out"; then echo "ok: without the zip of a selected module ($SELECTED), it fails reading that zip"
else echo "FAIL: without a selected zip, it failed, but not on that zip:"; tail -n 3 "$c/out"; fail=1; fi

# The wiring: set-check runs build-frankenphp.sh with SET_CHECK=1 and REQUIRE_SUMDB=1, and the download phase runs this
# command; the published set is built only from a set that passed.
here="$(cd "$(dirname "$0")/.." && pwd)"
grep -q 'AS set-check' "$here/Dockerfile" && grep -q 'SET_CHECK=1 REQUIRE_SUMDB=1 bash /usr/local/bin/build-frankenphp.sh' "$here/Dockerfile" \
    && grep -q 'COPY --from=set-check /set-checked' "$here/Dockerfile" \
    && grep -q "list -deps" "$here/build-frankenphp.sh" \
    && echo "ok: the Dockerfile runs set-check with REQUIRE_SUMDB=1 and publishes only a set that passed; the download phase runs go list -deps" \
    || { echo "FAIL: the set-check wiring is not as this test assumes"; fail=1; }

[ "$fail" -eq 0 ] && echo "set-check-zips: every case behaves as stated"
exit "$fail"
