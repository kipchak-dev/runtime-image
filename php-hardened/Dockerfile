# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
#
# Hardened PHP runtime for Kipchak: a static FrankenPHP binary on an empty filesystem.
#
#   runtime (default)  FROM scratch: the frankenphp binary, the php CLI for console scripts, CA certificates, php.ini,
#                      a Caddyfile and a non-root user. No shell, no package manager, no libc.
#   build              the same binary, plus a php CLI built with the same extensions, Composer and git on Debian,
#                      for the build stage of an API's Dockerfile and for CI.
#   alpine             the runtime's binary and settings on Alpine, for APIs that need to add programs (git, for
#                      the Git driver) with apk.
#
# PHP_VERSION is required: the exact release, e.g. 8.5.11. ./build.sh and the build workflow look up the latest
# release of each PHP version on php.net and pass it in. See README.md.

ARG FRANKENPHP_VERSION=1.13.5
# FrankenPHP's static builder for that release: an AlmaLinux 8 toolchain image holding the FrankenPHP source in
# /go/src/app. Pinned by digest, so that a rebuild uses the same toolchain.
ARG FRANKENPHP_BUILDER=dunglas/frankenphp:static-builder-musl-1.13.5@sha256:7e1a70e2f22d0b6e22e702f7665fa8b5ff7150addad541655f990b6d1db6d187
# Where the build and alpine images take the runtime from: the runtime stage, or an image built from it.
ARG RUNTIME_SOURCE=runtime
# The other images the build starts from, by digest, so that a rebuild starts from the same ones. The pipeline builds
# with these; it copies each, whole and under the same digest, to the public mirror before it publishes a set.
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG ALPINE_IMAGE=alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
ARG COMPOSER_IMAGE=composer/composer:2-bin@sha256:56a1b0a72bacd78079e3fa49a49e7bf58326365753415c99385ea2b08bded0a5

# A source set to build from instead of the network: empty unless the `sources` build context names one, as a
# rebuild from the mirror does (see the README and build-frankenphp.sh).
FROM scratch AS sources

FROM ${COMPOSER_IMAGE} AS composer

FROM ${FRANKENPHP_BUILDER} AS binary

ARG PHP_VERSION
# static-php-cli v3, pinned so that a rebuild uses the same build recipes. Most of its recipes fetch the latest
# release of a library, so the libraries themselves are refreshed with SOURCES_EPOCH.
ARG SPC_COMMIT=594e6439f4378ae02f3a70926e19d84992702535
# static-php-cli's recipe pins SQLite to a 2024 release, even at the head of its v3 branch, so the refresh never moves it
# and build-frankenphp.sh overrides it. The version, path and SHA3-256 are from the PRODUCT row of
# https://www.sqlite.org/download.html. check-sources.php fails the build when it falls too far behind.
ARG SQLITE_VERSION=3.54.1
ARG SQLITE_ARCHIVE=2026/sqlite-autoconf-3540100.tar.gz
ARG SQLITE_SHA3=b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4
# Caddy 2.11.9 reaches go-jose/v3 through its internal CA, and v3 has a High advisory with no fix: go.step.sm/crypto 0.92.0 and
# smallstep/certificates' master use v4 only, and the latter has no release yet. after-compile.sh fails if v3 is linked, and
# check-sources.php reports an unreleased pin as behind, by its own age. Move to a release as soon as one exists.
ARG STEP_CRYPTO_VERSION=v0.92.0
ARG STEP_CERTIFICATES_VERSION=v0.30.3-0.20261105213751-6d5a251fbe01
# static-php-cli installs xcaddy from its master branch whenever its Go differs from the builder image's, and @master can
# neither be resolved from a source set offline nor be rebuilt to the same thing later: build-frankenphp.sh pins it.
ARG XCADDY_VERSION=v0.4.7
ARG PHP_EXTENSIONS=apcu,bcmath,calendar,ctype,curl,dom,exif,fileinfo,filter,gd,gettext,gmp,iconv,intl,ldap,mbregex,mbstring,memcached,mysqli,mysqlnd,opcache,openssl,password-argon2,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,protobuf,rdkafka,redis,session,simplexml,sockets,sodium,sqlite3,sysvmsg,sysvsem,sysvshm,tidy,tokenizer,xml,xmlreader,xmlwriter,xsl,yaml,zip,zlib,zstd
ARG PHP_EXTENSION_LIBS=nghttp2
# 1 to replace musl's allocator, which is slow with threads, with mimalloc.
ARG MIMALLOC=1

