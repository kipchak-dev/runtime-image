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
SPC_TARGET="$(uname -m)-linux-musl"
export SPC_TARGET
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
# Go checks every module against sum.golang.org, the Go checksum database. With the network, it asks the database and
# keeps the answers in its module cache; every set carries those answers in gomod/sumdb, and the marker file
# "supported" lets Go read them from the set as its proxy, with no network. A set made before the answers were kept
# has no marker: its modules are then read unchecked, as they always were, and the build says so.
gosumdb() {
	if from_set && [ ! -f "${SOURCES}/gomod/sumdb/sum.golang.org/supported" ]; then
		# Mamluk's own set check sets REQUIRE_SUMDB=1: a set it has just made must carry its records.
		if [ "${REQUIRE_SUMDB:-0}" = 1 ]; then
			echo 'This source set carries no checksum database records, and REQUIRE_SUMDB=1 requires them.' >&2; exit 1
		fi
		echo 'NOTICE: this source set carries no checksum database records; its Go modules are not checked against sum.golang.org.'
		export GOSUMDB=off
	else
		from_set && restore_sumdb_notes
		unset GOSUMDB
	fi
}
# The newest checksum-database tree each Go client verified in the download phase. Go keeps it in
# $GOPATH/pkg/sumdb/sum.golang.org/latest, outside the module cache, and needs it offline: without it, a client that
# meets cached answers from two tree sizes must prove the two consistent from tiles the download phase never fetched.
# The set carries one signed note per GOPATH (gosumdb/<name>.latest, with that GOPATH in gosumdb/<name>.gopath), and
# each is put back where its client reads it. The notes are signed by sum.golang.org's key, which Go checks.
sumdb_tree() { awk '/^go.sum database tree$/ { getline; print; exit }' "$1"; }
restore_sumdb_notes() {
	restored=0
	for gopath_file in "${SOURCES}"/gosumdb/*.gopath; do
		[ -f "${gopath_file}" ] || continue
		note="${gopath_file%.gopath}.latest"
		gopath="$(cat "${gopath_file}")"
		[ -f "${note}" ] && [ -n "${gopath}" ] || { echo "The source set's ${gopath_file##*/} has no tree note beside it." >&2; exit 1; }
		mkdir -p "${gopath}/pkg/sumdb/sum.golang.org"
		cp "${note}" "${gopath}/pkg/sumdb/sum.golang.org/latest"
		restored=$((restored + 1))
	done
	[ "${restored}" -gt 0 ] || {
		echo 'The source set carries checksum database records but not the tree notes they are checked against.' >&2; exit 1; }
}
mkdir -p "${SET}"
# Archives written the same way every time, so the same contents give the same bytes and are stored once.
pack() { tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner "$@" -cf - . | gzip -n; }

mkdir -p "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"
cd "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"

# THE TWO PHASES. PHASE=download, run with the network, fetches everything the compile will need: static-php-cli and its
# overrides, every source and toolchain archive, Go, xcaddy and every Go module. PHASE=compile, run with --network=none in
# the Dockerfile, builds from what the download phase left, so every build proves that the compile needs nothing from
# the network. PHASE=all (the default) runs both, one after the other.
PHASE="${PHASE:-all}"
case "${PHASE}" in download|compile|all) ;; *) echo "PHASE must be download, compile or all, not ${PHASE}" >&2; exit 1 ;; esac
[ "${SET_CHECK:-0}" = 1 ] && [ "${PHASE}" = compile ] && { echo 'SET_CHECK runs the download phase' >&2; exit 1; }

