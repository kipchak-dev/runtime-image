#!/bin/sh
# The licences of the Alpine packages in this image. PACKAGES.txt lists what is installed and its licence. Each package's
# own licence files, with their copyright notices, come from its source archive on Alpine's distfiles mirror. A package
# with no licence file is handled below, with the reason, and gets the standard text of the licence it names.
# LICENCE-SOURCES.txt says which is which. An unknown package, or a package with no text, fails the build.
set -eu

target="$1"
mirror="https://distfiles.alpinelinux.org/distfiles/v$(cut -d. -f1,2 /etc/alpine-release)"
mkdir -p "${target}"
apk list --installed 2> /dev/null | sort > "${target}/PACKAGES.txt"
[ -s "${target}/PACKAGES.txt" ] || { echo 'No Alpine packages are listed.' >&2; exit 1; }
record="${target}/LICENCE-SOURCES.txt"
: > "${record}"

apk add --no-cache --quiet --virtual .licence-texts spdx-licenses-text tar xz bzip2
missing=0
work="$(mktemp -d)"

standard_texts() {
	for identifier in $(printf '%s' "$2" | tr ' ()' '\n\n\n' | grep -vE '^(AND|OR|WITH|)$'); do
		if [ -s "/usr/share/spdx/text/${identifier}.txt" ]; then
			cp "/usr/share/spdx/text/${identifier}.txt" "${target}/${identifier}.txt"
		else
			echo "No licence text for ${identifier} ($1)" >&2
			missing=1
		fi
	done
}

# Each line reads "musl-1.2.6-r3 aarch64 {musl} (MIT) [installed]". One line per source package: origin, version, licence.
sed -E 's/^(.*)-([^-]+)-r[0-9]+ [^ ]+ \{(.*)\} \((.*)\) \[installed\]$/\3|\2|\4/' "${target}/PACKAGES.txt" | sort -t'|' -k1,1 -u > "${work}/origins"
while IFS='|' read -r origin version licence; do
	case "${origin}" in
		alpine-base | alpine-baselayout | alpine-keys)
			# These are Alpine's own files, kept in aports, which has no source archive and no licence file for them.
			standard_texts "${origin}" "${licence}"
			echo "${origin} ${version} standard-text ${licence}: Alpine's own package, its source in aports has no licence file" >> "${record}"
			continue
			;;
		apk-tools) archive="apk-tools-v${version}.tar.gz" ;;
		busybox) archive="busybox-${version}.tar.bz2" ;;
		ca-certificates) archive="ca-certificates-${version}.tar.bz2" ;;
		musl) archive="musl-${version}.tar.gz" ;;
		openssl) archive="openssl-${version}.tar.gz" ;;
		pax-utils) archive="pax-utils-${version}.tar.xz" ;;
		zlib) archive="zlib-${version}.tar.gz" ;;
		*)
			echo "Package ${origin} is not known here: add where its source archive is, in alpine-licences.sh." >&2
			missing=1
			continue
			;;
	esac
	if ! wget -q -O "${work}/${archive}" "${mirror}/${archive}"; then
		echo "Could not download ${mirror}/${archive}" >&2
		missing=1
		continue
	fi
	mkdir -p "${work}/${origin}" "${target}/${origin}"
	tar -xf "${work}/${archive}" -C "${work}/${origin}" --strip-components=1
	find "${work}/${origin}" -maxdepth 1 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) \
		-exec cp {} "${target}/${origin}/" \;
	if [ "${origin}" = ca-certificates ]; then
		# Its source has no licence file: the notices are in the headers of the files, which are kept here.
		{
			sed -n '1,4p' "${work}/${origin}/certdata.txt"
			sed -n '1,/\*\//p' "${work}/${origin}/c_rehash.c"
		} > "${target}/${origin}/NOTICES.txt"
		grep -qi 'copyright' "${target}/${origin}/NOTICES.txt" || { echo "No copyright notice found in ${archive}" >&2; missing=1; }
		standard_texts "${origin}" "${licence}"
		echo "${origin} ${version} standard-text ${licence}: its source has no licence file, notices from file headers are in ${origin}/NOTICES.txt" >> "${record}"
	elif [ -z "$(ls -A "${target}/${origin}")" ]; then
		echo "No licence file in ${archive}" >&2
		missing=1
	else
		echo "${origin} ${version} original" >> "${record}"
	fi
	rm -rf "${work:?}/${origin}" "${work:?}/${archive}"
done < "${work}/origins"

rm -rf "${work}"
apk del --no-cache --quiet .licence-texts
echo "Alpine licence texts: $(grep -c ' original$' "${record}" || true) original, $(grep -c ' standard-text ' "${record}" || true) standard"
exit "${missing}"
