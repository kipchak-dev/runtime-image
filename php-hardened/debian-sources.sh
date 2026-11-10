#!/bin/sh
# The exact Debian source packages of every package in the build image, for the source set (see NOTICE.md).
# Runs in the build image, as root. Fails if any source package cannot be fetched at its exact version.
set -eu
out="${1:?usage: debian-sources.sh DIR}"
mkdir -p "${out}"

dpkg-query -W -f '${source:Package} ${source:Version}\n' | sort -u > "${out}/SOURCES.txt"
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update -qq

cd "${out}"
missing=0
while read -r package version; do
	apt-get source --download-only -qq "${package}=${version}" > /dev/null 2>&1 \
		|| { echo "Debian source package not found: ${package} ${version}" >&2; missing=$((missing + 1)); }
done < SOURCES.txt
[ "${missing}" = 0 ] || exit 1

rm -rf /var/lib/apt/lists/*
echo "Debian sources: $(wc -l < SOURCES.txt) source packages, $(du -sh . | cut -f1)"