if [ "${PHASE}" != compile ]; then
# Start from a clean checkout and build root; only the downloaded sources are kept, in the cache mount.
find . -mindepth 1 -maxdepth 1 ! -name downloads -exec rm -rf {} +
if from_set; then
	tar -xzf "${SOURCES}/static-php-cli.tar.gz"
	[ "$(git rev-parse HEAD)" = "${SPC_COMMIT}" ] \
		|| { echo "The set's static-php-cli is not at SPC_COMMIT ${SPC_COMMIT}." >&2; exit 1; }
	# The set's downloads, with static-php-cli's record of them, so that its download step finds every one in place.
	cp -a "${SOURCES}/downloads/." downloads/
	# The Go modules from the set alone, each checked against the checksum database's records that the set carries
	# (gosumdb, below). A set made before those records were kept has none, so it is read as before, unchecked.
	export GOPROXY="file://${SOURCES}/gomod" GOFLAGS=-mod=mod GOTOOLCHAIN=local
	gosumdb
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

# A download that stops before compiling. craft has no such option: it reads craft-options.download but never
# craft-options.build, and always goes on to extract and build. With SPC_DOWNLOAD_ONLY=1 the installer returns after
# its download step, having resolved and fetched exactly what craft would build from. Its download step is the one place
# both phases share, so the download phase and the set check fetch the same artifacts as the compile uses.
# shellcheck disable=SC2016 # the dollar sign is part of the PHP text matched
[ "$(grep -c '^        \$this->extractSourceArtifacts();$' src/StaticPHP/Package/PackageInstaller.php)" = 1 ] \
	|| { echo 'static-php-cli changed PackageInstaller::run: review the download-only override in build-frankenphp.sh' >&2; exit 1; }
sed -i "s#^        \\\$this->extractSourceArtifacts();\$#        if (getenv('SPC_DOWNLOAD_ONLY') === '1') { return; }\n&#" src/StaticPHP/Package/PackageInstaller.php
grep -qF "if (getenv('SPC_DOWNLOAD_ONLY') === '1') { return; }" src/StaticPHP/Package/PackageInstaller.php \
	|| { echo 'The download-only override did not apply.' >&2; exit 1; }

