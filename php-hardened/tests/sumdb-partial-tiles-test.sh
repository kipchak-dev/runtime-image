#!/bin/sh
# Tests sumdb-prove.sh --partial-tiles, with no network and no go command: from a full hash tile, the partial tile a
# tree of a given size ends in is written as the full tile's first W hashes, at the path Go reads from a file:// proxy.
# Then each safeguard is removed from a copy of the script, and the case that guards it must fail.
#
#   sh php-hardened/tests/sumdb-partial-tiles-test.sh
#
# The controls' sed expressions match the script's text literally, so their dollar signs must not expand.
# shellcheck disable=SC2016
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/sumdb-prove.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0

# A full tile of 256 hashes, 32 bytes each, every byte different from its neighbours, so a wrong prefix shows.
awk 'BEGIN { for (i = 0; i < 8192; i++) printf "%c", 65 + (i % 26) }' > "$W/full-tile"
[ "$(wc -c < "$W/full-tile")" -eq 8192 ] || { echo "FAIL: the test tile is not 8192 bytes"; exit 1; }

# The case of build 44754545641: tree 71784053 ends at level 0 in tile 280406 (x280/406), width 117, and at level 1 in
# tile 1095 (x001/095), width 86.
SIZE=71784053
setup() {
    D="$W/p"; rm -rf "$D"; mkdir -p "$D/sumdb/sum.golang.org/tile/8/0/x280"
    cp "$W/full-tile" "$D/sumdb/sum.golang.org/tile/8/0/x280/406"
}
run() { # run SCRIPT [SIZE...]
    s="$1"; shift
    status=0; sh "$s" --partial-tiles "$D" "$@" > "$W/out" 2>&1 || status=$?
}
PART="sumdb/sum.golang.org/tile/8/0/x280/406.p/117"

case_written() {
    setup; run "$1" "$SIZE"
    [ "$status" -eq 0 ] && [ -f "$D/$PART" ] && [ "$(wc -c < "$D/$PART")" -eq $((117 * 32)) ] \
        && head -c $((117 * 32)) "$W/full-tile" | cmp -s - "$D/$PART"
}
# Where the full tile is absent (level 1 here), nothing is invented.
case_no_full_no_partial() { setup; run "$1" "$SIZE"; [ "$status" -eq 0 ] && [ ! -e "$D/sumdb/sum.golang.org/tile/8/1/x001/095.p/86" ]; }
# A partial tile already present is kept as it is.
case_existing_kept() {
    setup; mkdir -p "$(dirname "$D/$PART")"; printf 'kept' > "$D/$PART"; run "$1" "$SIZE"
    [ "$status" -eq 0 ] && [ "$(cat "$D/$PART")" = kept ]; }
# A size that is a multiple of 256 at level 0 needs no partial tile there.
case_multiple_of_256() { setup; run "$1" $((280406 * 256)); [ "$status" -eq 0 ] && [ ! -e "$D/sumdb/sum.golang.org/tile/8/0/x280/406.p" ]; }
# A short "full" tile is refused, never cut into a wrong partial tile.
case_short_full() {
    setup; head -c 8000 "$W/full-tile" > "$D/sumdb/sum.golang.org/tile/8/0/x280/406"; run "$1" "$SIZE"
    [ "$status" -eq 1 ] && [ ! -e "$D/$PART" ]; }
case_bad_size() { setup; run "$1" 7178405x; [ "$status" -eq 2 ]; }
# The build's own case: no full tile yet, a longer partial tile (172 wide, from the larger note) present, and the
# partial tile 117 wide that tree 71784053 needs is written as its prefix.
case_from_longer_partial() {
    D="$W/p"; rm -rf "$D"; mkdir -p "$D/sumdb/sum.golang.org/tile/8/0/x280/406.p"
    head -c $((172 * 32)) "$W/full-tile" > "$D/sumdb/sum.golang.org/tile/8/0/x280/406.p/172"
    run "$1" "$SIZE"
    [ "$status" -eq 0 ] && [ -f "$D/$PART" ] && head -c $((117 * 32)) "$W/full-tile" | cmp -s - "$D/$PART"
}
# Of several wider partial tiles, the narrowest is used; a wider one with other bytes is not read. (The tiles at one
# place agree in a real record; the differing bytes only show which was read.)
case_narrowest_wider() {
    D="$W/p"; rm -rf "$D"; mkdir -p "$D/sumdb/sum.golang.org/tile/8/0/x280/406.p"
    head -c $((172 * 32)) "$W/full-tile" > "$D/sumdb/sum.golang.org/tile/8/0/x280/406.p/172"
    awk 'BEGIN { for (i = 0; i < 250 * 32; i++) printf "z" }' > "$D/sumdb/sum.golang.org/tile/8/0/x280/406.p/250"
    run "$1" "$SIZE"
    [ "$status" -eq 0 ] && [ -f "$D/$PART" ] && head -c $((117 * 32)) "$W/full-tile" | cmp -s - "$D/$PART"
}
case_small_index() { # index 5 is written 005
    D="$W/p"; rm -rf "$D"; mkdir -p "$D/sumdb/sum.golang.org/tile/8/0"; cp "$W/full-tile" "$D/sumdb/sum.golang.org/tile/8/0/005"
    run "$1" $((5 * 256 + 3)); [ "$status" -eq 0 ] && [ -f "$D/sumdb/sum.golang.org/tile/8/0/005.p/3" ] \
        && [ "$(wc -c < "$D/sumdb/sum.golang.org/tile/8/0/005.p/3")" -eq 96 ]; }

for c in written no_full_no_partial existing_kept multiple_of_256 short_full bad_size small_index from_longer_partial narrowest_wider; do
    if "case_$c" "$SCRIPT"; then echo "ok: $c"; else echo "FAIL: $c (exit $status)"; sed 's/^/    /' "$W/out"; fail=1; fi
done

control() { # control CASE SED
    sed "$2" "$SCRIPT" > "$W/broken.sh"
    if cmp -s "$SCRIPT" "$W/broken.sh"; then echo "FAIL: control $1 changed nothing"; fail=1; return; fi
    if "case_$1" "$W/broken.sh"; then echo "FAIL: control $1: the case still passes without its safeguard"; fail=1
    else echo "ok: control $1"; fi
}
control written 's/head -c \$((width \* 32)) "\$source" > "\$part"/: > "$part"/'
control existing_kept 's/if \[ ! -f "\$part" \]; then/if true; then/'
control no_full_no_partial 's/if \[ -n "\$source" \]; then/if mkdir -p "$(dirname "$part")" && : > "$part"; then/'
control short_full 's/\[ "\$(wc -c < "\$source")" -eq \$((hashes \* 32)) \] \\/true \\/'
control from_longer_partial 's/elif \[ -d "\$full.p" \]; then/elif false; then/'
control narrowest_wider 's/\[ "\$w" -lt "\$hashes" \]/[ "$w" -gt "$hashes" ]/'
control small_index 's/while (length(s) % 3) s = "0" s;//'

[ "$fail" -eq 0 ] && echo "sumdb-partial-tiles: every case and control behaves as stated"
exit "$fail"