# Changing SOURCES_EPOCH recompiles the binary from freshly downloaded sources, picking up every library's latest
# release. The pipeline and ./build.sh set it to the ISO week (2026-W41), so the first build of each week refreshes
# the libraries and later builds that week reuse the result.
ARG SOURCES_EPOCH=local
# Part of the download cache's name. Change it with an override of a recipe's source (SQLite, ICU), which a cache
# holding the old archive would otherwise ignore until the next week.
ARG SOURCES_REVISION=2
ARG TARGETARCH

COPY build-frankenphp.sh after-compile.sh check-sources.php check-download-urls.sh /usr/local/bin/
COPY tests/check-sources-test.php /usr/local/bin/tests/
# Two steps. The download step fetches everything, with the network; downloaded sources are cached for the epoch, so
# retried and repeated builds do not download them again. The GitHub token reaches it only as a secret mount, never as
# an ARG or ENV, so it is in no layer and no build history. The compile step has no network at all, so every build proves
# that the binaries compile from what was downloaded, which the set check proves is all in the source set.
RUN --mount=type=secret,id=github_token \
	--mount=type=cache,id=spc-sources-${SOURCES_REVISION}-${TARGETARCH}-${SOURCES_EPOCH},target=/go/src/app/dist/static-php-cli/downloads,sharing=locked \
	--mount=type=bind,from=sources,target=/sources \
	PHASE=download PHP_VERSION=${PHP_VERSION} SPC_COMMIT=${SPC_COMMIT} \
	SQLITE_VERSION=${SQLITE_VERSION} SQLITE_ARCHIVE=${SQLITE_ARCHIVE} SQLITE_SHA3=${SQLITE_SHA3} \
	STEP_CRYPTO_VERSION=${STEP_CRYPTO_VERSION} STEP_CERTIFICATES_VERSION=${STEP_CERTIFICATES_VERSION} XCADDY_VERSION=${XCADDY_VERSION} \
	PHP_EXTENSIONS=${PHP_EXTENSIONS} PHP_EXTENSION_LIBS=${PHP_EXTENSION_LIBS} MIMALLOC=${MIMALLOC} \
	bash /usr/local/bin/build-frankenphp.sh
RUN --network=none \
	--mount=type=cache,id=spc-sources-${SOURCES_REVISION}-${TARGETARCH}-${SOURCES_EPOCH},target=/go/src/app/dist/static-php-cli/downloads,sharing=locked \
	--mount=type=bind,from=sources,target=/sources \
	PHASE=compile PHP_VERSION=${PHP_VERSION} SPC_COMMIT=${SPC_COMMIT} \
	SQLITE_VERSION=${SQLITE_VERSION} SQLITE_ARCHIVE=${SQLITE_ARCHIVE} SQLITE_SHA3=${SQLITE_SHA3} \
	STEP_CRYPTO_VERSION=${STEP_CRYPTO_VERSION} STEP_CERTIFICATES_VERSION=${STEP_CERTIFICATES_VERSION} XCADDY_VERSION=${XCADDY_VERSION} \
	PHP_EXTENSIONS=${PHP_EXTENSIONS} PHP_EXTENSION_LIBS=${PHP_EXTENSION_LIBS} MIMALLOC=${MIMALLOC} \
	bash /usr/local/bin/build-frankenphp.sh
# The checks and licences, as their own step, so that a failure here keeps the compile above.
RUN --mount=type=secret,id=github_token \
	--mount=type=cache,id=spc-sources-${SOURCES_REVISION}-${TARGETARCH}-${SOURCES_EPOCH},target=/go/src/app/dist/static-php-cli/downloads,sharing=locked \
	--mount=type=bind,from=sources,target=/sources \
	SQLITE_VERSION=${SQLITE_VERSION} SQLITE_ARCHIVE=${SQLITE_ARCHIVE} SQLITE_SHA3=${SQLITE_SHA3} \
	STEP_CRYPTO_VERSION=${STEP_CRYPTO_VERSION} STEP_CERTIFICATES_VERSION=${STEP_CERTIFICATES_VERSION} XCADDY_VERSION=${XCADDY_VERSION} \
	bash /usr/local/bin/after-compile.sh