# An anonymous retry when GitHub refuses the token. A project whose organisation keeps an IP allow list (confluentinc,
# for librdkafka) refuses an authenticated API request from an address outside that list with 403, even for its public
# releases, and GitHub applies the list to the GitHub Actions token; the same request without a token is answered.
# static-php-cli runs curl with -f, so it sees only that an API request failed (curl exit code 22). Each request to
# api.github.com that carried an Authorization header and failed so is made once more without it. Nothing else changes:
# other hosts, and requests that carried no token, fail as before.
# The same patch records, for every download, the address it came from in downloads/.download-urls, which the source set
# carries so that Mamluk's promote job can download each archive again and compare it (Amendment 1).
# When the anonymous request is refused too because the runner's shared address has used its hourly allowance, the patch
# waits for the allowance to reset (at most an hour) and asks once more (github-rate-limit.php).
cp /usr/local/bin/github-rate-limit.php src/kipchak-github-rate-limit.php
php <<'PHP'
<?php
$file = 'src/StaticPHP/Runtime/Shell/DefaultShell.php';
$text = file_get_contents($file);
if (str_contains($text, 'GitHub refused the token for')) {
    fwrite(STDERR, "DefaultShell.php already carries the anonymous retry: static-php-cli was not freshly checked out\n");
    exit(1);
}
$edits = [
    // executeCurl: the API requests (release lists, latest releases, tags).
    "        if (\$ret === 2 || \$ret === -1073741510) {\n" =>
        "        if (\$ret === 22 && str_starts_with(\$url, 'https://api.github.com/') && preg_grep('/^Authorization:/i', \$headers) !== []) {\n"
        . "            logger()->warning(\"GitHub refused the token for {\$url}; asking again without it\");\n"
        . "            \$anonymous = array_values(preg_grep('/^Authorization:/i', \$headers, PREG_GREP_INVERT));\n"
        . "            \$answer = \$this->executeCurl(\$url, \$method, \$anonymous, \$hooks, \$retries, \$compressed);\n"
        . "            require_once dirname(__DIR__, 3) . '/kipchak-github-rate-limit.php';\n"
        . "            if (\$answer === false && \\kipchak_github_rate_limit_wait()) {\n"
        . "                logger()->warning(\"GitHub's anonymous allowance was used up; waited for it to reset, asking again for {\$url}\");\n"
        . "                \$answer = \$this->executeCurl(\$url, \$method, \$anonymous, \$hooks, \$retries, \$compressed);\n"
        . "            }\n"
        . "            return \$answer;\n"
        . "        }\n"
        . "        if (\$ret === 2 || \$ret === -1073741510) {\n",
    // executeCurlDownload: the archive downloads, whose URLs for GitHub tarballs are on api.github.com too.
    "        \$this->passthru(\$cmd, \$this->console_putput, capture_output: false, throw_on_error: true);\n" =>
        "        try {\n"
        . "            \$this->passthru(\$cmd, \$this->console_putput, capture_output: false, throw_on_error: true);\n"
        . "        } catch (ExecutionException \$e) {\n"
        . "            if (!str_starts_with(\$url, 'https://api.github.com/') || preg_grep('/^Authorization:/i', \$headers) === []) {\n"
        . "                throw \$e;\n"
        . "            }\n"
        . "            logger()->warning(\"GitHub refused the token for {\$url}; downloading again without it\");\n"
        . "            \$anonymous = array_values(preg_grep('/^Authorization:/i', \$headers, PREG_GREP_INVERT));\n"
        . "            try {\n"
        . "                \$this->executeCurlDownload(\$url, \$path, \$anonymous, \$hooks, \$retries);\n"
        . "            } catch (ExecutionException \$again) {\n"
        . "                require_once dirname(__DIR__, 3) . '/kipchak-github-rate-limit.php';\n"
        . "                if (!\\kipchak_github_rate_limit_wait()) {\n"
        . "                    throw \$again;\n"
        . "                }\n"
        . "                logger()->warning(\"GitHub's anonymous allowance was used up; waited for it to reset, downloading again {\$url}\");\n"
        . "                \$this->executeCurlDownload(\$url, \$path, \$anonymous, \$hooks, \$retries);\n"
        . "            }\n"
        . "            return;\n"
        . "        }\n"
        // Where each download came from (Amendment 1): the address as requested, before any redirect, its headers
        // without Authorization, and the file it was saved as. Written after the download succeeded, by the call that
        // succeeded. The set carries it, and check-download-urls.sh refuses anything not public before it is written.
        . "        \$public = array_values(preg_grep('/^Authorization:/i', \$headers, PREG_GREP_INVERT));\n"
        . "        file_put_contents(dirname(\$path) . '/.download-urls', \$url . \"\\t\" . implode(' | ', \$public) . \"\\t\" . basename(\$path) . \"\\n\", FILE_APPEND | LOCK_EX);\n",
];
foreach ($edits as $old => $new) {
    if (substr_count($text, $old) !== 1) {
        fwrite(STDERR, "static-php-cli changed DefaultShell.php: review the anonymous retry in build-frankenphp.sh\n");
        exit(1);
    }
    $text = str_replace($old, $new, $text);
}
file_put_contents($file, $text);
PHP
[ "$(grep -c 'GitHub refused the token for' src/StaticPHP/Runtime/Shell/DefaultShell.php)" = 2 ] \
	&& grep -qF "dirname(\$path) . '/.download-urls'" src/StaticPHP/Runtime/Shell/DefaultShell.php \
	&& [ "$(grep -c 'kipchak_github_rate_limit_wait()' src/StaticPHP/Runtime/Shell/DefaultShell.php)" = 2 ] \
	&& php -l src/StaticPHP/Runtime/Shell/DefaultShell.php > /dev/null \
	|| { echo 'The anonymous retry did not apply.' >&2; exit 1; }

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

