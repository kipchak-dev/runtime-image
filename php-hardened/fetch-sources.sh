#!/bin/sh
# Fetches one build's source set from Mamluk's mirror into a directory, and checks every file against the set's own
# SHA256SUMS, for a rebuild that needs nothing else (see NOTICE.md and "Rebuilding from the source set" in README.md).
#
#   fetch-sources.sh SET DIR      e.g. fetch-sources.sh 8.5.12-20261110T1730-arm64 ./set
#
# SET is the image's `org.kipchak.sources` label. Needs oras (https://oras.land); the mirror needs no login.
set -eu
set_name="${1:?usage: fetch-sources.sh SET DIR}"
dir="${2:?usage: fetch-sources.sh SET DIR}"
mirror="${KIPCHAK_SOURCES_MIRROR:-1x.ax/mamluk/kipchak-sources}"

mkdir -p "${dir}"
oras pull --output "${dir}" "${mirror}/sets:${set_name}"
cd "${dir}"
tar -xf small-files.tar && rm small-files.tar
check="$(mktemp)"
sha256sum -c SHA256SUMS > "${check}" 2>&1 || { grep -v ': OK$' "${check}" >&2; rm -f "${check}"; exit 1; }
rm -f "${check}"
echo "Fetched and checked: $(wc -l < SHA256SUMS) files. The images it was built with are in IMAGES.txt."
