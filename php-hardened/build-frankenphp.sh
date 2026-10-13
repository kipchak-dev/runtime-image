#!/bin/bash
#
# Builds a fully static FrankenPHP binary (musl, mimalloc) and a matching static PHP CLI with static-php-cli.
#
# Runs inside dunglas/frankenphp:static-builder-musl-<version>, whose /go/src/app holds the FrankenPHP source at
# that version and the toolchain. This follows FrankenPHP's own build-static.sh, with four differences:
#
#  - static-php-cli is pinned to a commit (SPC_COMMIT) instead of tracking its nightly build;
#  - every library is compiled here from source, never downloaded pre-built;
#  - Mercure and Vulcain are left out of Caddy, so the server carries only the modules an API needs;
#  - a standalone php CLI is built alongside, for Composer and CI in the build image.

set -euo pipefail

: "${PHP_VERSION:?PHP_VERSION is required, e.g. 8.5.11}"
: "${PHP_EXTENSIONS:?PHP_EXTENSIONS is required}"
: "${PHP_EXTENSION_LIBS:?PHP_EXTENSION_LIBS is required}"
: "${SPC_COMMIT:?SPC_COMMIT is required}"

FRANKENPHP_SOURCE_PATH=/go/src/app
export FRANKENPHP_SOURCE_PATH
# The builder image sets v1.13.0; the binary adds its own "v".
export FRANKENPHP_VERSION="${FRANKENPHP_VERSION#v}"

# Brotli is required by caddy-cbrotli. mimalloc replaces musl's allocator, which is slow under ZTS (MIMALLOC=1).
PHP_EXTENSION_LIBS="${PHP_EXTENSION_LIBS},brotli"
if [ "${MIMALLOC:-1}" = "1" ]; then
	PHP_EXTENSION_LIBS="${PHP_EXTENSION_LIBS},mimalloc"
fi

export SPC_LIBC=musl
export SPC_DEFAULT_C_FLAGS="-fPIC -O2"
export SPC_CMD_VAR_PHP_MAKE_EXTRA_CFLAGS="-fPIE -fstack-protector-strong -O2 -w -s"
export SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS_PROGRAM="-Wl,-O1 -Wl,-z,relro -Wl,-z,now -pie"
export SPC_CMD_VAR_FRANKENPHP_XCADDY_MODULES="--with github.com/dunglas/caddy-cbrotli"
CGO_CFLAGS="${CGO_CFLAGS:-} $(sh "${FRANKENPHP_SOURCE_PATH}/mtls-cflags.sh")"
export CGO_CFLAGS

if [ -f /run/secrets/github_token ]; then
	GITHUB_TOKEN="$(cat /run/secrets/github_token)"
	export GITHUB_TOKEN
fi

mkdir -p "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"
cd "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"
# The builder image ships the libraries and binary from FrankenPHP's own release build, compiled with other
# options. Remove everything except the downloaded sources, so that all of it is compiled here.
find . -mindepth 1 -maxdepth 1 ! -name downloads -exec rm -rf {} +
rm -f ../frankenphp-linux-*
git init --quiet
git fetch --quiet --depth 1 https://github.com/crazywhalecc/static-php-cli "${SPC_COMMIT}"
git checkout --quiet FETCH_HEAD
composer install --no-dev --classmap-authoritative --no-interaction --quiet

spc=./bin/spc
${spc} doctor --auto-fix
${spc} install-pkg go-xcaddy
${spc} download --with-php="${PHP_VERSION}" --for-extensions="${PHP_EXTENSIONS}" --for-libs="${PHP_EXTENSION_LIBS}" \
	--ignore-cache-sources=php-src --retry 5
if ! ${spc} build --enable-zts --build-embed --build-frankenphp --build-cli --disable-opcache-jit \
	--with-config-file-path=/etc/frankenphp --with-config-file-scan-dir=/etc/frankenphp/php.d \
	"${PHP_EXTENSIONS}" --with-libs="${PHP_EXTENSION_LIBS}"; then
	# The build log stays inside the failed build step, so show where it went wrong.
	grep -n -i -E 'error|undefined reference' log/spc.shell.log | grep -v -i -E 'Werror|-error|error\.(c|o|h|lo)' | tail -n 40 || true
	tail -n 60 log/spc.shell.log
	exit 1
fi

mkdir -p /out
cp buildroot/bin/frankenphp buildroot/bin/php /out/
/out/frankenphp version
/out/frankenphp build-info > /out/build-info.txt
# Every extension with its version, and every source compiled in, so each image records exactly what it contains
# (most library filenames include the version). The build log shows both.
/out/php -n -r 'foreach (get_loaded_extensions() as $e) { echo $e, " ", phpversion($e) ?: "", PHP_EOL; }' \
	| sort -f > /out/extensions.txt
cp downloads/.lock.json /out/sources.lock.json
jq -r 'to_entries[] | select(.value.lock_as != 3) | "\(.key) \(.value.filename // .value.dirname // "")"' \
	/out/sources.lock.json | sort > /out/sources.txt
echo "--- Extensions"
cat /out/extensions.txt
echo "--- Sources"
cat /out/sources.txt