# The download itself: what craft would fetch, then Go and xcaddy, then every Go module the binary imports. Nothing is
# compiled. From a set (and in the set check) this runs with no network, so every one of them must come from the set.
# The doctor first, on its own: its fixes (zig, for one) install packages through the same installer, which the
# download-only override would stop before installing.
./bin/spc doctor --auto-fix
SPC_DOWNLOAD_ONLY=1 ./bin/spc craft craft.yml
./bin/spc install-pkg go-xcaddy
go=/opt/spc-pkgroot/go-xcaddy/bin/go
# xcaddy writes the module FrankenPHP is built as, and resolves it, then stops before compiling.
# Its build environment goes in a directory of its own (xcaddy uses TMPDIR), so it is the only buildenv_ there.
work="$(mktemp -d)"
(export PATH="/opt/spc-pkgroot/go-xcaddy/bin:${PATH}" GOPATH=/opt/spc-pkgroot/go-xcaddy/go
	cd "${work}" && TMPDIR="${work}" XCADDY_SKIP_BUILD=1 XCADDY_SKIP_CLEANUP=1 xcaddy build \
		--with "github.com/dunglas/frankenphp=${FRANKENPHP_SOURCE_PATH}" \
		--with "github.com/dunglas/frankenphp/caddy=${FRANKENPHP_SOURCE_PATH}/caddy" \
		--with github.com/dunglas/caddy-cbrotli)
module="$(ls -d "${work}"/buildenv_* 2> /dev/null | head -n 1)"
[ -d "${module}" ] || { echo 'xcaddy left no build environment to check' >&2; exit 1; }
# Every package the binary imports. With the network this fetches each module; from a set, each must be in it.
modules="$(cd "${module}" && GOPATH=/opt/spc-pkgroot/go-xcaddy/go CGO_ENABLED=1 "${go}" list -deps \
	-f '{{with .Module}}{{.Path}}@{{.Version}}{{end}}' . | sort -u | grep -c .)"
# The Caddy release the binary will be built with. xcaddy asks for Caddy with no version, and from a file proxy "latest"
# is whatever the cache holds, so the compile must build exactly this one (checked after the build).
caddy_version="$(cd "${module}" && GOPATH=/opt/spc-pkgroot/go-xcaddy/go "${go}" list -m -f '{{.Version}}' github.com/caddyserver/caddy/v2)"
printf '%s\n' "${caddy_version}" | grep -Eqx 'v2\.[0-9]+\.[0-9]+' || { echo "Could not resolve the Caddy release: '${caddy_version}'" >&2; exit 1; }
mkdir -p /out && printf '%s\n' "${caddy_version}" > /out/caddy-version
# FrankenPHP's own modules are built from the builder image's source (xcaddy replaces them with /go/src/app), but the
# binary's build information records the version Go resolved for them. Go downloads nothing for a replaced module, so
# its version is not in the module cache, and offline "latest" would resolve to a placeholder (v0.0.0-...). Download
# each at the version resolved here, so that the compile records the same version a networked build does.
for m in github.com/dunglas/frankenphp github.com/dunglas/frankenphp/caddy; do
	v="$(cd "${module}" && GOPATH=/opt/spc-pkgroot/go-xcaddy/go "${go}" list -m -f '{{if .Replace}}{{.Version}}{{end}}' "${m}")"
	printf '%s\n' "${v}" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+' || { echo "Could not resolve the version recorded for ${m}: '${v}'" >&2; exit 1; }
	(cd "${module}" && GOPATH=/opt/spc-pkgroot/go-xcaddy/go GOFLAGS=-mod=mod "${go}" mod download "${m}@${v}")
	echo "${m} is recorded as ${v}."
