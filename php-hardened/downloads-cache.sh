#!/bin/sh
# The weekly download cache between GitHub Actions jobs (K-REG-1). The Dockerfile keeps static-php-cli's downloads in a
# BuildKit cache mount named for the ISO week, but each GitHub job starts on a fresh runner, so build.yml saves the
# downloads directory after a build and restores it before the next one. A restored cache is a store that other jobs
# wrote, so it is used only after this script has checked it:
#
#   downloads-cache.sh manifest DIR
#       Writes DIR/SHA256SUMS: the SHA-256 of every file under DIR. build.yml attests it with the identity of
#       .github/workflows/build.yml on the branch that ran, then saves DIR.
#   downloads-cache.sh seed CACHE SEED REF REPO
#       Fills SEED, the build context the download step copies from, with what may be used from the restored CACHE:
#       the manifest's attestation must verify for REPO's build.yml on REF (gh attestation verify), and every file
#       must match the manifest. An entry of the downloads directory (an archive, or a directory such as a git
#       checkout) with any file that does not match, is not listed, or is missing, is left out, so static-php-cli
#       downloads it again. A missing manifest, an attestation that does not verify, or a manifest naming a path outside
#       CACHE leaves SEED empty. Every failure falls back to a fresh download, never to an unchecked file.
#   downloads-cache.sh no-token DIR
#       Fails if any file under DIR contains the value of the environment variable TOKEN. Prints file names only.
set -eu

die() { echo "downloads-cache: $*" >&2; exit 1; }

manifest() {
	[ -d "$1" ] || die "no directory '$1'"
	(cd "$1" && rm -f SHA256SUMS && find . -type f -print | LC_ALL=C sort > /tmp/downloads-cache-files.$$ \
		&& tr '\n' '\0' < /tmp/downloads-cache-files.$$ | xargs -0 -r sha256sum > SHA256SUMS.tmp \
		&& mv SHA256SUMS.tmp SHA256SUMS && rm -f /tmp/downloads-cache-files.$$)
	echo "downloads-cache: manifest of $(grep -c . "$1/SHA256SUMS" || true) file(s) written"
}

# top PATH: the entry of the downloads directory that holds PATH (./a/b/c -> a).
top() { printf '%s\n' "$1" | sed -e 's#^\./##' -e 's#/.*##'; }

seed() {
	cache="$1" out="$2" ref="$3" repo="$4"
	mkdir -p "$out"
	[ -z "$(ls -A "$out")" ] || die "the seed directory '$out' is not empty"
	if [ ! -s "$cache/SHA256SUMS" ]; then
		echo "downloads-cache: no cache restored, or it has no manifest; every download is made afresh"
		return 0
	fi
	if ! gh attestation verify "$cache/SHA256SUMS" --repo "$repo" \
		--signer-workflow "$repo/.github/workflows/build.yml" --source-ref "$ref" > /dev/null 2>&1; then
		echo "downloads-cache: the manifest's attestation did not verify for $repo build.yml on $ref; the restored cache is discarded"
		return 0
	fi
	# Every path in the manifest must be a plain relative path inside the cache.
	if awk '{ p = substr($0, 67) } p !~ /^\.\// || p ~ /(^|\/)\.\.(\/|$)/ || p ~ /\/\// { bad = 1 } END { exit !bad }' "$cache/SHA256SUMS"; then
		echo "downloads-cache: the manifest names a path outside the cache; the restored cache is discarded"
		return 0
	fi
	w="$(mktemp -d)"
	(cd "$cache" && find . -type f ! -path ./SHA256SUMS -print | LC_ALL=C sort) > "$w/on-disk"
	awk '{ print substr($0, 67) }' "$cache/SHA256SUMS" | LC_ALL=C sort > "$w/listed"
	: > "$w/bad"
	# Not listed, or listed and missing.
	LC_ALL=C comm -23 "$w/on-disk" "$w/listed" | while IFS= read -r p; do top "$p"; done >> "$w/bad"
	LC_ALL=C comm -13 "$w/on-disk" "$w/listed" | while IFS= read -r p; do top "$p"; done >> "$w/bad"
	# Listed, present, and not matching.
	(cd "$cache" && sha256sum -c SHA256SUMS 2> /dev/null || true) | sed -n 's/: FAILED.*$//p' \
		| while IFS= read -r p; do top "$p"; done >> "$w/bad"
	LC_ALL=C sort -u "$w/bad" -o "$w/bad"
	(cd "$cache" && find . -mindepth 1 -maxdepth 1 ! -name SHA256SUMS -print | sed 's#^\./##' | LC_ALL=C sort) > "$w/entries"
	while IFS= read -r entry; do
		if grep -qxF -- "$entry" "$w/bad"; then
			echo "downloads-cache: $entry does not match the manifest; it is downloaded again"
			echo dropped >> "$w/count"
		else
			cp -a "$cache/$entry" "$out/"
			echo used >> "$w/count"
		fi
	done < "$w/entries"
	used="$(grep -cx used "$w/count" 2> /dev/null || true)"
	dropped="$(grep -cx dropped "$w/count" 2> /dev/null || true)"
	rm -rf "$w"
	echo "downloads-cache: ${used:-0} entr(y/ies) of the restored cache checked and used, ${dropped:-0} left out"
}

no_token() {
	[ -d "$1" ] || die "no directory '$1'"
	[ -n "${TOKEN:-}" ] || die "TOKEN is not set"
	found="$(grep -rlF -- "$TOKEN" "$1" || true)"
	if [ -n "$found" ]; then
		echo "downloads-cache: these files hold the token and the cache is not saved:" >&2
		printf '%s\n' "$found" >&2
		exit 1
	fi
	echo "downloads-cache: no file holds the token"
}

case "${1:-}" in
	manifest) [ "$#" -eq 2 ] || die "usage: manifest DIR"; manifest "$2" ;;
	seed) [ "$#" -eq 5 ] || die "usage: seed CACHE SEED REF REPO"; seed "$2" "$3" "$4" "$5" ;;
	no-token) [ "$#" -eq 2 ] || die "usage: no-token DIR"; no_token "$2" ;;
	*) die "usage: downloads-cache.sh manifest DIR | seed CACHE SEED REF REPO | no-token DIR" ;;
esac
