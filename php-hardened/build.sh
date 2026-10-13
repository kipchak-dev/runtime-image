#!/bin/bash
#
# Builds and pushes the hardened runtime and build images for PHP 8.4 and 8.5, for linux/amd64 and linux/arm64.
# Concourse does the same in pipelines/mamluk/kipchak-runtime.yml; this script is for building by hand.
#
#   ./build.sh             build and push everything
#   ./build.sh 8.5         one PHP version
#   PUSH=0 ./build.sh 8.5  build without pushing
#
# Each PHP version is built at its latest release, looked up on php.net. Images, for PHP 8.5.11:
#   1x.ax/mamluk/enterprise/php/8.5:franken        and :franken-8.5.11        the runtime
#   1x.ax/mamluk/enterprise/php/8.5:franken-build  and :franken-build-8.5.11  the build image
#
# Libraries are refreshed to their latest releases once a week: SOURCES_EPOCH defaults to the ISO week. Set it to
# anything else to force a refresh.
#
# Each architecture compiles PHP and its libraries from source, which takes a long time under emulation. To build
# each architecture natively, add a machine of the other architecture to the builder:
#
#   docker buildx create --name kipchak-runtime --append ssh://user@amd64-host

set -euo pipefail
cd "$(dirname "$0")"

REGISTRY="${REGISTRY:-1x.ax/mamluk/enterprise/php}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER="${BUILDER:-kipchak-runtime}"
PUSH="${PUSH:-1}"
SOURCES_EPOCH="${SOURCES_EPOCH:-$(date -u +%G-W%V)}"

versions=("$@")
if [ ${#versions[@]} -eq 0 ]; then
	versions=(8.4 8.5)
fi

# Multi-platform images need a builder with the docker-container driver.
if ! docker buildx inspect "${BUILDER}" > /dev/null 2>&1; then
	docker buildx create --name "${BUILDER}" --driver docker-container --platform "${PLATFORMS}"
fi

# static-php-cli downloads most library sources from GitHub, which allows 60 API requests an hour without a token,
# fewer than one build makes. Composer's GitHub token is used when GITHUB_TOKEN is not set.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "${HOME}/.composer/auth.json" ] && command -v jq > /dev/null; then
	GITHUB_TOKEN="$(jq -r '."github-oauth"."github.com" // empty' "${HOME}/.composer/auth.json")"
	export GITHUB_TOKEN
fi

secrets=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
	secrets=(--secret id=github_token,env=GITHUB_TOKEN)
fi

output=(--push --sbom=true --provenance=mode=max)
if [ "${PUSH}" != "1" ]; then
	output=()
fi

for minor in "${versions[@]}"; do
	php="$(curl -fsSL "https://www.php.net/releases/index.php?json&version=${minor}" | jq -r '.version // empty')"
	case "${php}" in
		"${minor}".*) echo "PHP ${minor}: building ${php}, sources ${SOURCES_EPOCH}" ;;
		*) echo "Could not find the latest PHP ${minor} release on php.net" >&2; exit 1 ;;
	esac

	for target in runtime build; do
		tag="franken"
		[ "${target}" = "build" ] && tag="franken-build"

		docker buildx build \
			--builder "${BUILDER}" \
			--platform "${PLATFORMS}" \
			--target "${target}" \
			--build-arg PHP_VERSION="${php}" \
			--build-arg SOURCES_EPOCH="${SOURCES_EPOCH}" \
			${secrets[@]+"${secrets[@]}"} \
			--tag "${REGISTRY}/${minor}:${tag}" \
			--tag "${REGISTRY}/${minor}:${tag}-${php}" \
			${output[@]+"${output[@]}"} \
			.
	done
done
