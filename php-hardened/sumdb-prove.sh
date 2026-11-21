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
#   sumdb-prove.sh --partial-tiles PROXY_DIR SIZE...
#   sumdb-prove.sh --check-offline GO PROXY_DIR NOTE...
#
# GO is the go command; PROXY_DIR is a module proxy directory as the set holds it (cache/download layout, with
# sumdb/sum.golang.org/lookup and supported); each NOTE is a client's tree note, as Go keeps it in
# $GOPATH/pkg/sumdb/sum.golang.org/latest. Network required. Exit codes: 0 every answer verified against every note,
# online and then offline from PROXY_DIR alone, and the tiles that took are in PROXY_DIR; 1 an answer did not verify,
# or Go failed; 2 the input is wrong.
#
# Partial tiles (found 20 November 2026, build 44754545641). A tree whose size is not a multiple of 256 ends, at each
# level, in a partial tile, read at tile/8/<level>/<index>.p/<width>. Online, Go takes a partial tile from a wider one it
# already holds at the same place (a longer partial tile, or the full tile); read from a file:// proxy, as the set check
# reads the set, it asks for the partial tile of the exact width. The build met this with trees 71784039, 71784053 and
# 71784108, all ending in tile x280/406: online, x280/406.p/172 served for .p/117; offline, .p/117 was missing. So for
# every tree size the set names (each note, and each answer's signed tree), a missing partial tile is written from the
# narrowest wider tile present at the same place: a partial tile of width W is exactly the first W hashes, 32 bytes
# each, of any wider tile there. Then every answer is checked again against every note from PROXY_DIR alone, as the set
# check will, so that a gap fails here, while the network is still there, and not in the set check.
# --partial-tiles does only the writing, with no go and no network (the structure tests run it). --check-offline skips
# the network step: it writes the partial tiles and runs the offline check on the records as they are (the live test).
set -eu

# A tile index in groups of three digits, all but the last with an x: 280406 is x280/406, 5 is 005.
tile_index() {
	printf '%d' "$1" | awk '{ s = $0; while (length(s) % 3) s = "0" s; out = ""; for (i = 1; i <= length(s); i += 3) { g = substr(s, i, 3); out = out (i + 3 <= length(s) ? "x" g "/" : g) } print out }'
}
# partial_tiles DIR SIZE...: writes each missing partial hash tile from its full tile; prints how many it wrote.
partial_tiles() {
	tiles="$1/sumdb/sum.golang.org/tile/8"; shift
	written=0
	for size in "$@"; do
		case "$size" in '' | *[!0-9]*) echo "sumdb-prove: '$size' is not a tree size" >&2; exit 2 ;; esac
		level=0; n="$size"
		while [ "$n" -gt 0 ]; do
			index=$((n / 256)); width=$((n % 256))
			if [ "$width" -gt 0 ]; then
				full="$tiles/$level/$(tile_index "$index")"
				part="$full.p/$width"
				if [ ! -f "$part" ]; then
					# The source: the full tile, else the narrowest partial tile at the same index that is wider.
					source=""
					if [ -f "$full" ]; then
						source="$full"; hashes=256
					elif [ -d "$full.p" ]; then
						hashes=""
						for wider in "$full.p"/*; do
							w="${wider##*/}"
							case "$w" in '' | *[!0-9]*) continue ;; esac
							if [ "$w" -gt "$width" ] && { [ -z "$hashes" ] || [ "$w" -lt "$hashes" ]; }; then hashes="$w"; fi
						done
						[ -n "$hashes" ] && source="$full.p/$hashes"
					fi
					if [ -n "$source" ]; then
						[ "$(wc -c < "$source")" -eq $((hashes * 32)) ] \
							|| { echo "sumdb-prove: $source does not hold $hashes hashes" >&2; exit 1; }
						mkdir -p "$(dirname "$part")"
						head -c $((width * 32)) "$source" > "$part"
						written=$((written + 1))
					fi
				fi
			fi
			n="$index"; level=$((level + 1))
		done
	done
	echo "$written"
}
if [ "${1:-}" = --partial-tiles ]; then
	[ -d "${2:-}" ] || { echo "sumdb-prove: no proxy directory '${2:-}'" >&2; exit 2; }
	d="$2"; shift 2
	[ "$#" -gt 0 ] || { echo "sumdb-prove: no tree size given" >&2; exit 2; }
	partial_tiles "$d" "$@" > /dev/null
	exit 0
fi

# --check-offline: no network step; only the partial tiles and the offline check, on records as they are (the tests).
online=yes
if [ "${1:-}" = --check-offline ]; then online=no; shift; fi
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
	[ "$online" = yes ] || break
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
		GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= \
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

# The partial tiles for every tree size the set names: each note's, and each answer's signed tree's.
sizes="$(mktemp)"
for note in "$@"; do awk '/^go.sum database tree$/ { getline; print; exit }' "$note"; done > "$sizes"
find "$lookups" -type f -exec awk '/^go.sum database tree$/ { getline; print; exit }' {} \; >> "$sizes"
# shellcheck disable=SC2046 # one argument per tree size
partials="$(partial_tiles "$P" $(sort -un "$sizes"))"
rm -f "$sizes"

