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

# This build's settings, as given, for the Dockerfile's set-check stage, which checks the set with the same ones. No
# image copies this file.
mkdir -p /out
printf '%s\n' "PHP_VERSION=${PHP_VERSION}" "PHP_EXTENSIONS=${PHP_EXTENSIONS}" "PHP_EXTENSION_LIBS=${PHP_EXTENSION_LIBS}" \
	"SPC_COMMIT=${SPC_COMMIT}" "MIMALLOC=${MIMALLOC:-1}" "SQLITE_VERSION=${SQLITE_VERSION:-}" "SQLITE_ARCHIVE=${SQLITE_ARCHIVE:-}" \
	"SQLITE_SHA3=${SQLITE_SHA3:-}" "STEP_CRYPTO_VERSION=${STEP_CRYPTO_VERSION:-}" \
	"STEP_CERTIFICATES_VERSION=${STEP_CERTIFICATES_VERSION:-}" "XCADDY_VERSION=${XCADDY_VERSION:-}" > /out/build.env

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

# THE SOURCE SET. Every build writes to /out-set everything it fetched, at the versions it built: static-php-cli as
# fetched, the source and toolchain archives, and the Go modules. The pipeline keeps each published build's set on
# 1x.ax, so the binaries can be rebuilt, with a modified library if wanted, without any upstream (see NOTICE.md).
# With a set mounted at /sources (the `sources` build context, see the README), the build takes everything from it
# instead, and is run with --network=none, so that nothing can come from anywhere else.
SOURCES=/sources
SET=/out-set
from_set() { [ -f "${SOURCES}/static-php-cli.tar.gz" ]; }
mkdir -p "${SET}"
# Archives written the same way every time, so the same contents give the same bytes and are stored once.
pack() { tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner "$@" -cf - . | gzip -n; }

mkdir -p "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"
cd "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"
# Start from a clean checkout and build root; only the downloaded sources are kept, in the cache mount.
find . -mindepth 1 -maxdepth 1 ! -name downloads -exec rm -rf {} +
if from_set; then
	tar -xzf "${SOURCES}/static-php-cli.tar.gz"
	[ "$(git rev-parse HEAD)" = "${SPC_COMMIT}" ] \
		|| { echo "The set's static-php-cli is not at SPC_COMMIT ${SPC_COMMIT}." >&2; exit 1; }
	# The set's downloads, with static-php-cli's record of them, so that its download step finds every one in place.
	cp -a "${SOURCES}/downloads/." downloads/
	# The Go modules from the set alone. go.sum still checks every one of them.
	export GOPROXY="file://${SOURCES}/gomod" GOSUMDB=off GOFLAGS=-mod=mod GOTOOLCHAIN=local
else
	git init --quiet
	git fetch --quiet --depth 1 https://github.com/crazywhalecc/static-php-cli "${SPC_COMMIT}"
	git checkout --quiet FETCH_HEAD
	composer install --no-dev --classmap-authoritative --no-interaction --quiet
fi
# static-php-cli as fetched, with its Composer packages, before the overrides below: a rebuild replays them.
pack --exclude=./downloads > "${SET}/static-php-cli.tar.gz"

# GNU sources from ftpmirror.gnu.org, which redirects to a nearby mirror, as GNU recommends: ftp.gnu.org itself is
# often unavailable, and static-php-cli then waits two minutes per attempt before trying its mirror.
grep -rlZ 'https://ftp.gnu.org/' config | xargs -0 -r sed -i \
	's#https://ftp.gnu.org/pub/gnu/#https://ftpmirror.gnu.org/gnu/#g; s#https://ftp.gnu.org/gnu/#https://ftpmirror.gnu.org/gnu/#g'

# The SQLite recipe names a fixed 2024 release: see the Dockerfile. Failing here if the recipe has moved, rather than
# quietly building whatever it now names.
: "${SQLITE_VERSION:?SQLITE_VERSION is required}" "${SQLITE_ARCHIVE:?SQLITE_ARCHIVE is required}" "${SQLITE_SHA3:?SQLITE_SHA3 is required}"
grep -q 'https://www.sqlite.org/2024/sqlite-autoconf-3450200.tar.gz' config/pkg/lib/sqlite.yml \
	|| { echo 'static-php-cli changed its SQLite recipe: review the override in build-frankenphp.sh' >&2; exit 1; }
