#!/bin/sh
# Tests the weekly download cache between jobs (K-REG-1). Each check has a control that must fail:
#   T1  build.yml's cache key and the Dockerfile's cache id are built from the same revision, architecture and ISO week,
#       the revision read from the Dockerfile itself;
#   T4  downloads-cache.sh no-token refuses a directory holding the token, and passes one that does not;
#   T8  downloads-cache.sh seed uses only what matches an attested manifest: an altered, unlisted or missing file leaves
#       its whole entry out, and a manifest whose attestation does not verify, or that names a path outside the cache,
#       leaves the seed empty. The attestation check is stubbed here (gh on PATH); the real one runs in the workflow.
#   T5  the save steps run whether the source set passed or failed, and the save needs a verified attestation.
#   T6/T7 are in download-fault-test.sh and the existing tests.
# No network.
#
#   sh php-hardened/tests/downloads-cache-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
DF="$HERE/Dockerfile"
WF="$REPO/.github/workflows/build.yml"
SCRIPT="$HERE/downloads-cache.sh"

# --- T1 ---------------------------------------------------------------------------------------------------------------
t1() { # t1 DOCKERFILE WORKFLOW
	grep -q '^ARG SOURCES_REVISION=[0-9][0-9]*$' "$1" || return 1
	# Every cache mount of the downloads uses the one name.
	n="$(grep -c 'type=cache,id=spc-sources-\${SOURCES_REVISION}-\${TARGETARCH}-\${SOURCES_EPOCH},' "$1")"
	all="$(grep -c 'type=cache,id=spc-sources-' "$1")"
	[ "$n" -ge 4 ] && [ "$n" = "$all" ] || return 1
	grep -q "CACHE_PREFIX: spc-sources-\${{ needs.resolve.outputs.revision }}-\${{ matrix.platform.arch }}-\${{ needs.resolve.outputs.epoch }}-$" "$2" || return 1
	grep -q "sed -n 's/^ARG SOURCES_REVISION=" "$2" || return 1
	grep -q 'echo "epoch=$(date -u +%G-W%V)"' "$2" || return 1
}
if t1 "$DF" "$WF"; then ok "T1: the saved cache's key and the Dockerfile's cache name use the same revision, architecture and week"
else bad "T1: the cache key and the Dockerfile's cache name differ"; fi
sed 's/-\${{ needs.resolve.outputs.epoch }}-$/-/' "$WF" > "$W/wf-no-week"
if t1 "$DF" "$W/wf-no-week"; then bad "T1 control: a key without the ISO week passed"
else ok "T1 control: a key without the ISO week fails"; fi

# --- T4 ---------------------------------------------------------------------------------------------------------------
mkdir -p "$W/t4/clean" "$W/t4/dirty/sub"
printf 'archive\n' > "$W/t4/clean/a.tar.gz"
printf 'archive\n' > "$W/t4/dirty/a.tar.gz"
STAND_IN="ghs_standin0000000000000000000000000000"
printf 'header Authorization: token %s\n' "$STAND_IN" > "$W/t4/dirty/sub/curl-config"
if TOKEN="$STAND_IN" sh "$SCRIPT" no-token "$W/t4/clean" > /dev/null 2>&1; then ok "T4: a directory without the token passes"
else bad "T4: a directory without the token was refused"; fi
if TOKEN="$STAND_IN" sh "$SCRIPT" no-token "$W/t4/dirty" > "$W/t4/out" 2>&1; then bad "T4 control: a directory holding the token passed"
elif grep -qF "$STAND_IN" "$W/t4/out"; then bad "T4 control: refused, but the token was printed"
else ok "T4 control: a directory holding the token is refused, and the token is not printed"; fi

# --- T8 ---------------------------------------------------------------------------------------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'GH'
#!/bin/sh
# Stand-in for gh attestation verify: passes only when the manifest's SHA-256 is the one recorded as attested.
[ "$1 $2" = "attestation verify" ] || exit 2
[ "$(sha256sum "$3" | cut -d' ' -f1)" = "$(cat "$ATTESTED")" ]
GH
chmod +x "$W/bin/gh"
make_cache() { # make_cache DIR: a downloads directory with an archive, a git checkout and the lock file
	mkdir -p "$1/libfoo/.git" "$1/libfoo/src"
	printf 'tarball of libbar\n' > "$1/libbar-1.2.tar.gz"
	printf 'tarball of libbaz\n' > "$1/libbaz-3.0.tar.xz"
	printf 'ref: refs/heads/main\n' > "$1/libfoo/.git/HEAD"
	printf 'int main(void){return 0;}\n' > "$1/libfoo/src/main.c"
	printf '{"libbar":{}}\n' > "$1/.cache.json"
	sh "$SCRIPT" manifest "$1" > /dev/null
	sha256sum "$1/SHA256SUMS" | cut -d' ' -f1 > "$W/attested"
}
seed() { # seed CACHE SEED [SCRIPT]
	rm -rf "$2"; PATH="$W/bin:$PATH" ATTESTED="$W/attested" sh "${3:-$SCRIPT}" seed "$1" "$2" refs/heads/master kipchak-dev/runtime-image
}
has() { [ -e "$1" ]; }