# Offline, as the set check reads the set: a copy of the records as a file:// proxy, with sumdb served from it
# ("supported"), the same GOSUMDB as the set check, and a fresh module cache. Every HTTP and HTTPS request goes to an
# address that refuses it, so that nothing can be fetched and a missing tile fails. (Naming a URL in GOSUMDB is not
# used for this: Go then reads the checksum database from that URL instead of from the proxy.)
# Each answer is checked on its own, against each note, by a fresh client. Go downloads several modules in no fixed
# order, and the tiles a proof reads depend on which answer a client meets first (on 20 November, meeting tree 71784108
# before 71784053 needed only .p/172; the other order needed .p/117). One answer per client is the order-free case.
o="$(mktemp -d)"
mkdir -p "$o/proxy" && cp -R "$P/." "$o/proxy/"
touch "$o/proxy/sumdb/sum.golang.org/supported"
# As the set writer prepares the set (build-frankenphp.sh, after the module caches are copied): Go keeps no .info for a
# module it fetched only as a requirement, but reading a version from a file proxy needs one, so it is written for
# every version the records hold; and Go's lock files are dropped. (Found on 21 November 2026, build 44876161556:
# without this, the check failed on cel.dev/cel-go@v0.32.0's missing .info, which the set itself would have had.)
find "$o/proxy" -name '*.mod' -path '*/@v/*' | while read -r mod; do
	info="${mod%.mod}.info"
	[ -f "$info" ] || printf '{"Version":"%s"}\n' "$(basename "${mod%.mod}")" > "$info"
done
find "$o/proxy" -name '*.lock' -delete
unread=0
for note in "$@"; do
	while read -r m; do
		# An answer Go cached while resolving, for a version whose files it never fetched (no go.mod, no zip), is read by
		# no rebuild: the set check reads an answer only for a version it downloads, and it can download only what the
		# records hold. (Found on 21 November 2026, run 44881384791: github.com/dlclark/regexp2@v1.11.5.) Such answers
		# are counted, not checked. A rebuild that needed one would fail set-check, which refuses a set missing a
		# selected module (tests/set-check-zips-test.sh).
		mpath="${m%@*}"; mver="${m##*@}"
		vdir="$o/proxy/$(printf '%s' "$mpath" | sed 's/[A-Z]/!&/g' | tr '[:upper:]' '[:lower:]')/@v/$(printf '%s' "$mver" | sed 's/[A-Z]/!&/g' | tr '[:upper:]' '[:lower:]')"
		if [ ! -f "$vdir.mod" ]; then
			[ "$note" = "$1" ] && unread=$((unread + 1))
			continue
		fi
		c="$(mktemp -d -p "$o")"
		mkdir -p "$c/gopath/pkg/sumdb/sum.golang.org"
		cp "$note" "$c/gopath/pkg/sumdb/sum.golang.org/latest"
		# A version the build used only to resolve requirements has its go.mod in the records but no zip, and the set
		# check verifies only that go.mod. go mod download always asks for the zip, so with -json the result is read:
		# with the zip in the records, the download must succeed; without it, go.mod must have verified (GoModSum set)
		# and the missing zip must be the only error. A verification failure leaves GoModSum empty and names it.
		(cd "$c" && env GOPATH="$c/gopath" GOMODCACHE="$c/mod" GOFLAGS=-mod=mod GOTOOLCHAIN=local \
			GOPROXY="file://$o/proxy" GOSUMDB=sum.golang.org GONOSUMDB= GONOSUMCHECK= GOPRIVATE= GOINSECURE= \
			HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 NO_PROXY= no_proxy= \
			"$go" mod download -json "$m" > "$c/out" 2> "$c/err") && rc=0 || rc=$?
		zip="$vdir.zip"
		verified=no
		if [ -f "$zip" ]; then
			[ "$rc" -eq 0 ] && ! grep -q '"Error"' "$c/out" && verified=yes
		elif grep -q '"GoModSum": "h1:' "$c/out" \
			&& [ "$(grep -c '"Error"' "$c/out")" -eq 1 ] \
			&& grep -q '"Error": ".*\.zip: no such file or directory"' "$c/out" \
			&& ! grep -q 'verifying' "$c/out"; then
			verified=yes
		fi
		if [ "$verified" != yes ]; then
			grep -h '"Error"' "$c/out" | head -n 3 >&2
			grep -v '^go: downloading' "$c/err" | head -n 5 >&2
			echo "sumdb-prove: offline, from the records alone, the answer for $m did not verify against the note $note" >&2
			chmod -R u+w "$o"; rm -rf "$o"
			exit 1
		fi
		chmod -R u+w "$c"; rm -rf "$c"
	done < "$list"
done
chmod -R u+w "$o"; rm -rf "$o"

after="$(find "$P/sumdb/sum.golang.org" -path '*/tile/*' -type f | wc -l)"
echo "sumdb-prove: $(( $(wc -l < "$list") - unread )) answers verified against $# tree note(s), $([ "$online" = yes ] && echo "online and ")offline, one answer per client; $unread answer(s) for versions with no module files in the records, read by no rebuild, not checked; $((after - before)) proof tile(s) added, $partials of them partial tiles written from wider tiles"
rm -f "$list"