sed -i "s#https://www.sqlite.org/2024/sqlite-autoconf-3450200.tar.gz#https://www.sqlite.org/${SQLITE_ARCHIVE}#" config/pkg/lib/sqlite.yml
# SQLite's current configure (autosetup) rejects options it does not know, and static-php-cli passes --with-pic to every
# library.
# Position-independent code still has to reach the static binary, so it goes in through the flags. So does dbstat, which
# breaks a database down by table and index, and which after-compile.sh checks with a real query.
grep -q "'CFLAGS' => '-DSQLITE_ENABLE_COLUMN_METADATA=1'," src/Package/Library/sqlite.php && grep -q -- '->configure()' src/Package/Library/sqlite.php \
	|| { echo 'static-php-cli changed its SQLite build: review the override in build-frankenphp.sh' >&2; exit 1; }
sed -i -e "s/'CFLAGS' => '-DSQLITE_ENABLE_COLUMN_METADATA=1',/'CFLAGS' => '-DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 -fPIC',/" \
	-e "s/->configure()/->removeConfigureArgs('--with-pic', '--enable-pic')->configure()/" src/Package/Library/sqlite.php

# ICU renamed its source archive at 78 (icu4c-78.3-sources.tgz), and the recipe still looks for -src.tgz, so it finds
# nothing newer than 77.1 and reports that as the latest. check-sources.php now catches this kind of thing.
grep -qF 'match: icu4c.+-src\.tgz' config/pkg/lib/icu.yml \
	|| { echo 'static-php-cli changed its ICU recipe: review the override in build-frankenphp.sh' >&2; exit 1; }
sed -i 's/match: icu4c\.+-src\\\.tgz/match: icu4c.+-sources\\.tgz/' config/pkg/lib/icu.yml
grep -qF 'match: icu4c.+-sources\.tgz' config/pkg/lib/icu.yml \
	|| { echo 'The ICU override did not apply.' >&2; exit 1; }

# static-php-cli installs xcaddy from its master branch whenever the Go it downloads differs from the builder image's.
# A source set cannot answer @master offline, and @master moves, so xcaddy is pinned (XCADDY_VERSION, in the Dockerfile).
: "${XCADDY_VERSION:?XCADDY_VERSION is required}"
grep -qF 'xcaddy/cmd/xcaddy@master' src/Package/Artifact/go_xcaddy.php \
	|| { echo 'static-php-cli changed how it installs xcaddy: review the override in build-frankenphp.sh' >&2; exit 1; }
sed -i "s#xcaddy/cmd/xcaddy@master#xcaddy/cmd/xcaddy@${XCADDY_VERSION}#" src/Package/Artifact/go_xcaddy.php
grep -qF "xcaddy/cmd/xcaddy@${XCADDY_VERSION}" src/Package/Artifact/go_xcaddy.php \
	|| { echo 'The xcaddy override did not apply.' >&2; exit 1; }

# Off go-jose/v3 (see the Dockerfile). xcaddy builds the FrankenPHP module from this directory, and Go takes the highest
# version any module requires, so requiring these here is what reaches the binary.
: "${STEP_CRYPTO_VERSION:?STEP_CRYPTO_VERSION is required}" "${STEP_CERTIFICATES_VERSION:?STEP_CERTIFICATES_VERSION is required}"
mkdir -p /out
if ! grep -q 'github.com/go-jose/go-jose/v3 ' "${FRANKENPHP_SOURCE_PATH}/caddy/go.mod"; then
	# The sources report carries this, and the pipeline's guard alerts on it.
	echo 'NOTICE: FrankenPHP no longer needs go-jose/v3 by itself: remove the pins in the Dockerfile.'
	touch /out/go-pins-unnecessary
