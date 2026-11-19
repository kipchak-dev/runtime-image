#!/bin/sh
# Fetches, while the network is still there, every proof the Go checksum database's answers in a source set will need
# offline. A set merges the module caches of two Go clients (the default GOPATH and xcaddy's), each with its own newest
# tree note. When one client cached an answer from a tree of one size and the other client's note is from a larger
# tree, a rebuild must prove the two trees consistent, from tiles that neither client fetched: the set check then fails
# with "reading .../sumdb/sum.golang.org/tile/...: no such file". This asks Go to check every answer against every
# note, with the set's own records first and the Go module proxy behind them, so that Go fetches each tile it is
# missing; those tiles are then added to the set's records. Each tile is checked by Go against sum.golang.org's key.
#
#   sumdb-prove.sh GO PROXY_DIR NOTE...
#
# GO is the go command; PROXY_DIR is a module proxy directory as the set holds it (cache/download layout, with
# sumdb/sum.golang.org/lookup and supported); each NOTE is a client's tree note, as Go keeps it in
# $GOPATH/pkg/sumdb/sum.golang.org/latest. Network required. Exit codes: 0 every answer verified against every note,
# and the tiles that took are in PROXY_DIR; 1 an answer did not verify, or Go failed; 2 the input is wrong.
set -eu
go="${1:-}"; P="${2:-}"
[ -x "$go" ] || command -v "$go" > /dev/null 2>&1 || { echo "sumdb-prove: no go command '$go'" >&2; exit 2; }
[ -d "$P/sumdb/sum.golang.org/lookup" ] || { echo "sumdb-prove: $P holds no checksum answers" >&2; exit 2; }
shift 2
[ "$#" -gt 0 ] || { echo "sumdb-prove: no tree note given" >&2; exit 2; }
P="$(cd "$P" && pwd)"
lookups="$P/sumdb/sum.golang.org/lookup"

# Every module version the set holds an answer for. Module paths are stored escaped: !x is X.
list="$(mktemp)"
find "$lookups" -type f | sed "s|^$lookups/||" | sed 's/!\([a-z]\)/\U\1/g' | sort -u > "$list"
[ -s "$list" ] || { echo "sumdb-prove: no answers under $lookups" >&2; exit 2; }
before="$(find "$P/sumdb/sum.golang.org" -path '*/tile/*' -type f | wc -l)"

for note in "$@"; do
	[ -f "$note" ] || { echo "sumdb-prove: no tree note at $note" >&2; exit 2; }
	w="$(mktemp -d)"
	mkdir -p "$w/gopath/pkg/sumdb/sum.golang.org"
	cp "$note" "$w/gopath/pkg/sumdb/sum.golang.org/latest"
	# go mod download checks each version's go.mod and zip against the checksum database, as the set check does, which
	# reads each answer and proves its tree against the note; it fails when one does not verify. (go list -m is not
	# used: it exits 0 when a verification fails.) Outside any module, with a fresh module cache.
	# The fresh module cache starts as a copy of the set's records, so Go reads the set's own answers from it and asks
	# the Go module proxy only for what is missing: the proof tiles. (With the set as a file:// proxy instead, Go reads
	# every checksum database file from it and does not fall back for a missing tile.)
	mkdir -p "$w/modcache/cache/download"
	cp -R "$P/." "$w/modcache/cache/download/"
	# shellcheck disable=SC2046 # one argument per module@version
	if ! (cd "$w" && env GOPATH="$w/gopath" GOMODCACHE="$w/modcache" GOFLAGS= GOTOOLCHAIN=local \
		GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org GONOSUMDB= GONOSUMCHECK= GOPRIVATE= \
		"$go" mod download $(cat "$list") > /dev/null 2> "$w/err"); then
		grep -v '^go: downloading' "$w/err" | head -n 10 >&2
		echo "sumdb-prove: a checksum answer did not verify against the note $note" >&2
		exit 1
	fi
	# The tiles Go fetched for these proofs, added to the set's records beside the ones already there.
	fetched="$w/modcache/cache/download/sumdb/sum.golang.org"
	if [ -d "$fetched" ]; then
		(cd "$fetched" && find . -path '*/tile/*' -type f) | while read -r t; do
			[ -f "$P/sumdb/sum.golang.org/$t" ] && continue
			mkdir -p "$(dirname "$P/sumdb/sum.golang.org/$t")"
			cp "$fetched/$t" "$P/sumdb/sum.golang.org/$t"
		done
	fi
	chmod -R u+w "$w"; rm -rf "$w"
done
after="$(find "$P/sumdb/sum.golang.org" -path '*/tile/*' -type f | wc -l)"
echo "sumdb-prove: $(wc -l < "$list" | tr -d ' ') answers verified against $# tree note(s); $((after - before)) proof tile(s) added"
rm -f "$list"
