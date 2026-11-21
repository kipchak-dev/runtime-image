#!/bin/sh
# Tests sumdb-prove.sh against the real Go checksum database (network and a go command required; not run by the pull
# request checks, which have no reason to depend on sum.golang.org). It builds the failure the set check met on
# 19 November 2026: two Go clients cache answers from two tree sizes, and their caches are merged, as a source set
# merges them, without the tiles that would prove the larger tree against the smaller note. Offline, the client with the
# smaller note then cannot verify. After sumdb-prove.sh, both clients can.
# Control: with the tiles sumdb-prove.sh added removed again, the offline check fails once more.
#
# The second case is the one build 44754545641 met on 20 November 2026: two notes whose trees end in the same tile, and
# records holding that full tile but not the partial tile Go reads at the larger tree's edge from a file:// proxy. Online, Go uses the full tile and
# fetches nothing, so proving online alone passed while the set check failed. sumdb-prove.sh must now write the partial
# tile and pass its own offline check. Control: the same script with the partial-tile writing removed fails, at its own
# offline check, on the same records.
#
#   sh php-hardened/tests/sumdb-prove-test.sh [GO]
# The control's sed expression matches the script's text literally.
# shellcheck disable=SC2016
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
offline() { # offline NOTE [RECORDS]: a fresh client checks both modules from the records alone (default $W/P)
    c="$(mktemp -d -p "$W")"
    mkdir -p "$c/gopath/pkg/sumdb/sum.golang.org"; cp "$1" "$c/gopath/pkg/sumdb/sum.golang.org/latest"
    # go mod download, as the set check does: go list -m exits 0 even when a verification fails.
    (cd "$c" && env GOPATH="$c/gopath" GOMODCACHE="$c/mod" GOFLAGS= GOTOOLCHAIN=local \
        GOPROXY="file://${2:-$W/P}" GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE= "$GO" mod download "$A_MOD" "$B_MOD" > "$c/out" 2>&1)
}
# A tile index in groups of three digits, all but the last with an x (280049 is x280/049).
tile_index() {
    printf '%d' "$1" | awk '{ s = $0; while (length(s) % 3) s = "0" s; out = ""; for (i = 1; i <= length(s); i += 3) { g = substr(s, i, 3); out = out (i + 3 <= length(s) ? "x" g "/" : g) } print out }'
}

# Client a starts from a fresh note taken from sum.golang.org itself: the copy the Go module proxy serves can be hours
# behind, and the second case needs a note from a few seconds later, in the same tile.
mkdir -p "$W/a/gopath/pkg/sumdb/sum.golang.org"
curl -fsS https://sum.golang.org/latest > "$W/a/gopath/pkg/sumdb/sum.golang.org/latest"
online a "$A_MOD"
T1="$(tree "$W/a/gopath/pkg/sumdb/sum.golang.org/latest")"
# The tree grows every few seconds. Wait until it has crossed two 256-entry boundaries, so that the second client's answer
# is from a tree whose level-1 tile differs: the tile the set check found missing was such a tile.
n=0
until [ "$(( $(curl -fsS https://sum.golang.org/latest | awk 'NR == 2') / 256 ))" -gt "$(( T1 / 256 + 1 ))" ] 2> /dev/null; do
    n=$((n + 1)); [ "$n" -le 240 ] || { echo "FAIL: the checksum tree did not grow enough in 40 minutes"; exit 1; }
    sleep 10
done
# The first full data tile after client a's tree: every record in it has an ID larger than client a's tree. A tile index
# is written in groups of three digits, all but the last with an x (280049 is x280/049).
k=$(( T1 / 256 + 1 ))
path="$(printf '%d' "$k" | awk '{ s = $0; while (length(s) % 3) s = "0" s; out = ""; for (i = 1; i <= length(s); i += 3) { g = substr(s, i, 3); out = out (i + 3 <= length(s) ? "x" g "/" : g) } print out }')"
# The tile's module versions, in order. Some cannot be downloaded by this go command (a newer go directive, a module
# withdrawn from the proxy), so they are tried in turn until one downloads.
curl -fsS "https://sum.golang.org/tile/8/data/$path" | awk 'NF == 3 && $2 !~ /\/go\.mod$/ { print $1 "@" $2 }' > "$W/candidates"
[ -s "$W/candidates" ] || { echo "FAIL: no record read from data tile $path"; exit 1; }
B_MOD=""
while read -r m; do
    if [ -d "$W/b" ]; then chmod -R u+w "$W/b"; rm -rf "$W/b"; fi
    if online b "$m" 2> /dev/null; then B_MOD="$m"; break; fi
