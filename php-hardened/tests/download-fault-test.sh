#!/bin/sh
# T6 (K-REG-1): the source set is retried only after a download fault. download-fault.sh is given log lines as the
# builds wrote them (run 44885705000 for librdkafka, alpine-sources.sh and sumdb-prove.sh for the rest); a download
# fault is retried, and a failed check, or a failure the log does not name, is not. The control is a classifier that
# retries any failure: the cases that must not retry then pass, and the test sees it. No network.
#
#   sh php-hardened/tests/download-fault-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0
ESC="$(printf '\033')"

case_log() { printf '%s\n' "$@" > "$W/log"; }
run() { sh "${CLASSIFIER:-$HERE/download-fault.sh}" "$W/log" > /dev/null 2>&1; }
expect() { # expect retry|no NAME
	if run; then got=retry; else got=no; fi
	if [ "$got" = "$1" ]; then echo "ok: $2 -> $1"; else echo "FAIL: $2 -> $got, expected $1"; fail=1; fi
}

cases() {
	case_log "#27 26.86 ${ESC}[93m[08:38:04 WARNING] GitHub refused the token for https://api.github.com/repos/confluentinc/librdkafka/releases/latest; asking again without it${ESC}[0m" \
		"#27 1055.3 ${ESC}[31m✘ Download failed: Download artifact 'librdkafka' failed. Please check your internet connection and try again.${ESC}[0m" \
		"#27 1055.3 ${ESC}[31mCause: ${ESC}[37mFailed to get GitHub latest release for confluentinc/librdkafka from https://api.github.com/repos/confluentinc/librdkafka/releases/latest${ESC}[0m${ESC}[0m"
	expect retry "librdkafka latest-release lookup refused (run 44885705000)"
	case_log "#31 12.0 Source files not fetched for apk-tools 3.0.9-r0"
	expect retry "an Alpine package's source files not fetched"
	case_log "#31 3.1 Could not clone aports from https://gitlab.alpinelinux.org/alpine/aports.git; trying the next host." \
		"#31 9.2 Could not clone aports from any host."
	expect retry "aports not cloned from any host"
	case_log "#27 162.0 sumdb-prove: 458 answers verified against 2 tree note(s), online and offline, one answer per client" \
		"#27 170.1 sumdb-prove: offline, from the records alone, the answer for golang.org/x/text@v0.14.0 did not verify against the note n1"
	expect no "sumdb-prove failed after its summary"
	case_log "#27 50.0 ✘ Download failed: Download artifact 'zlib' failed." \
		"#27 60.0 sumdb-prove: a checksum answer did not verify against the note n2"
	expect no "a download fault and a failed checksum answer together"
	case_log "#67 [set-check 5/5] RUN --network=none ... SET_CHECK=1 REQUIRE_SUMDB=1 bash /usr/local/bin/build-frankenphp.sh" \
		"#67 ERROR: process \"/bin/sh -c set -a && . /tmp/build.env && set +a && SET_CHECK=1 REQUIRE_SUMDB=1 bash\" did not complete successfully"
	expect no "set-check failed"
	case_log "#31 4.0 No aports commit for apk-tools 3.0.9-r0"
	expect no "an Alpine version with no aports commit"
	case_log "check-download-urls: line 3 refused (private address): http://10.0.0.1/x.tar.gz"
	expect no "a download address that may not be published"
	case_log "#27 400.0 make: *** [Makefile:12: all] Error 2"
	expect no "a failure the log does not name"
	case_log "#27 162.0 sumdb-prove: 458 answers verified against 2 tree note(s), online and offline, one answer per client" \
		"#27 1055.3 ✘ Download failed: Download artifact 'librdkafka' failed."
	expect retry "a download fault after a passing sumdb-prove summary"
}

cases
echo "--- control: a classifier that retries any failure"
printf '#!/bin/sh\nexit 0\n' > "$W/always.sh"
before="$fail"; fail=0
CLASSIFIER="$W/always.sh" cases > "$W/control.out"
if [ "$fail" -ne 0 ]; then echo "ok: control: the cases that must not retry catch a classifier that retries everything"
else echo "FAIL: control: a classifier that retries everything passed"; before=1; fi
fail="$before"

[ "$fail" -eq 0 ] && echo "download-fault: every case behaves as stated"
exit "$fail"