done
rm -rf "${work}"
echo "Caddy ${caddy_version}."
# The set merges both Go clients' module caches, xcaddy's over the default's, as the set writer below does. An answer one
# client cached from a larger checksum tree than the other client's note then needs a proof between the two trees,
# from tiles neither client fetched, and the offline set check fails reading them. While the network is here, Go checks
# every answer in that merged view against both notes and fetches what is missing (sumdb-prove.sh); the tiles go into
# xcaddy's cache, which the set carries.
if ! from_set; then
	merged="$(mktemp -d)"
	xcaddy_cache="$(GOPATH=/opt/spc-pkgroot/go-xcaddy/go "${go}" env GOMODCACHE)/cache/download"
	cp -a "$("${go}" env GOMODCACHE)/cache/download/." "${merged}/"
	cp -a "${xcaddy_cache}/." "${merged}/"
	chmod -R u+w "${merged}"
	notes=""
	for note in "$("${go}" env GOPATH)/pkg/sumdb/sum.golang.org/latest" /opt/spc-pkgroot/go-xcaddy/go/pkg/sumdb/sum.golang.org/latest; do
		[ -f "${note}" ] && notes="${notes} ${note}"
	done
	# shellcheck disable=SC2086 # one argument per note
	sh /usr/local/bin/sumdb-prove.sh "${go}" "${merged}" ${notes}
	(cd "${merged}" && find . -path './sumdb/sum.golang.org/tile/*' -type f) | while read -r tile; do
		[ -f "${xcaddy_cache}/${tile}" ] && continue
		mkdir -p "$(dirname "${xcaddy_cache}/${tile}")"
		cp "${merged}/${tile}" "${xcaddy_cache}/${tile}"
	done
	rm -rf "${merged:?}"
fi
echo "Downloaded: every source and toolchain archive, Go, xcaddy ${XCADDY_VERSION} and the ${modules} Go modules the binary imports."
fi # the download phase

# SET_CHECK=1 (the set-check stage of the Dockerfile, run with no network) proves the set can rebuild: it is the download
# phase run from the set alone, so everything the build downloads must be in it. It stops there, without compiling, so a
# set that would fail a customer's rebuild fails the pipeline before its images are published.
if [ "${SET_CHECK:-0}" = 1 ]; then
	from_set || { echo 'SET_CHECK needs a source set at /sources' >&2; exit 1; }
	echo "The source set rebuilds offline: downloads, Go, xcaddy ${XCADDY_VERSION} and the Go modules the binary imports."
	exit 0
fi
[ "${PHASE}" = download ] && exit 0

# THE COMPILE. Everything was fetched by the download phase, so nothing is downloaded and the doctor, which can fetch
# missing tools, is not run again. Go may read only its module cache.
[ -f craft.yml ] || { echo 'No craft.yml: run the download phase first' >&2; exit 1; }
sed -i 's/^  doctor: true$/  doctor: false/; s/^  download: true$/  download: false/' craft.yml
if ! grep -qx '  download: false' craft.yml || ! grep -qx '  doctor: false' craft.yml; then
	echo 'craft.yml was not switched to compile only' >&2; exit 1
fi
# Go reads modules only from the two module caches the download phase filled, served as file proxies (as a rebuild
# from a set reads the set's). GOPROXY=off is not enough: xcaddy runs `go get github.com/caddyserver/caddy/v2` with no
# version, and resolving "latest" is a lookup, which GOPROXY=off refuses even when the module is cached. The step runs
# with --network=none, so nothing can come from elsewhere. Every module is still checked against the checksum
# database's answers, which the download phase kept in the cache (gosumdb); a module with no recorded answer fails.
go=/opt/spc-pkgroot/go-xcaddy/bin/go
GOPROXY="file://$(GOPATH=/opt/spc-pkgroot/go-xcaddy/go "${go}" env GOMODCACHE)/cache/download,file://$("${go}" env GOMODCACHE)/cache/download"
from_set && GOPROXY="${GOPROXY},file://${SOURCES}/gomod"
case "${GOPROXY}" in *http:*|*https:*) echo 'The compile must not name a network proxy' >&2; exit 1 ;; esac
export GOPROXY GOFLAGS=-mod=mod GOTOOLCHAIN=local
gosumdb
caddy_version="$(cat /out/caddy-version 2> /dev/null || true)"
printf '%s\n' "${caddy_version}" | grep -Eqx 'v2\.[0-9]+\.[0-9]+' || { echo 'No Caddy release recorded: run the download phase first' >&2; exit 1; }
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
# Every module the binary records carries a real version: a placeholder means a version was not in the module cache.
if grep -q 'v0\.0\.0-00010101000000-000000000000' /out/build-info.txt; then
	grep 'v0\.0\.0-00010101000000-000000000000' /out/build-info.txt >&2
	echo 'The build information records a module with no version; the download phase did not fetch it.' >&2; exit 1
