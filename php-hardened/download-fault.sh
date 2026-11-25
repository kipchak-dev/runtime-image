#!/bin/sh
# Decides whether a failed source-set build may be retried (K-REG-1, option C). Reads the build's log and exits 0 only
# when the failure is a download fault, upstream and outside the recipe, and nothing else failed:
#   a download fault: static-php-cli could not download an artifact or look up a latest release, aports could not be
#   cloned from any host, or an Alpine package's source files could not be fetched;
#   anything else: a checksum answer that did not verify (sumdb-prove), a set that did not pass set-check, a download
#   address that may not be published, an Alpine version with no aports commit, or a checksum mismatch.
# Exits 1 when the failure is not a download fault, or when the log names none, so an unknown failure is not retried.
#
#   download-fault.sh LOG
set -eu
LOG="${1:-}"
[ -f "$LOG" ] || { echo "download-fault: no log '$LOG'" >&2; exit 2; }
# Without colour codes, which static-php-cli writes around its messages.
clean="$(mktemp)"; trap 'rm -f "$clean"' EXIT
sed 's/\x1b\[[0-9;]*m//g; s/\^\[\[[0-9;]*m//g' "$LOG" > "$clean"
LOG="$clean"

if grep -qE 'sumdb-prove: ' "$LOG" && grep -E 'sumdb-prove: ' "$LOG" | grep -qvE 'answers verified against'; then
	echo "download-fault: sumdb-prove failed; not a download fault, not retried"; exit 1
fi
if grep -qE '\[set-check [0-9]+/[0-9]+\].*(ERROR|error)|ERROR: process .*SET_CHECK=1|SET_CHECK needs a source set' "$LOG"; then
	echo "download-fault: set-check failed; not a download fault, not retried"; exit 1
fi
if grep -qE 'check-download-urls: .*(refused|may not be published)|No aports (commit|directory) for|checksum mismatch|SECURITY ERROR|verifying .*checksum' "$LOG"; then
	echo "download-fault: a check failed; not a download fault, not retried"; exit 1
fi
if grep -qE 'Download failed: Download artifact|Failed to get GitHub latest release|Could not clone aports from any host|Source files not fetched for ' "$LOG"; then
	echo "download-fault: the build failed on a download; retried once"; exit 0
fi
echo "download-fault: the log names no download fault; not retried"
exit 1
