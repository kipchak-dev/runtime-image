# syntax=docker/dockerfile:1
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
# PHP_VERSION is required: the exact release, e.g. 8.5.11. ./build.sh and the Concourse pipeline look up the latest
# release of each PHP version on php.net and pass it in. See README.md.

ARG FRANKENPHP_VERSION=1.13.2
# FrankenPHP's static builder for that release: an AlmaLinux 8 toolchain image holding the FrankenPHP source in
# /go/src/app. Pinned by digest because 1.13.2 was published only as static-builder-musl, without the
# static-builder-musl-1.13.2 tag; its labels give version 1.13.2, revision 0ad8a403 (the v1.13.2 tag).
ARG FRANKENPHP_BUILDER=dunglas/frankenphp:static-builder-musl@sha256:c2db90161dbc00a93fac80a73059b1ca7e7aa9a4c9cbaa70d663ad47f572b795
# Where the build and alpine images take the runtime from: the runtime stage, or an image built from it.
ARG RUNTIME_SOURCE=runtime

FROM ${FRANKENPHP_BUILDER} AS binary

ARG PHP_VERSION
# static-php-cli v3, pinned so that a rebuild uses the same build recipes. Most of its recipes fetch the latest
# release of a library, so the libraries themselves are refreshed with SOURCES_EPOCH.
ARG SPC_COMMIT=594e6439f4378ae02f3a70926e19d84992702535
ARG PHP_EXTENSIONS=apcu,bcmath,calendar,ctype,curl,dom,exif,fileinfo,filter,gd,gettext,gmp,iconv,igbinary,intl,ldap,mbregex,mbstring,memcached,mysqli,mysqlnd,opcache,openssl,password-argon2,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,protobuf,rdkafka,redis,session,simplexml,sockets,sodium,sqlite3,sysvmsg,sysvsem,sysvshm,tidy,tokenizer,xml,xmlreader,xmlwriter,xsl,yaml,zip,zlib,zstd
ARG PHP_EXTENSION_LIBS=nghttp2
# 1 to replace musl's allocator, which is slow with threads, with mimalloc.
ARG MIMALLOC=1

# Changing SOURCES_EPOCH recompiles the binary from freshly downloaded sources, picking up every library's latest
# release. The pipeline and ./build.sh set it to the ISO week (2026-W41), so the first build of each week refreshes
# the libraries and later builds that week reuse the result.
ARG SOURCES_EPOCH=local
ARG TARGETARCH

COPY build-frankenphp.sh /usr/local/bin/build-frankenphp.sh
# Downloaded sources are cached for the epoch, so retried and repeated builds do not download them again.
RUN --mount=type=secret,id=github_token \
	--mount=type=cache,id=spc-sources-${TARGETARCH}-${SOURCES_EPOCH},target=/go/src/app/dist/static-php-cli/downloads,sharing=locked \
	PHP_VERSION=${PHP_VERSION} SPC_COMMIT=${SPC_COMMIT} \
	PHP_EXTENSIONS=${PHP_EXTENSIONS} PHP_EXTENSION_LIBS=${PHP_EXTENSION_LIBS} MIMALLOC=${MIMALLOC} \
	bash /usr/local/bin/build-frankenphp.sh


# The few files the runtime needs, prepared where there is a shell.
FROM debian:trixie-slim AS rootfs

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

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
	/rootfs/usr/share/kipchak-runtime/


# The runtime image.
FROM scratch AS runtime

ARG PHP_VERSION
ARG FRANKENPHP_VERSION

COPY --from=rootfs /rootfs/ /

LABEL org.opencontainers.image.title="Kipchak Runtime" \
	org.opencontainers.image.description="Hardened FrankenPHP ${FRANKENPHP_VERSION} with PHP ${PHP_VERSION} for Kipchak APIs" \
	org.opencontainers.image.vendor="Mamluk" \
	org.opencontainers.image.url="https://kipchak.dev"

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
FROM debian:trixie-slim AS build

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates git unzip \
	&& rm -rf /var/lib/apt/lists/*

COPY --from=runtime-source /usr/local/bin/frankenphp /usr/local/bin/php /usr/local/bin/
COPY --from=runtime-source /usr/share/kipchak-runtime/ /usr/share/kipchak-runtime/
COPY --from=composer/composer:2-bin /composer /usr/local/bin/composer
COPY etc/build/php.ini /etc/frankenphp/php.ini

ENV COMPOSER_ALLOW_SUPERUSER=1
WORKDIR /var/www


# The runtime's binary and settings on Alpine, for APIs that need to add programs such as git. The binary is static
# and uses nothing from Alpine; Alpine provides a shell and a package manager. The functions that start programs
# are enabled, because here there are programs to start.
FROM alpine:3.24 AS alpine

ARG PHP_VERSION
ARG FRANKENPHP_VERSION

RUN apk upgrade --no-cache \
	&& addgroup -g 65532 nonroot \
	&& adduser -u 65532 -G nonroot -D -H -h /home/nonroot -s /sbin/nologin nonroot

COPY --from=runtime-source /usr/local/bin/ /usr/local/bin/
COPY --from=runtime-source /etc/frankenphp/ /etc/frankenphp/
COPY --from=runtime-source /var/www/ /var/www/
COPY --from=runtime-source /usr/share/kipchak-runtime/ /usr/share/kipchak-runtime/
COPY etc/alpine/alpine.ini /etc/frankenphp/php.d/00-alpine.ini

LABEL org.opencontainers.image.title="Kipchak Runtime (Alpine)" \
	org.opencontainers.image.description="Hardened FrankenPHP ${FRANKENPHP_VERSION} with PHP ${PHP_VERSION} for Kipchak APIs, on Alpine" \
	org.opencontainers.image.vendor="Mamluk" \
	org.opencontainers.image.url="https://kipchak.dev"

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


# The default target, and the last stage, so that a plain docker build produces the runtime image.
FROM runtime AS default