done < "$W/candidates"
[ -n "$B_MOD" ] || { echo "FAIL: no module version in data tile $path could be downloaded"; exit 1; }
echo "client b looks up $B_MOD, a record from data tile $path (IDs from $((k * 256)), after tree $T1)"
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

# The second case, as build 44754545641 met it on 20 November 2026: the default client's note was tree 71784039, an
# answer it read from the merged records was signed at tree 71784053, and the xcaddy client's note was tree 71784108,
# all three ending in tile x280/406, which was not yet full. Proving 71784039 against 71784053 reads the partial tile
# x280/406.p/117. Online, Go took that from the longer partial tile x280/406.p/172 it held, and fetched nothing; from a
# file:// proxy it asked for .p/117 itself, which the set did not have.
# Built here from sum.golang.org's own answers, which are signed at a fresher tree than /latest serves: three answers,
# from the newest data tile, whose trees S1 < S2 < S3 end in one level-0 tile. The records hold the answers for S1 and
# S2 and the partial tile of S3's width at that index, but not S2's; the client's note is S1's.
lookup_tree() { awk '/^go.sum database tree$/ { getline; print; exit }' "$1"; }
L="$(curl -fsS https://sum.golang.org/latest | awk 'NR == 2')"
curl -fsS "https://sum.golang.org/tile/8/data/$(tile_index $((L / 256 - 1)))" \
    | awk 'NF == 3 && $2 !~ /\/go\.mod$/ && ($1 $2) !~ /[A-Z]/ { print $1 "@" $2 }' > "$W/fresh"
mkdir -p "$W/fresh-answers"
found=""; S1=""; S2=""; M1=""; M2=""; i=0
while read -r m; do
    i=$((i + 1))
    curl -fsS "https://sum.golang.org/lookup/$m" > "$W/fresh-answers/$i" || continue
    s="$(lookup_tree "$W/fresh-answers/$i")"
    case "$s" in '' | *[!0-9]*) continue ;; esac
    if [ -z "$S1" ] || [ $((s / 256)) -ne $((S1 / 256)) ] || [ "$s" -le "$S1" ]; then S1="$s"; M1="$m"; A1="$W/fresh-answers/$i"; S2=""; continue; fi
    if [ -z "$S2" ]; then S2="$s"; M2="$m"; A2="$W/fresh-answers/$i"; continue; fi
    if [ "$s" -gt "$S2" ] && [ $((s / 256)) -eq $((S2 / 256)) ]; then S3="$s"; found=yes; break; fi
    sleep 2
done < "$W/fresh"
[ -n "$found" ] && [ $((S1 % 256)) -gt 0 ] && [ $((S2 % 256)) -gt 0 ] \
    || { echo "FAIL: no three answers in one tile from the newest data tile; run the test again"; exit 1; }
IDX="tile/8/0/$(tile_index $((S2 / 256)))"
echo "second case: note for tree $S1; answers signed at trees $S1 ($M1) and $S2 ($M2); records hold $IDX.p/$((S3 % 256)) but not $IDX.p/$((S2 % 256))"
# A client whose cache already holds the two answers, with S1's note, downloads both modules online: Go reads the answers
# from the cache, proves S1 against S2, and keeps the tiles it fetched.
esc() { printf '%s' "$1"; } # the chosen module paths have no capitals, so need no escaping
mkdir -p "$W/c2/gopath/pkg/sumdb/sum.golang.org" "$W/c2/mod/cache/download/sumdb/sum.golang.org/lookup/$(dirname "$(esc "$M1")")" \
    "$W/c2/mod/cache/download/sumdb/sum.golang.org/lookup/$(dirname "$(esc "$M2")")"
sed -n '/^go.sum database tree$/,$p' "$A1" > "$W/note-s1"
cp "$W/note-s1" "$W/c2/gopath/pkg/sumdb/sum.golang.org/latest"
cp "$A1" "$W/c2/mod/cache/download/sumdb/sum.golang.org/lookup/$(esc "$M1")"
cp "$A2" "$W/c2/mod/cache/download/sumdb/sum.golang.org/lookup/$(esc "$M2")"
(cd "$W" && env GOPATH="$W/c2/gopath" GOMODCACHE="$W/c2/mod" GOFLAGS= GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org \
    GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE= "$GO" mod download "$M1" "$M2" > /dev/null) \
    || { echo "FAIL: the online client could not download $M1 and $M2"; exit 1; }
