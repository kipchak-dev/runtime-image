#!/bin/sh
# The exact Alpine sources of every package in the alpine image, for the source set (see NOTICE.md): for each origin,
# its aports directory at the commit whose APKBUILD has the installed version, and the source files that names.
# Runs in the alpine image, as root. Fails if any installed version has no matching aports commit, or a source file
# cannot be fetched.
set -eu
out="${1:?usage: alpine-sources.sh DIR}"
mkdir -p "${out}/aports" "${out}/distfiles"

# origin version, for every installed package (apk v3).
apk query --fields origin,version --installed '*' \
	| awk '/^Origin: / { o = $2 } /^Version: / { v = $2 } /^$/ { if (o != "") print o, v; o = ""; v = "" } END { if (o != "") print o, v }' \
	| sort -u > "${out}/ORIGINS.txt"

apk add --no-cache -q abuild git > /dev/null
branch="$(cut -d. -f1,2 /etc/alpine-release)-stable"
# Alpine keeps a copy of every source file its packages are built from. abuild tries it first and the upstream URL only
# if it lacks a file, so an upstream that is down (dev.gentoo.org, for pax-utils, on 11 November) does not fail the
# set. abuild checks every file against the APKBUILD's sha512sums wherever it came from.
export DISTFILES_MIRROR="https://distfiles.alpinelinux.org/distfiles/v$(cut -d. -f1,2 /etc/alpine-release)"
git clone -q --filter=blob:none --no-checkout -b "${branch}" https://gitlab.alpinelinux.org/alpine/aports.git /tmp/aports
cd /tmp/aports

: > "${out}/COMMITS.txt"
failed=0
while read -r origin version; do
	dir=""
	for repo in main community; do
		if [ -n "$(git ls-tree -d HEAD "${repo}/${origin}")" ]; then dir="${repo}/${origin}"; fi
	done
	[ -n "${dir}" ] || { echo "No aports directory for ${origin}" >&2; failed=$((failed + 1)); continue; }
	# The newest commit whose APKBUILD gives exactly the installed pkgver-rpkgrel.
	commit=""
	for c in $(git log --format=%H -- "${dir}/APKBUILD"); do
		apkbuild="$(git show "${c}:${dir}/APKBUILD")"
		ver="$(printf '%s\n' "${apkbuild}" | sed -n 's/^pkgver=//p' | head -1)"
		rel="$(printf '%s\n' "${apkbuild}" | sed -n 's/^pkgrel=//p' | head -1)"
		if [ "${ver}-r${rel}" = "${version}" ]; then commit="${c}"; break; fi
	done
	[ -n "${commit}" ] || { echo "No aports commit for ${origin} ${version}" >&2; failed=$((failed + 1)); continue; }
	echo "${origin} ${version} ${commit}" >> "${out}/COMMITS.txt"
	mkdir -p "${out}/aports/${origin}"
	git archive "${commit}" "${dir}" | tar -x --strip-components=2 -C "${out}/aports/${origin}"
	(cd "${out}/aports/${origin}" && SRCDEST="${out}/distfiles" abuild -F fetch > /dev/null 2>&1) \
		|| { echo "Source files not fetched for ${origin} ${version}" >&2; failed=$((failed + 1)); }
done < "${out}/ORIGINS.txt"
[ "${failed}" = 0 ] || exit 1

apk del -q abuild git > /dev/null
rm -rf /tmp/aports
echo "Alpine sources: $(wc -l < "${out}/COMMITS.txt") origins, $(du -sh "${out}" | cut -f1)"
