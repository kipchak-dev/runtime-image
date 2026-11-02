#!/bin/bash
#
# Builds a fully static FrankenPHP binary (musl, mimalloc) and a matching static PHP CLI with static-php-cli v3.
#
# Runs inside dunglas/frankenphp:static-builder-musl, whose /go/src/app holds the FrankenPHP source at its release
# and which sets FRANKENPHP_VERSION. This follows FrankenPHP's own build-static.sh and craft.yml, with these
# differences:
#
#  - static-php-cli is pinned to a commit (SPC_COMMIT) and run from source, instead of its nightly binary;
#  - libraries are compiled here from source wherever static-php-cli has a source recipe (prefer-source);
#  - Mercure and Vulcain are left out of Caddy, so the server carries only the modules an API needs;
#  - a standalone php CLI is built alongside. `frankenphp php-cli` cannot replace it before PHP 8.6: it puts its
#    own path in $argv[0], so Composer and console scripts misread their arguments.

set -euo pipefail

: "${PHP_VERSION:?PHP_VERSION is required, e.g. 8.5.12}"
: "${PHP_EXTENSIONS:?PHP_EXTENSIONS is required}"
: "${PHP_EXTENSION_LIBS:?PHP_EXTENSION_LIBS is required}"
: "${SPC_COMMIT:?SPC_COMMIT is required}"
: "${FRANKENPHP_VERSION:?FRANKENPHP_VERSION is set by the builder image}"

FRANKENPHP_SOURCE_PATH=/go/src/app
# Older builder images set v1.13.0; the binary adds its own "v".
export FRANKENPHP_VERSION="${FRANKENPHP_VERSION#v}"

# Brotli is required by caddy-cbrotli. mimalloc replaces musl's allocator, which is slow under ZTS (MIMALLOC=1).
PHP_EXTENSION_LIBS="${PHP_EXTENSION_LIBS},brotli"
if [ "${MIMALLOC:-1}" = "1" ]; then
	PHP_EXTENSION_LIBS="${PHP_EXTENSION_LIBS},mimalloc"
fi

# A fully static musl binary, built with static-php-cli's zig toolchain. The target is resolved when spc starts,
# before craft.yml is read, so it has to be in the environment. It names the architecture rather than "native":
# for a native target, zig compiles for the build machine's CPU, and the arm64 build runs under QEMU, whose CPU
# has features that real arm64 machines such as Apple silicon lack, so php and frankenphp died with SIGILL there.
# A named architecture compiles for its baseline, as static-php-cli does by default.
unset SPC_LIBC
export SPC_TARGET="$(uname -m)-linux-musl"
# zig opens many file descriptors when a lot of extensions are linked statically.
ulimit -n 8192 2> /dev/null || true

if [ -f /run/secrets/github_token ]; then
	GITHUB_TOKEN="$(cat /run/secrets/github_token)"
	export GITHUB_TOKEN
fi

mkdir -p "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"
cd "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"
# Start from a clean checkout and build root; only the downloaded sources are kept, in the cache mount.
find . -mindepth 1 -maxdepth 1 ! -name downloads -exec rm -rf {} +
git init --quiet
git fetch --quiet --depth 1 https://github.com/crazywhalecc/static-php-cli "${SPC_COMMIT}"
git checkout --quiet FETCH_HEAD
composer install --no-dev --classmap-authoritative --no-interaction --quiet

# GNU sources from ftpmirror.gnu.org, which redirects to a nearby mirror, as GNU recommends: ftp.gnu.org itself is
# often unavailable, and static-php-cli then waits two minutes per attempt before trying its mirror.
grep -rlZ 'https://ftp.gnu.org/' config | xargs -0 -r sed -i \
	's#https://ftp.gnu.org/pub/gnu/#https://ftpmirror.gnu.org/gnu/#g; s#https://ftp.gnu.org/gnu/#https://ftpmirror.gnu.org/gnu/#g'