mkdir -p "$W/P2"; cp -R "$W/c2/mod/cache/download/." "$W/P2/"; chmod -R u+w "$W/P2"
touch "$W/P2/sumdb/sum.golang.org/supported"
# The answers as signed at S1 and S2 (Go may have refreshed them). At the index, the tiles the client fetched stay, except
# S2's partial tile and any full tile; S3's wider partial tile is added. That is the set the build made: the wider tile
# present (it had served online), the exact one absent.
cp "$A1" "$W/P2/sumdb/sum.golang.org/lookup/$(esc "$M1")"; cp "$A2" "$W/P2/sumdb/sum.golang.org/lookup/$(esc "$M2")"
rm -f "$W/P2/sumdb/sum.golang.org/$IDX" "$W/P2/sumdb/sum.golang.org/$IDX.p/$((S2 % 256))"
mkdir -p "$W/P2/sumdb/sum.golang.org/$IDX.p"
curl -fsS "https://sum.golang.org/$IDX.p/$((S3 % 256))" > "$W/P2/sumdb/sum.golang.org/$IDX.p/$((S3 % 256))"
[ "$(wc -c < "$W/P2/sumdb/sum.golang.org/$IDX.p/$((S3 % 256))")" -eq $(( (S3 % 256) * 32 )) ] || { echo "FAIL: the partial tile for S3 is not $((S3 % 256)) hashes"; exit 1; }
cp -R "$W/P2" "$W/P2-control"
near() { # near RECORDS: a fresh client with S1's note checks both modules from the records alone
    c="$(mktemp -d -p "$W")"
    mkdir -p "$c/gopath/pkg/sumdb/sum.golang.org"; cp "$W/note-s1" "$c/gopath/pkg/sumdb/sum.golang.org/latest"
    (cd "$c" && env GOPATH="$c/gopath" GOMODCACHE="$c/mod" GOFLAGS= GOTOOLCHAIN=local \
        GOPROXY="file://$1" GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE= "$GO" mod download "$M1" "$M2" > "$c/out" 2>&1)
}
if near "$W/P2"; then
    echo "FAIL: the second case's records already verify offline, so the failure was not reproduced"; fail=1
elif grep -q "$IDX.p/$((S2 % 256))" "$c/out"; then
    echo "ok: before sumdb-prove.sh, the check fails offline reading $IDX.p/$((S2 % 256)), as the build did"
else echo "FAIL: it failed offline, but not on that partial tile:"; tail -n 2 "$c/out"; fail=1; fi
if sh "$HERE/sumdb-prove.sh" --check-offline "$GO" "$W/P2" "$W/note-s1" && near "$W/P2"; then
    echo "ok: sumdb-prove.sh writes the partial tile, passes its own offline check, and the client verifies offline"
else echo "FAIL: the second case is not fixed"; tail -n 3 "$c/out"; fail=1; fi
# Control (architect AM1): a derived tile is safe only because Go checks every tile against the signed tree note. The
# derived .p tile with one hash byte altered must be refused with a verification error, not a missing-tile error. It is
# run with the caller's environment turning verification off every way Go allows, to show the script turns it back on.
cp -R "$W/P2" "$W/P2-tamper"
T="$W/P2-tamper/sumdb/sum.golang.org/$IDX.p/$((S2 % 256))"
[ -f "$T" ] || { echo "FAIL: control AM1: no derived tile $IDX.p/$((S2 % 256)) to alter"; exit 1; }
n=$(wc -c < "$T"); last=$(tail -c 1 "$T" | od -An -tu1 | tr -d ' ')
head -c $((n - 1)) "$T" > "$T.new"
if [ "$last" = 65 ]; then printf 'B' >> "$T.new"; else printf 'A' >> "$T.new"; fi
mv "$T.new" "$T"
if env GONOSUMDB='*' GONOSUMCHECK=1 GONOSUMVERIFY=1 GOPRIVATE='*' GOINSECURE='*' GOFLAGS=-insecure GOSUMDB=off \
    sh "$HERE/sumdb-prove.sh" --check-offline "$GO" "$W/P2-tamper" "$W/note-s1" > "$W/tamper.out" 2>&1; then
    echo "FAIL: control AM1: an altered tile was accepted"; fail=1
elif grep -q 'no such file' "$W/tamper.out"; then
    echo "FAIL: control AM1: it failed on a missing tile, not on verification:"; tail -n 3 "$W/tamper.out"; fail=1