fi
# And the Caddy release the download phase resolved, not whatever else the module cache might hold.
case "${version}" in
	*" Caddy ${caddy_version} "*) ;;
	*) echo "Expected Caddy ${caddy_version}, built: ${version}" >&2; exit 1 ;;
esac
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
# Where each archive in the set was downloaded from (Amendment 1): for every file the set holds, the last address that
# file was saved from. A set rebuilt from an older set has no record to carry and writes none; a build that downloaded
# must have one for every archive, and every address in it must be public (check-download-urls.sh).
: > /tmp/download-urls
if [ -f downloads/.download-urls ]; then
	for file in "${SET}"/downloads/*; do
		[ -f "${file}" ] || continue
		name="$(basename "${file}")"
		awk -F '\t' -v n="${name}" '$3 == n { line = $0 } END { if (line != "") print line }' downloads/.download-urls > /tmp/download-url
		if [ -s /tmp/download-url ]; then cat /tmp/download-url >> /tmp/download-urls
		elif ! from_set; then echo "No download address was recorded for ${name}." >&2; exit 1; fi
	done
	bash /usr/local/bin/check-download-urls.sh /tmp/download-urls
	cp /tmp/download-urls "${SET}/downloads/.download-urls"
elif ! from_set; then
	echo 'The download phase recorded no download addresses (downloads/.download-urls).' >&2; exit 1
fi
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
# The checksum database's answers, which a rebuild checks every module against, and the marker that serves them.
[ -d "${SET}/gomod/sumdb/sum.golang.org" ] \
	|| { echo 'The module cache holds no checksum database records; the set could not be checked offline.' >&2; exit 1; }
touch "${SET}/gomod/sumdb/sum.golang.org/supported"
# Each Go client's newest verified tree note (restore_sumdb_notes). A note must exist wherever that client cached
# answers, and must be no older than the newest tree any of those answers names: an older one would leave the client
# needing proofs that were never fetched.
mkdir -p "${SET}/gosumdb"
for entry in "default:$("${go}" env GOPATH)" "xcaddy:/opt/spc-pkgroot/go-xcaddy/go"; do
	name="${entry%%:*}"; gopath="${entry#*:}"
	lookups="$(GOPATH="${gopath}" "${go}" env GOMODCACHE)/cache/download/sumdb/sum.golang.org/lookup"
	[ -d "${lookups}" ] || continue
	note="${gopath}/pkg/sumdb/sum.golang.org/latest"
	[ -f "${note}" ] || { echo "The ${name} Go client cached checksum answers but kept no tree note at ${note}." >&2; exit 1; }
	# Every cached answer must name a tree size; one that does not is unreadable, and stops the set.
	answers="$(find "${lookups}" -type f | wc -l)"
	sizes="$(find "${lookups}" -type f -exec awk '/^go.sum database tree$/ { getline; print; exit }' {} \;)"
	[ "$(printf '%s\n' "${sizes}" | grep -Ecx '[0-9]+')" -eq "${answers}" ] \
		|| { echo "The ${name} Go client's cached checksum answers are not all readable (${answers} answers)." >&2; exit 1; }
	newest="$(printf '%s\n' "${sizes}" | sort -n | tail -n 1)"
	kept="$(sumdb_tree "${note}")"
	case "${kept}" in '' | *[!0-9]*) echo "Unreadable tree note: ${note}" >&2; exit 1 ;; esac
	[ "${kept}" -ge "${newest}" ] \
		|| { echo "The ${name} tree note (${kept}) is older than a cached answer (${newest})." >&2; exit 1; }
	cp "${note}" "${SET}/gosumdb/${name}.latest"
	printf '%s\n' "${gopath}" > "${SET}/gosumdb/${name}.gopath"
	echo "Checksum tree note for the ${name} Go client: tree ${kept}, newest cached answer ${newest}."
done
ls "${SET}"/gosumdb/*.latest > /dev/null 2>&1 \
	|| { echo 'No Go client kept a checksum tree note; the set could not be checked offline.' >&2; exit 1; }
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