fi
(
	cd "${FRANKENPHP_SOURCE_PATH}/caddy"
	/opt/spc-pkgroot/go-xcaddy/bin/go get "go.step.sm/crypto@${STEP_CRYPTO_VERSION}" "github.com/smallstep/certificates@${STEP_CERTIFICATES_VERSION}"
	/opt/spc-pkgroot/go-xcaddy/bin/go mod tidy
)

# The guard's own tests: it must fail when it should, before hours of compiling rest on it.
php /usr/local/bin/tests/check-sources-test.php > /dev/null

# What to build. PHP_VERSION is the exact release, so static-php-cli downloads that tarball from php.net and checks
# it against php.net's SHA-256. The FrankenPHP source is the builder image's, not the latest GitHub release.
# From a set, the php-version line is left out: with it, craft always fetches PHP again from php.net (ignore-cache:
# php-src), and the set's tarball is the one to build. The version check after the build still requires PHP_VERSION.
php_version_line="php-version: \"${PHP_VERSION}\""
from_set && php_version_line="# php-version: the set's php-src (${PHP_VERSION})"
cat > craft.yml <<EOF
${php_version_line}
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

# SET_CHECK=1 (the set-check stage of the Dockerfile, run with no network) proves the set can rebuild: everything the
# build would download comes from it, and so do Go, xcaddy and every Go module the binary is built from. It stops there,
# without compiling, so a set that would fail a customer's rebuild fails the pipeline before its images are published.
if [ "${SET_CHECK:-0}" = 1 ]; then
	from_set || { echo 'SET_CHECK needs a source set at /sources' >&2; exit 1; }
	echo '  build: false' >> craft.yml # craft-options is the last block: check and download, but do not build
	./bin/spc craft craft.yml
	./bin/spc install-pkg go-xcaddy
	go=/opt/spc-pkgroot/go-xcaddy/bin/go
	export PATH="/opt/spc-pkgroot/go-xcaddy/bin:${PATH}" GOPATH=/opt/spc-pkgroot/go-xcaddy/go
	# xcaddy writes the module FrankenPHP is built as, and resolves it, then stops before compiling.
	# Its build environment goes in a directory of its own (xcaddy uses TMPDIR), so it is the only buildenv_ there.
	work="$(mktemp -d)"
	(cd "${work}" && TMPDIR="${work}" XCADDY_SKIP_BUILD=1 XCADDY_SKIP_CLEANUP=1 xcaddy build \
		--with "github.com/dunglas/frankenphp=${FRANKENPHP_SOURCE_PATH}" \
		--with "github.com/dunglas/frankenphp/caddy=${FRANKENPHP_SOURCE_PATH}/caddy" \
		--with github.com/dunglas/caddy-cbrotli)
	module="$(ls -d "${work}"/buildenv_* 2> /dev/null | head -n 1)"
	[ -d "${module}" ] || { echo 'xcaddy left no build environment to check' >&2; exit 1; }
	# Every package the binary imports, from the set's modules alone. Nothing is compiled.
	modules="$(cd "${module}" && CGO_ENABLED=1 "${go}" list -deps -f '{{with .Module}}{{.Path}}@{{.Version}}{{end}}' . | sort -u | grep -c .)"
	echo "The source set rebuilds offline: downloads, Go, xcaddy ${XCADDY_VERSION} and the ${modules} Go modules the binary imports."
	exit 0
fi

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
# The download cache remembers whatever it has ever fetched, so an extension no longer built must not be recorded as a source.
jq --arg extensions "${PHP_EXTENSIONS}" '($extensions | split(",") | map("ext-" + .)) as $built
	| with_entries(select((.key | startswith("ext-") | not) or (.key | IN($built[]))))' downloads/.cache.json > /tmp/sources.lock.json
# The record leaves out when static-php-cli registered FrankenPHP's source directory: it has no hash or version (the
# builder image's digest fixes the content), and only the time would differ in a rebuild. The set keeps it, as
# static-php-cli's own record.
jq 'if .frankenphp.source then .frankenphp.source.time = null else . end' /tmp/sources.lock.json > /out/sources.lock.json
jq -r 'to_entries[] | select(.value.source != null)
	| "\(.key) \(.value.source.filename // .value.source.dirname // .value.source.cache_type)"' \
	/out/sources.lock.json | sort > /out/sources.txt
