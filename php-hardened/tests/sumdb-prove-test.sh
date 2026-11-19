#!/bin/sh
# Tests sumdb-prove.sh against the real Go checksum database (network and a go command required; not run by the pull
# request checks, which have no reason to depend on sum.golang.org). It builds the failure the set check met on
# 19 November 2026: two Go clients cache answers from two tree sizes, and their caches are merged, as a source set
# merges them, without the tiles that would prove the larger tree against the smaller note. Offline, the client with the
# smaller note then cannot verify. After sumdb-prove.sh, both clients can.
# Control: with the tiles sumdb-prove.sh added removed again, the offline check fails once more.
#
#   sh php-hardened/tests/sumdb-prove-test.sh [GO]
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GO="${1:-go}"
W="$(mktemp -d)"; trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
fail=0
A_MOD=github.com/pkg/errors@v0.9.1
# Client b looks up a module version whose record entered the log after client a's tree, as go-jose v4.1.9 had on
# 19 November: client a, whose tree does not contain the record, must then accept client b's larger tree, which takes a
# proof. (For a record already in client a's tree, Go proves it in that tree and needs nothing more.) B_MOD is chosen
# below from the checksum database's own data tile, once the tree has grown.
tree() { awk '/^go.sum database tree$/ { getline; print; exit }' "$1"; }

online() { # online NAME MODULE: a fresh client looks one module up, with the network
    mkdir -p "$W/$1"
    (cd "$W" && env GOPATH="$W/$1/gopath" GOMODCACHE="$W/$1/mod" GOFLAGS= GOTOOLCHAIN=local \
        GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE= "$GO" mod download "$2" > /dev/null)
}
offline() { # offline NOTE: a fresh client checks both modules from the merged records alone, with NOTE as its tree
    c="$(mktemp -d -p "$W")"
    mkdir -p "$c/gopath/pkg/sumdb/sum.golang.org"; cp "$1" "$c/gopath/pkg/sumdb/sum.golang.org/latest"
    # go mod download, as the set check does: go list -m exits 0 even when a verification fails.
    (cd "$c" && env GOPATH="$c/gopath" GOMODCACHE="$c/mod" GOFLAGS= GOTOOLCHAIN=local \
        GOPROXY="file://$W/P" GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE= "$GO" mod download "$A_MOD" "$B_MOD" > "$c/out" 2>&1)
}

online a "$A_MOD"
T1="$(tree "$W/a/gopath/pkg/sumdb/sum.golang.org/latest")"
# The tree grows every few seconds. Wait until it has crossed two 256-entry boundaries, so that the second client's answer
# is from a tree whose level-1 tile differs: the tile the set check found missing was such a tile.
n=0
until [ "$(( $(curl -fsS https://sum.golang.org/latest | awk 'NR == 2') / 256 ))" -gt "$(( T1 / 256 + 1 ))" ] 2> /dev/null; do
    n=$((n + 1)); [ "$n" -le 90 ] || { echo "FAIL: the checksum tree did not grow enough in 15 minutes"; exit 1; }
    sleep 10
done
# The first full data tile after client a's tree: every record in it has an ID larger than client a's tree. A tile index
# is written in groups of three digits, all but the last with an x (280049 is x280/049).
k=$(( T1 / 256 + 1 ))
path="$(printf '%d' "$k" | awk '{ s = $0; while (length(s) % 3) s = "0" s; out = ""; for (i = 1; i <= length(s); i += 3) { g = substr(s, i, 3); out = out (i + 3 <= length(s) ? "x" g "/" : g) } print out }')"
B_MOD="$(curl -fsS "https://sum.golang.org/tile/8/data/$path" | awk 'NF == 3 && $2 !~ /\/go\.mod$/ { print $1 "@" $2; exit }')"
case "$B_MOD" in *@v*) ;; *) echo "FAIL: no record read from data tile $path"; exit 1 ;; esac
echo "client b looks up $B_MOD, a record from data tile $path (IDs from $((k * 256)), after tree $T1)"
online b "$B_MOD"
T2="$(tree "$W/b/gopath/pkg/sumdb/sum.golang.org/latest")"
echo "client a: tree $T1; client b: tree $T2"

mkdir -p "$W/P"
cp -R "$W/a/mod/cache/download/." "$W/P/"
# Client b's answer replaces client a's, but not the tiles client b fetched to prove it: an answer from a larger tree,
# with nothing in the records that proves it against client a's note. That is the state the set check failed on, built
# directly, because which tiles two clients happen to fetch depends on timing that a test cannot fix.
(cd "$W/b/mod/cache/download" && find . -type f ! -path '*/sumdb/sum.golang.org/tile/*') | while read -r x; do
    mkdir -p "$(dirname "$W/P/$x")"; cp "$W/b/mod/cache/download/$x" "$W/P/$x"
done
chmod -R u+w "$W/P"; touch "$W/P/sumdb/sum.golang.org/supported"
NOTE_A="$W/a/gopath/pkg/sumdb/sum.golang.org/latest"; NOTE_B="$W/b/gopath/pkg/sumdb/sum.golang.org/latest"

if offline "$NOTE_A"; then
    echo "FAIL: the merged records already prove both trees offline, so the failure was not reproduced"; fail=1
else echo "ok: before sumdb-prove.sh, the merged records cannot prove tree $T1 against tree $T2 offline"; fi

(cd "$W/P" && find . -path '*/tile/*' -type f | sort) > "$W/tiles-before"
sh "$HERE/sumdb-prove.sh" "$GO" "$W/P" "$NOTE_A" "$NOTE_B"
(cd "$W/P" && find . -path '*/tile/*' -type f | sort) > "$W/tiles-after"

if offline "$NOTE_A" && offline "$NOTE_B"; then echo "ok: after sumdb-prove.sh, both clients verify both answers offline"
else echo "FAIL: still not provable offline"; cat "$c/out"; fail=1; fi

# Control: the added tiles removed again.
comm -13 "$W/tiles-before" "$W/tiles-after" > "$W/added"
if [ ! -s "$W/added" ]; then echo "FAIL: control: sumdb-prove.sh added no tile"; fail=1
else
    while read -r t; do rm -f "$W/P/$t"; done < "$W/added"
    if offline "$NOTE_A"; then echo "FAIL: control: without the added tiles the check still passes"; fail=1
    else echo "ok: control: without the $(wc -l < "$W/added" | tr -d ' ') added tile(s), the offline check fails again"; fi
fi

[ "$fail" -eq 0 ] && echo "sumdb-prove: the failure, the fix and the control behave as stated"
exit "$fail"