# The few files the runtime needs, prepared where there is a shell. The CA certificates come from Debian, or from the
# source set when rebuilding from one, which holds the same bundle as data.
FROM ${DEBIAN_IMAGE} AS rootfs

RUN --mount=type=bind,from=sources,target=/sources \
	if [ -f /sources/ca-certificates/ca-certificates.crt ]; then \
		mkdir -p /etc/ssl/certs /usr/share/doc/ca-certificates \
		&& cp /sources/ca-certificates/ca-certificates.crt /etc/ssl/certs/ \
		&& cp /sources/ca-certificates/copyright /usr/share/doc/ca-certificates/; \
	else \
		apt-get update \
		&& apt-get install -y --no-install-recommends ca-certificates \
		&& rm -rf /var/lib/apt/lists/*; \
	fi

RUN mkdir -p /rootfs/etc/ssl/certs /rootfs/etc/frankenphp/php.d /rootfs/usr/local/bin /rootfs/var/www/html \
		/rootfs/tmp /rootfs/usr/share/kipchak-runtime \
	&& cp /etc/ssl/certs/ca-certificates.crt /rootfs/etc/ssl/certs/ \
	&& printf 'root:x:0:0:root:/root:/sbin/nologin\nnonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin\n' > /rootfs/etc/passwd \
	&& printf 'root:x:0:\nnonroot:x:65532:\n' > /rootfs/etc/group \
	&& chmod 1777 /rootfs/tmp

COPY etc/frankenphp/ /rootfs/etc/frankenphp/
COPY var/www/html/index.php /rootfs/var/www/html/index.php
COPY --from=binary /out/frankenphp /out/php /rootfs/usr/local/bin/
COPY --from=binary /out/build-info.txt /out/extensions.txt /out/sources.txt /out/sources.lock.json \
	/out/sources-report.json /rootfs/usr/share/kipchak-runtime/
COPY --from=binary /out/THIRD-PARTY-LICENCES/ /rootfs/usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/
RUN mkdir -p /rootfs/usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/debian-ca-certificates \
	&& cp /usr/share/doc/ca-certificates/copyright /rootfs/usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/debian-ca-certificates/
# What NOTICE.md says the image carries: the notice, the build recipe, and the LGPL libraries' sources as built.
COPY NOTICE.md /rootfs/usr/share/kipchak-runtime/NOTICE.md
COPY Dockerfile build.sh build-frankenphp.sh after-compile.sh alpine-licences.sh check-sources.php check-download-urls.sh debian-sources.sh \
	alpine-sources.sh fetch-sources.sh README.md NOTICE.md /rootfs/usr/share/kipchak-runtime/source/recipe/
COPY tests/ /rootfs/usr/share/kipchak-runtime/source/recipe/tests/
COPY etc/ /rootfs/usr/share/kipchak-runtime/source/recipe/etc/
COPY var/ /rootfs/usr/share/kipchak-runtime/source/recipe/var/
COPY --from=binary /out/source-libraries/ /rootfs/usr/share/kipchak-runtime/source/libraries/


# The runtime image.
FROM scratch AS runtime

ARG PHP_VERSION
ARG FRANKENPHP_VERSION
ARG SOURCES_SET=local
ARG TARGETARCH

COPY --from=rootfs /rootfs/ /

LABEL org.opencontainers.image.title="Kipchak Runtime" \
	org.opencontainers.image.description="Hardened FrankenPHP ${FRANKENPHP_VERSION} with PHP ${PHP_VERSION} for Kipchak APIs" \
	org.opencontainers.image.vendor="Mamluk" \
	org.opencontainers.image.url="https://kipchak.dev" \
	org.kipchak.sources="${SOURCES_SET}-${TARGETARCH}"

ENV PATH=/usr/local/bin \
	SERVER_ROOT=/var/www/html \
	SERVER_NAME=:8080 \
	FRANKENPHP_CONFIG="worker /var/www/html/index.php" \
	XDG_CONFIG_HOME=/tmp/caddy/config \
	XDG_DATA_HOME=/tmp/caddy/data \
	SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

USER 65532:65532
WORKDIR /var/www/html
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/frankenphp"]
CMD ["run", "--config", "/etc/frankenphp/Caddyfile"]


# The build and alpine images take their binaries and settings from a runtime image: by default the one built
# above. The pipeline builds the runtime image for both architectures first and passes it in as RUNTIME_SOURCE, so
# the binaries are compiled once.
FROM ${RUNTIME_SOURCE} AS runtime-source


# For an API's build stage and for CI: Composer resolves platform requirements against exactly the extensions
# the runtime has.
FROM ${DEBIAN_IMAGE} AS build

RUN apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends ca-certificates git unzip \
	&& rm -rf /var/lib/apt/lists/*

COPY --from=runtime-source /usr/local/bin/frankenphp /usr/local/bin/php /usr/local/bin/
COPY --from=runtime-source /usr/share/kipchak-runtime/ /usr/share/kipchak-runtime/
COPY --from=composer /composer /usr/local/bin/composer
COPY etc/build/php.ini /etc/frankenphp/php.ini
# Composer's licence from inside its own archive, beside the others. Debian's packages keep theirs in /usr/share/doc.
RUN mkdir -p /usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/composer \
	&& cp /usr/local/bin/composer /tmp/composer.phar \
	&& php -n -r 'copy("phar:///tmp/composer.phar/LICENSE", "/usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/composer/LICENSE") || exit(1);' \
	&& rm /tmp/composer.phar

ARG PHP_VERSION
ARG SOURCES_SET=local
ARG TARGETARCH
LABEL org.kipchak.sources="${SOURCES_SET}-${TARGETARCH}"

ENV COMPOSER_ALLOW_SUPERUSER=1
WORKDIR /var/www


# The runtime's binary and settings on Alpine, for APIs that need to add programs such as git. The binary is static
# and uses nothing from Alpine; Alpine provides a shell and a package manager. The functions that start programs
# are enabled, because here there are programs to start.
FROM ${ALPINE_IMAGE} AS alpine

ARG PHP_VERSION
ARG FRANKENPHP_VERSION
ARG SOURCES_SET=local
ARG TARGETARCH

RUN apk upgrade --no-cache \
	&& addgroup -g 65532 nonroot \
	&& adduser -u 65532 -G nonroot -D -H -h /home/nonroot -s /sbin/nologin nonroot

COPY --from=runtime-source /usr/local/bin/ /usr/local/bin/
COPY --from=runtime-source /etc/frankenphp/ /etc/frankenphp/
COPY --from=runtime-source /var/www/ /var/www/
COPY --from=runtime-source /usr/share/kipchak-runtime/ /usr/share/kipchak-runtime/
COPY etc/alpine/alpine.ini /etc/frankenphp/php.d/00-alpine.ini
COPY alpine-licences.sh /tmp/alpine-licences.sh
# The licences of Alpine's own packages: what is installed, and the text of each licence it names.
RUN sh /tmp/alpine-licences.sh /usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/alpine && rm /tmp/alpine-licences.sh

LABEL org.opencontainers.image.title="Kipchak Runtime (Alpine)" \
	org.opencontainers.image.description="Hardened FrankenPHP ${FRANKENPHP_VERSION} with PHP ${PHP_VERSION} for Kipchak APIs, on Alpine" \
	org.opencontainers.image.vendor="Mamluk" \
	org.opencontainers.image.url="https://kipchak.dev" \
	org.kipchak.sources="${SOURCES_SET}-${TARGETARCH}"

ENV SERVER_ROOT=/var/www/html \
	SERVER_NAME=:8080 \
	FRANKENPHP_CONFIG="worker /var/www/html/index.php" \
	XDG_CONFIG_HOME=/tmp/caddy/config \
	XDG_DATA_HOME=/tmp/caddy/data \
	SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

USER 65532:65532
WORKDIR /var/www/html
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/frankenphp"]
CMD ["run", "--config", "/etc/frankenphp/Caddyfile"]


# THE SOURCE SET of this build (see NOTICE.md and build-frankenphp.sh), which the pipeline keeps on 1x.ax: what
# the binaries were built from, the CA bundle, and the exact Debian and Alpine source packages of the build and
# alpine images. Built only as `--target sources-set`, never into an image that is offered.
FROM build AS debian-sources
COPY debian-sources.sh /tmp/debian-sources.sh
RUN sh /tmp/debian-sources.sh /set/debian

FROM alpine AS alpine-sources
USER root
COPY alpine-sources.sh /tmp/alpine-sources.sh
RUN sh /tmp/alpine-sources.sh /set/alpine

FROM ${ALPINE_IMAGE} AS sources-index
ARG FRANKENPHP_BUILDER
ARG DEBIAN_IMAGE
ARG ALPINE_IMAGE
ARG COMPOSER_IMAGE
ARG PHP_VERSION
ARG TARGETARCH
COPY --from=binary /out-set/ /set/
COPY --from=rootfs /etc/ssl/certs/ca-certificates.crt /usr/share/doc/ca-certificates/copyright /set/ca-certificates/
COPY --from=debian-sources /set/debian/ /set/debian/
COPY --from=alpine-sources /set/alpine/ /set/alpine/
COPY Dockerfile /tmp/Dockerfile
# What the set is for, the images it was built with and the Dockerfile frontend (from this file's syntax line), each by
# the digest the mirror keeps it under, and every file's SHA-256.
RUN printf 'php %s\narch %s\ndockerfile %s\nbuilder %s\ndebian %s\nalpine %s\ncomposer %s\n' "${PHP_VERSION}" "${TARGETARCH}" \
		"$(sed -n '1s/^# syntax=//p' /tmp/Dockerfile)" \
		"${FRANKENPHP_BUILDER}" "${DEBIAN_IMAGE}" "${ALPINE_IMAGE}" "${COMPOSER_IMAGE}" > /set/IMAGES.txt \
	&& grep -q '^dockerfile docker/dockerfile:[^ ]*@sha256:[0-9a-f]\{64\}$' /set/IMAGES.txt \
	&& cd /set && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS

# The set must rebuild a customer's binaries with no network. This proves it before the set, or any image built with
# it, is published: build-frankenphp.sh with SET_CHECK=1 takes every download, Go, xcaddy and every Go module from the
# set alone, with this build's settings, and stops before compiling (see build-frankenphp.sh).
FROM ${FRANKENPHP_BUILDER} AS set-check
COPY build-frankenphp.sh after-compile.sh check-sources.php check-download-urls.sh /usr/local/bin/
COPY tests/check-sources-test.php /usr/local/bin/tests/
COPY --from=binary /out/build.env /tmp/build.env
RUN --network=none --mount=type=bind,from=sources-index,source=/set,target=/sources \
	set -a && . /tmp/build.env && set +a && SET_CHECK=1 REQUIRE_SUMDB=1 bash /usr/local/bin/build-frankenphp.sh \
	&& echo checked > /set-checked

FROM sources-index AS sources-pack
# Only a set that passed set-check is packed and published.
COPY --from=set-check /set-checked /tmp/set-checked
# The mirror keeps each file once, shared by every set that has it. The 3,500 or so small files (Go .mod and .info, the
# Debian and Alpine package files) go into one tar, the same bytes whenever they are, so that a set's manifest stays
# small; fetch-sources.sh unpacks it.
RUN apk add --no-cache -q tar \
	&& cd /set && find . -type f -size -64k ! -name SHA256SUMS ! -name IMAGES.txt | sort > /tmp/small \
	&& tar --mtime=@0 --owner=0 --group=0 --numeric-owner --no-recursion -cf small-files.tar -T /tmp/small \
	&& tr '\n' '\0' < /tmp/small | xargs -0 rm && find . -type d -empty -delete

FROM scratch AS sources-set
COPY --from=sources-pack /set/ /


# The default target, and the last stage, so that a plain docker build produces the runtime image.
FROM runtime AS default