make_cache "$W/c1"; seed "$W/c1" "$W/s1" > /dev/null
if has "$W/s1/libbar-1.2.tar.gz" && has "$W/s1/libfoo/src/main.c" && has "$W/s1/.cache.json" && ! has "$W/s1/SHA256SUMS"; then
	ok "T8: a cache that matches its attested manifest is used whole"
else bad "T8: a matching cache was not used whole"; fi

make_cache "$W/c2"; printf 'altered\n' >> "$W/c2/libbar-1.2.tar.gz"; seed "$W/c2" "$W/s2" > /dev/null
if ! has "$W/s2/libbar-1.2.tar.gz" && has "$W/s2/libbaz-3.0.tar.xz"; then ok "T8: an archive altered after the save is left out, and downloaded again"
else bad "T8: an altered archive reached the seed"; fi

make_cache "$W/c3"; printf 'changed\n' >> "$W/c3/libfoo/src/main.c"; seed "$W/c3" "$W/s3" > /dev/null
if ! has "$W/s3/libfoo" && has "$W/s3/libbar-1.2.tar.gz"; then ok "T8: one altered file in a git checkout leaves the whole checkout out"
else bad "T8: a partly altered checkout reached the seed"; fi

make_cache "$W/c4"; printf 'extra\n' > "$W/c4/libqux-9.tar.gz"; rm "$W/c4/libbaz-3.0.tar.xz"; seed "$W/c4" "$W/s4" > /dev/null
if ! has "$W/s4/libqux-9.tar.gz" && ! has "$W/s4/libbaz-3.0.tar.xz" && has "$W/s4/libbar-1.2.tar.gz"; then
	ok "T8: an unlisted file is left out, and a missing one is not invented"
else bad "T8: an unlisted file reached the seed"; fi

make_cache "$W/c5"; printf 'other\n' > "$W/attested"; seed "$W/c5" "$W/s5" > /dev/null
if [ -z "$(ls -A "$W/s5")" ]; then ok "T8: a manifest whose attestation does not verify leaves the seed empty"
else bad "T8: an unverified manifest was used"; fi

make_cache "$W/c6"; printf '%064d  ../../etc/passwd\n' 0 >> "$W/c6/SHA256SUMS"; sha256sum "$W/c6/SHA256SUMS" | cut -d' ' -f1 > "$W/attested"
seed "$W/c6" "$W/s6" > /dev/null
if [ -z "$(ls -A "$W/s6")" ]; then ok "T8: a manifest naming a path outside the cache leaves the seed empty"
else bad "T8: a manifest with an outside path was used"; fi

mkdir -p "$W/c7"; printf 'x\n' > "$W/c7/a.tar.gz"; seed "$W/c7" "$W/s7" > /dev/null
if [ -z "$(ls -A "$W/s7")" ]; then ok "T8: a cache without a manifest leaves the seed empty"
else bad "T8: a cache without a manifest was used"; fi

# Control: with the comparison against the manifest removed, the altered archive reaches the seed, so the checks above
# depend on it.
sed 's/sha256sum -c SHA256SUMS/true/' "$SCRIPT" > "$W/no-check.sh"
make_cache "$W/c8"; printf 'altered\n' >> "$W/c8/libbar-1.2.tar.gz"; seed "$W/c8" "$W/s8" "$W/no-check.sh" > /dev/null
if has "$W/s8/libbar-1.2.tar.gz"; then ok "T8 control: without the check, the altered archive reaches the seed"
else bad "T8 control: the altered archive was left out even without the check"; fi

# --- T5 and the wiring ------------------------------------------------------------------------------------------------
t5() { # t5 WORKFLOW
	awk '/- name: Clear the restored downloads/,/- name: Build the runtime/' "$1" > "$W/save-block"
	grep -q "if: \${{ !cancelled() }}" "$W/save-block" || return 1
	grep -q "if: \${{ !cancelled() && steps.downloads-attest.outcome == 'success' }}" "$W/save-block" || return 1
	grep -q 'downloads-cache.sh no-token' "$W/save-block" || return 1
	# The save comes before the runtime build, and the restore check before the source set.
	awk '/Check the restored downloads/ { c = NR } /- name: Build the source set$/ { s = NR } END { exit !(c && s && c < s) }' "$1" || return 1
	grep -q 'build-contexts: downloads-seed=' "$1" || return 1
}
if t5 "$WF"; then ok "T5: the downloads are saved whether the source set passed or failed, only with an attested manifest and no token"
else bad "T5: the save steps are not wired as stated"; fi
sed "s/        if: \${{ !cancelled() }}/        if: success()/" "$WF" > "$W/wf-success-only"
if t5 "$W/wf-success-only"; then bad "T5 control: a save that runs only on success passed"
else ok "T5 control: a save that runs only on success fails"; fi
grep -q 'FROM scratch AS downloads-seed' "$DF" && grep -q 'type=bind,from=downloads-seed,target=/downloads-seed' "$DF" \
	&& grep -q 'FROM scratch AS downloads-out' "$DF" \
	&& ok "the Dockerfile copies the seed into the download cache and can copy the cache out" \
	|| bad "the Dockerfile's seed and copy-out stages are not as stated"

[ "$fail" -eq 0 ] && echo "downloads-cache: every case behaves as stated"
exit "$fail"
