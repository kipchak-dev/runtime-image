#!/bin/sh
# Tests check-download-urls.sh (Amendment 1, condition P5): a set's list of download addresses holds only public ones.
# Each planted line must be refused; real lines from a build must pass. Then each rule is removed from a copy of the
# script, and the planted line it guards must pass: the negative controls.
#
#   sh php-hardened/tests/download-urls-test.sh
#
# shellcheck disable=SC2016 # the controls' sed expressions match the script's text literally
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/check-download-urls.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0
T="$(printf '\t')"

good() { # the shapes a real build records
    printf 'https://api.github.com/repos/madler/zlib/releases/assets/312045%sAccept: application/octet-stream%szlib-1.4.tar.gz\n' "$T" "$T"
    printf 'https://api.github.com/repos/confluentinc/librdkafka/tarball/v2.16.0%s%sconfluentinc-librdkafka-v2.16.0-0-gc6c9973.tar.gz\n' "$T" "$T"
    printf 'https://ftpmirror.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz%s%sgmp-6.3.0.tar.xz\n' "$T" "$T"
    printf 'https://pecl.php.net/get/protobuf-5.36.2.tgz%s%sprotobuf-5.36.2.tgz\n' "$T" "$T"
    printf 'https://www.php.net/distributions/php-8.5.12.tar.xz%s%sphp-8.5.12.tar.xz\n' "$T" "$T"
    printf 'https://api.github.com/repos/krakjoe/apcu/zipball/819fce90c469a5666b1706036cd66120af419f1f%s%sapcu_apcu-v5.1.28.zip\n' "$T" "$T"
}
check() { # check SCRIPT LINE...: the exit status of the script on the good lines plus LINE
    s="$1"; shift
    { good; for l in "$@"; do printf '%s\n' "$l"; done; } > "$W/urls"
    status=0; sh "$s" "$W/urls" > "$W/out" 2>&1 || status=$?
}
AUTH="https://api.github.com/repos/a/b/tarball/v1${T}Authorization: Bearer ghp_planted${T}b-v1.tar.gz"
INTERNAL="https://1x.ax/mamluk/kipchak-sources/x.tar.gz${T}${T}x.tar.gz"
SUBDOMAIN="https://packages.mamluk.net/x.tar.gz${T}${T}x.tar.gz"
SIGNED="https://objects.githubusercontent.com/x?X-Amz-Signature=abc&X-Amz-Expires=300${T}${T}x.tar.gz"
QUERYTOKEN="https://example.org/x.tar.gz?token=abc${T}${T}x.tar.gz"
PLAIN="http://ftpmirror.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz${T}${T}gmp-6.3.0.tar.xz"
IPHOST="https://10.0.0.5/x.tar.gz${T}${T}x.tar.gz"
USERINFO="https://user:pass@example.org/x.tar.gz${T}${T}x.tar.gz"
COOKIE="https://example.org/x.tar.gz${T}Accept: */* | Cookie: s=1${T}x.tar.gz"
TOKENHDR="https://example.org/x.tar.gz${T}X-Api-Token: abc${T}x.tar.gz"
FOURFIELDS="https://example.org/x.tar.gz${T}${T}x.tar.gz${T}extra"

check "$SCRIPT"
if [ "$status" -eq 0 ]; then echo "ok: the addresses a real build records pass"; else echo "FAIL: real addresses refused"; cat "$W/out"; fail=1; fi
status=0; sh "$SCRIPT" "$W/none" > /dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then echo "ok: no file is an input error"; else echo "FAIL: no file gave $status"; fail=1; fi

refused() { # refused NAME LINE
    check "$SCRIPT" "$2"
    if [ "$status" -eq 1 ] && grep -q 'line 7 refused' "$W/out"; then echo "ok: refused: $1"
    else echo "FAIL: not refused: $1 (exit $status)"; cat "$W/out"; fail=1; fi
}
refused "a planted Authorization header" "$AUTH"
refused "a planted internal host (1x.ax)" "$INTERNAL"
refused "a Mamluk subdomain" "$SUBDOMAIN"
refused "a pre-signed query" "$SIGNED"
refused "a token in the query" "$QUERYTOKEN"
refused "plain http" "$PLAIN"
refused "an IP address" "$IPHOST"
refused "credentials in the address" "$USERINFO"
refused "a cookie header" "$COOKIE"
refused "a header naming a token" "$TOKENHDR"
refused "a line with four fields" "$FOURFIELDS"

control() { # control NAME LINE SED: with the rule removed, the line passes
    sed "$3" "$SCRIPT" > "$W/broken.sh"
    if cmp -s "$SCRIPT" "$W/broken.sh"; then echo "FAIL: control $1 changed nothing"; fail=1; return; fi
    check "$W/broken.sh" "$2"
    if [ "$status" -eq 0 ]; then echo "ok: control $1"; else echo "FAIL: control $1: still refused"; fail=1; fi
}
control headers "$AUTH" 's/if (tolower(headers) ~ /if (0 \&\& tolower(headers) ~ /'
control hosts "$INTERNAL" 's/if (host == "1x.ax" ||/if (0 \&\& host == "1x.ax" ||/'
control query "$SIGNED" 's/if (q ~ /if (0 \&\& q ~ /'
control https "$PLAIN" 's/if (url !~ \/^https:/if (0 \&\& url !~ \/^https:/'
control fields "$FOURFIELDS" 's/if (NF != 3) { refuse/if (0) { refuse/'

[ "$fail" -eq 0 ] && echo "download-urls: every case and control behaves as stated"
exit "$fail"