# What to build. PHP_VERSION is the exact release, so static-php-cli downloads that tarball from php.net and checks
# it against php.net's SHA-256. The FrankenPHP source is the builder image's, not the latest GitHub release.
cat > craft.yml <<EOF
php-version: "${PHP_VERSION}"
extensions: "${PHP_EXTENSIONS}"
packages: "${PHP_EXTENSION_LIBS}"
sapi: "cli,frankenphp"
clean-build: false

build-options:
  enable-zts: true
  disable-opcache-jit: true
  with-config-file-path: "/etc/frankenphp"
  with-config-file-scan-dir: "/etc/frankenphp/php.d"
  no-strip: false
  with-upx-pack: false
  with-suggests: false

download-options:
  parallel: 4
  retry: 5
  prefer-source: true
  custom-local: ["frankenphp:${FRANKENPHP_SOURCE_PATH}"]

extra-env:
  SPC_CMD_VAR_FRANKENPHP_XCADDY_MODULES: "--with github.com/dunglas/caddy-cbrotli"
  # static-php-cli's default C++ flags for PHP end with an empty SPC_DEFAULT_CXXFLAGS, so ext/intl's C++ was compiled
  # without -O, which zig's clang treats as a debug build with UBSan, and the php CLI then failed to link
  # (undefined __ubsan_handle_*). The same flags as for C.
  SPC_CMD_VAR_PHP_MAKE_EXTRA_CXXFLAGS: "-g -fstack-protector-strong -fno-ident -fPIE -fvisibility=hidden -fvisibility-inlines-hidden -fPIC -O3 -pipe -fno-plt -fno-semantic-interposition -fstack-clash-protection -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -ffunction-sections -fdata-sections -Wno-unused-command-line-argument -fno-sanitize=undefined"
  # relro and now make the relocated data of the SAPI executables read-only.
  SPC_CMD_VAR_PHP_MAKE_EXTRA_LDFLAGS_PROGRAM: "-Wl,-z,relro -Wl,-z,now"

craft-options:
  doctor: true
  download: true
EOF

if ! ./bin/spc craft craft.yml; then
	# The build log stays inside the failed build step, so show where it went wrong.
	grep -h -n -i -E 'error|undefined reference' log/*.log 2> /dev/null \
		| grep -v -i -E 'Werror|-error|error\.(c|o|h|lo)' | tail -n 40 || true
	tail -n 60 log/spc.shell.log 2> /dev/null || true
	exit 1
fi

mkdir -p /out
cp buildroot/bin/frankenphp buildroot/bin/php /out/
/out/frankenphp build-info > /out/build-info.txt
# Both binaries must be the FrankenPHP and PHP releases asked for, e.g. "FrankenPHP v1.13.2 PHP 8.5.12 Caddy ...".
version="$(/out/frankenphp version)"
echo "${version}"
php="$(/out/php -n -r 'echo PHP_VERSION;')"
case "${version}" in
	*"FrankenPHP v${FRANKENPHP_VERSION} PHP ${PHP_VERSION} "*) [ "${php}" = "${PHP_VERSION}" ] ;;
	*) false ;;
esac || { echo "Expected FrankenPHP ${FRANKENPHP_VERSION} and PHP ${PHP_VERSION}, built php ${php}" >&2; exit 1; }
# ICU (intl) crashed on first use when the php CLI was linked with thread-local storage relocations left for run
# time, which musl never applies in a static binary. Use it here, so that such a binary fails the build.
/out/php -n -r 'echo (new NumberFormatter("en", NumberFormatter::DECIMAL))->format(1234.5), PHP_EOL;'
# Every extension with its version, and every source compiled in, so each image records exactly what it contains
# (most library filenames include the version). The build log shows both.
/out/php -n -r 'foreach (get_loaded_extensions() as $e) { echo $e, " ", phpversion($e) ?: "", PHP_EOL; }' \
	| sort -f > /out/extensions.txt
cp downloads/.cache.json /out/sources.lock.json
jq -r 'to_entries[] | select(.value.source != null)
	| "\(.key) \(.value.source.filename // .value.source.dirname // .value.source.cache_type)"' \
	/out/sources.lock.json | sort > /out/sources.txt
echo "--- Extensions"
cat /out/extensions.txt
echo "--- Sources"
cat /out/sources.txt