elif grep -q 'did not verify' "$W/tamper.out" && grep -qiE 'verif|security|inconsistent|mismatch' "$W/tamper.out"; then
    echo "ok: control AM1: an altered derived tile is refused by verification, with verification switched off in the caller's environment"
    grep -iE 'verif|security|inconsistent|mismatch' "$W/tamper.out" | grep -v 'did not verify' | head -n 1 | cut -c1-200 | sed 's/^/    /'
else echo "FAIL: control AM1: it failed, but not as a verification error:"; tail -n 3 "$W/tamper.out"; fail=1; fi
# Control: the partial-tile writing removed. The script's own offline check must then fail on the same records.
sed 's/head -c \$((width \* 32)) "\$source" > "\$part"/: > \/dev\/null/' "$HERE/sumdb-prove.sh" > "$W/no-partials.sh"
if cmp -s "$HERE/sumdb-prove.sh" "$W/no-partials.sh"; then echo "FAIL: control: the sed changed nothing"; fail=1
elif sh "$W/no-partials.sh" --check-offline "$GO" "$W/P2-control" "$W/note-s1" > "$W/control.out" 2>&1; then
    echo "FAIL: control: without the partial tiles, sumdb-prove.sh still passed"; tail -n 2 "$W/control.out"; fail=1
elif grep -q 'offline, from the records alone' "$W/control.out"; then
    echo "ok: control: without the partial tiles, sumdb-prove.sh fails at its own offline check"
else echo "FAIL: control: it failed, but not at the offline check:"; tail -n 3 "$W/control.out"; fail=1; fi

# The third case (build 44876161556, 21 November 2026): a version the build used only to resolve requirements has its
# go.mod in the records, but no zip and no .info. The set check verifies only its go.mod, so the offline check must
# too, and must read the records as the set writer prepares them (.info written). Client a's records, with its module's
# zip and .info removed.
mkdir -p "$W/P3"; cp -R "$W/a/mod/cache/download/." "$W/P3/"; chmod -R u+w "$W/P3"
v="$W/P3/$(printf '%s' "${A_MOD%@*}" | tr '[:upper:]' '[:lower:]')/@v/${A_MOD##*@}"
rm -f "$v.zip" "$v.ziphash" "$v.info"
cp -R "$W/P3" "$W/P3-tamper"; cp -R "$W/P3" "$W/P3-control"
three() { # three SCRIPT RECORDS OUT
    sh "$1" --check-offline "$GO" "$2" "$NOTE_A" > "$3" 2>&1
}
if three "$HERE/sumdb-prove.sh" "$W/P3" "$W/three.out"; then
    echo "ok: third case: a version with go.mod and no zip or .info verifies offline, on its go.mod"
else echo "FAIL: third case: it did not verify:"; tail -n 3 "$W/three.out"; fail=1; fi
t="$(find "$W/P3-tamper/sumdb/sum.golang.org/tile" -type f | head -n 1)"
n=$(wc -c < "$t"); head -c $((n - 1)) "$t" > "$t.new"; printf 'Z' >> "$t.new"; mv "$t.new" "$t"
if three "$HERE/sumdb-prove.sh" "$W/P3-tamper" "$W/three-t.out"; then
    echo "FAIL: third case, control: an altered tile was accepted for a version with no zip"; fail=1
elif grep -q 'verifying go.mod' "$W/three-t.out" && ! grep -q 'no such file' "$W/three-t.out"; then
    echo "ok: third case, control: an altered tile is refused as a go.mod verification error"
else echo "FAIL: third case, control: it failed, but not on verification:"; tail -n 3 "$W/three-t.out"; fail=1; fi
sed '/\[ -f "\$info" \] || printf/d' "$HERE/sumdb-prove.sh" > "$W/no-info.sh"
if cmp -s "$HERE/sumdb-prove.sh" "$W/no-info.sh"; then echo "FAIL: third case, control: the sed changed nothing"; fail=1
elif three "$W/no-info.sh" "$W/P3-control" "$W/three-c.out"; then
    echo "FAIL: third case, control: without the .info writing, the check still passed"; fail=1
elif grep -q '\.info: no such file' "$W/three-c.out"; then
    echo "ok: third case, control: without the .info writing, the check fails as build 44876161556 did"
else echo "FAIL: third case, control: it failed, but not on .info:"; tail -n 3 "$W/three-c.out"; fail=1; fi

[ "$fail" -eq 0 ] && echo "sumdb-prove: the failure, the fix and the control behave as stated"
exit "$fail"