echo "--- Extensions"
cat /out/extensions.txt
echo "--- Sources"
cat /out/sources.txt

# The rest of the set: every download the lock names, source and this platform's binaries (zig and Go), with the lock
# as static-php-cli's record of them; and every Go module the build fetched. FrankenPHP's own source is the builder
# image's, which the set names by digest.
mkdir -p "${SET}/downloads"
platform="linux-$(uname -m)"
jq -r --arg platform "${platform}" 'to_entries[].value
	| (.source // {} | .filename // .dirname // empty),
	  (if (.binary | type) == "object" then (.binary[$platform] // {} | .filename // empty) else empty end)' \
	/out/sources.lock.json | sort -u | while read -r entry; do
	case "${entry}" in /*) continue ;; esac
	[ -e "downloads/${entry}" ] || { echo "The lock names ${entry}, which is not in the downloads." >&2; exit 1; }
	cp -a "downloads/${entry}" "${SET}/downloads/"
done
cp /tmp/sources.lock.json "${SET}/downloads/.cache.json"
# The sources of the LGPL libraries linked into both programs, which every image carries itself (NOTICE.md). libiconv's
# archive holds libcharset too.
mkdir -p /out/source-libraries
for library in gettext libiconv gmp; do
	archive="$(jq -r --arg l "${library}" '.[$l].source.filename // empty' /out/sources.lock.json)"
	[ -n "${archive}" ] && [ -f "${SET}/downloads/${archive}" ] \
		|| { echo "The source archive of ${library}, which NOTICE.md names, is missing." >&2; exit 1; }
	cp "${SET}/downloads/${archive}" /out/source-libraries/
done
go=/opt/spc-pkgroot/go-xcaddy/bin/go
# Two module caches: the go-jose pins above use Go's default GOPATH, and static-php-cli runs xcaddy with its own
# (config/pkg/tool/go-xcaddy.yml).
mkdir -p "${SET}/gomod"
for modcache in "$("${go}" env GOMODCACHE)" "$(GOPATH=/opt/spc-pkgroot/go-xcaddy/go "${go}" env GOMODCACHE)"; do
	[ -d "${modcache}/cache/download" ] || { echo "No Go module cache at ${modcache}" >&2; exit 1; }
	cp -a "${modcache}/cache/download/." "${SET}/gomod/"
done
chmod -R u+w "${SET}"
# Go keeps no .info for a module it fetched as a requirement, but xcaddy's `go get module@version` reads one from the
# file proxy: write it for every version the cache holds.
find "${SET}/gomod" -name '*.mod' -path '*/@v/*' | while read -r mod; do
	info="${mod%.mod}.info"
	[ -f "${info}" ] || printf '{"Version":"%s"}\n' "$(basename "${mod%.mod}")" > "${info}"
done
find "${SET}/gomod" -name '*.lock' -delete
echo "--- The source set"
du -sh "${SET}"/* 2> /dev/null || true

# Keep this step's layer to what is still read. Later stages copy only /out, and after-compile.sh needs static-php-cli itself,
# the licence files in source/ and the Go toolchain, which is the builder image's. The downloads are on their cache mount.
go_caches="$("${go}" env GOMODCACHE) $("${go}" env GOCACHE)"
echo "--- Before trimming"
# shellcheck disable=SC2086
du -sh source buildroot pkgroot log ${go_caches} 2> /dev/null || true
# shellcheck disable=SC2086
chmod -R u+w ${go_caches} 2> /dev/null || true
# shellcheck disable=SC2086
rm -rf buildroot pkgroot log ${go_caches}
find source -type f ! \( -iname '*LICEN[CS]E*' -o -iname 'COPY*' -o -iname 'NOTICE*' \) -delete
find source -type d -empty -delete
echo "--- After trimming"
du -sh source . 2> /dev/null || true
