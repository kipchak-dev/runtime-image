# Hardened Kipchak runtime

A FrankenPHP image for running Kipchak APIs in production, for PHP 8.4 and 8.5, on `linux/amd64` and
`linux/arm64`. It is part of Kipchak Enterprise.

FrankenPHP and PHP are built from source into one static binary, linked against musl with mimalloc as the
allocator. The image is that binary on an empty filesystem (`FROM scratch`), with:

* `php`, a static PHP CLI with the same extensions, for console scripts;
* CA certificates, `php.ini` and a Caddyfile;
* a non-root user (`65532`), which runs the server;
* `/tmp`, the only directory the runtime user can write to. PHP and Caddy keep their temporary files there.

It has no shell, no package manager, no libc and no programs other than `frankenphp` and `php`, so an attacker who
gets code execution has nothing to run. The image is about 310 MB, almost all of it the two static binaries, against
about 2 GB for the free `franken` image.

Vulnerability scanners see the Go modules in the binary (Caddy and FrankenPHP), but not the C libraries compiled
into it, such as OpenSSL, curl and librdkafka. Instead, the images are rebuilt with the latest release of every
library once a week (see [Updates](#updates)), and each image lists the versions it contains.

| Image | Use |
| --- | --- |
| `1x.ax/mamluk/enterprise/php/8.5:franken` | Runtime, the latest PHP 8.5 release |
| `1x.ax/mamluk/enterprise/php/8.5:franken-8.5.11` | Runtime, pinned to a PHP release |
| `1x.ax/mamluk/enterprise/php/8.5:franken-build` | Build stage and CI: the same PHP with Composer, git and a shell |
| `1x.ax/mamluk/enterprise/php/8.5:franken-build-8.5.11` | The build image, pinned to a PHP release |
| `1x.ax/mamluk/enterprise/php/8.5:franken-alpine` | The runtime on Alpine, for APIs that need to add programs (see [Adding programs](#adding-programs)) |
| `1x.ax/mamluk/enterprise/php/8.5:franken-alpine-8.5.11` | The Alpine variant, pinned to a PHP release |
| `1x.ax/mamluk/enterprise/php/8.4:...` | The same for PHP 8.4 |

## Extensions

The extensions are compiled in and cannot be added later. igbinary is not among them: its latest stable release does not
compile against PHP 8.5, and a release candidate has no place in this image. `redis` and `memcached` are therefore built
without that serialiser. It can return when upstream publishes a stable release for PHP 8.5. They are:

apcu, bcmath, calendar, ctype, curl, dom, exif, fileinfo, filter, gd, gettext, gmp, iconv, intl, ldap,
mbregex, mbstring, memcached, mysqli, mysqlnd, opcache, openssl, password-argon2, pcntl, pdo, pdo_mysql,
pdo_pgsql, pdo_sqlite, pgsql, phar, posix, protobuf, **rdkafka**, redis, session, simplexml, sockets, sodium,
sqlite3, sysvmsg, sysvsem, sysvshm, tidy, tokenizer, xml, xmlreader, xmlwriter, xsl, yaml, zip, zlib, zstd.

`rdkafka` is included for the [Kafka driver](https://kipchak.dev/docs/driver-kafka). Xdebug is not: develop
against the free `franken-dev` image.

Each image records what it contains, in `/usr/share/kipchak-runtime/`:

* `extensions.txt`: every extension, with its version;
* `sources.txt` and `sources.lock.json`: every source downloaded for the build, including each library's
  version, for a software bill of materials;
* `build-info.txt`: FrankenPHP's build information.

## Using it in an API

Install dependencies in the build image, and copy the result into the runtime:

```dockerfile
FROM 1x.ax/mamluk/enterprise/php/8.5:franken-build AS build

COPY composer.json composer.lock ./
RUN --mount=type=secret,id=composer-auth,target=/root/.composer/auth.json \
    composer install --no-dev --no-scripts --no-autoloader --no-interaction
COPY . .
RUN composer dump-autoload --no-dev --classmap-authoritative \
    && rm -rf .git .gitignore tests

FROM 1x.ax/mamluk/enterprise/php/8.5:franken

COPY --from=build /var/www /var/www
# Optional: your own Caddyfile. The default runs html/index.php as a worker on port 8080.
# COPY etc/caddy/Caddyfile /etc/frankenphp/Caddyfile
```

```bash
docker build --secret id=composer-auth,src=$HOME/.composer/auth.json -t my-api .
```

The code is owned by root and read-only to the server, so a compromised worker cannot change it. OPcache never
checks files for changes (`opcache.validate_timestamps = 0`), because they cannot change.

### What is different from the free image

* **Port 8080, not 80.** The server does not run as root, so it cannot bind ports below 1024. Map the port in
  your Service or `docker run -p 80:8080`.
* **Worker mode by default.** `FRANKENPHP_CONFIG` defaults to `worker /var/www/html/index.php`. Set it to an empty
  string to serve without a worker.
* **No programs to run.** `exec`, `shell_exec`, `system`, `passthru`, `popen`, `proc_open` and `pcntl_exec` are
  disabled, because there is nothing for them to run. The [Git driver](https://kipchak.dev/docs/driver-git)
  needs the `git` program and does not work in this image; use the Alpine variant.
* **The admin API is off.** The configuration never changes in a running container. Set `CADDY_ADMIN` to
  `localhost:2019` and `CADDY_GLOBAL_OPTIONS` to `metrics` for Prometheus metrics.
* **Plain HTTP, with HTTP/2.** TLS ends at your load balancer or ingress. The server speaks HTTP/1.1 and
  cleartext HTTP/2 (h2c), and manages no certificates.
* **No Mercure or Vulcain.** Caddy is built with only the modules an API needs.
* **No JIT.** OPcache's JIT is not available in musl builds. OPcache itself is.

### Adding programs

The `franken-alpine` variant is the same binary, with the same settings and the same non-root user, on Alpine
Linux. Alpine adds a shell and its package manager, so programs can be installed:

```dockerfile
FROM 1x.ax/mamluk/enterprise/php/8.5:franken-alpine

USER root
RUN apk add --no-cache git
USER 65532

COPY --from=build /var/www /var/www
```

The functions that start programs (`exec`, `proc_open` and the others) are enabled in this variant, by
`/etc/frankenphp/php.d/00-alpine.ini`. Everything else is as in the runtime image,
including the read-only filesystem and the restrictive Kubernetes settings below.

Use it only when an API needs a program. Each package installed is software to patch, and a shell is a tool for an
attacker. Extensions still cannot be added: they are compiled into the binary.

### Command-line scripts

Run PHP scripts, such as migrations or queue consumers, with the `php` CLI in the image. The image's entrypoint
is `frankenphp`, so name `php` as the entrypoint, or as the `command` of a Kubernetes container or Job:

```bash
docker run --rm --entrypoint php my-api /var/www/bin/console migrations:up
```

```yaml
command: ["php", "/var/www/bin/console", "migrations:up"]
```

Use `php` rather than `frankenphp php-cli`: before PHP 8.6, `frankenphp php-cli` puts its own path in `$argv[0]`,
so scripts that read their arguments, such as Composer and Symfony Console, misread them.

### Kubernetes

The image runs with the most restrictive pod security settings. Give it a writable `/tmp`:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
volumeMounts:
  - name: tmp
    mountPath: /tmp
# volumes:
#   - name: tmp
#     emptyDir: {}
```

With no shell in the image, use HTTP probes, and `kubectl debug` with an ephemeral container to inspect a running
pod.

### Settings

Add `.ini` files to `/etc/frankenphp/php.d/`, or use `php_ini` in the Caddyfile, rather than replacing
`/etc/frankenphp/php.ini`.

## Updates

* **PHP.** Each build looks up the latest release of its PHP version on php.net. The pipeline builds daily, so
  a new PHP release is in the images within a day.
* **Libraries and extensions.** Most of static-php-cli's recipes fetch the latest release of a library or
  extension. The first build of each ISO week (`SOURCES_EPOCH`, e.g. `2026-W41`) downloads them all again and
  compiles from scratch; later builds that week reuse that binary. A security release of OpenSSL, curl or any
  other library is therefore in the images within a week. The build log lists every version.
* **Pinned.** FrankenPHP, static-php-cli (v3) and SQLite are pinned in `Dockerfile`; update them deliberately. A new
  FrankenPHP release changes `FRANKENPHP_VERSION` and `FRANKENPHP_BUILDER` (its static builder image, by digest),
  and usually needs a newer `SPC_COMMIT`. static-php-cli's SQLite recipe names a 2024 release, so the build overrides
  it with `SQLITE_VERSION`, `SQLITE_ARCHIVE` and `SQLITE_SHA3`, checks the archive, and fails unless both binaries and
  both drivers report that version. It also enables SQLite's `dbstat` table, and fails unless a `dbstat` query works
  in both binaries and both drivers.
* **go-jose.** Caddy 2.11.9 reaches `go-jose/v3`, which has a High advisory and no fix, through its internal CA. The build
  requires `go.step.sm/crypto` 0.92.0 and `smallstep/certificates` at an unreleased commit, which use v4, and fails if v3
  is linked. The sources report reads the commit as behind until a release has it. The guard alerts when smallstep releases past the
  commit, or a Caddy release no longer needs v3, on the day of that release, and when FrankenPHP's own module no longer
  needs it; remove the pins then. `x/crypto` 0.58.0 is reported by scanners for its `openpgp` package; see the release notes.
* **What has fallen behind.** `check-sources.php` compares every library with upstream, straight after a fresh download,
  so whatever is still behind is pinned rather than waiting for the weekly refresh. The result is in each image, at
  `/usr/share/kipchak-runtime/sources-report.json`. The build fails on a library 18 months behind. The pipeline's
  `sources-guard` job reads the reports daily and fails, which alerts on Talk, on a library 6 months behind, on a lookup
  that failed, and on a report that is empty or more than 9 days old. Sources with no comparable version, such as those
  fetched from a git branch, are listed as `no comparable version`: they have not been checked.

## Licences

Each image holds the licence of what is in it, in `/usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/`:

* `libraries/`: each library and extension compiled in, from static-php-cli's `dump-license`.
* `go/`: each Go module linked into the binary, as the binary records them, with `MODULES.txt` listing their versions.
* `frankenphp/` and `debian-ca-certificates/`: FrankenPHP's own, and the CA certificates'.
* `alpine/` (Alpine image only): `PACKAGES.txt`, the installed packages and their licences, and each package's own
  licence files from its source archive. A package whose source has no licence file gets the standard text of its
  licence, with any notices from its file headers.
* `composer/` (build image only). The build image's Debian packages keep theirs in `/usr/share/doc`.

`LICENCE-SOURCES.txt`, beside them, says of each component whether its text is the project's original or not, and why
not. The build fails if a library, Go module or Alpine package has no text, or if one that should have an original does
not.

## Building

Concourse builds and pushes both PHP versions, for both architectures, from
`concourse-pipelines/pipelines/mamluk/kipchak-runtime.yml`: on every commit, and daily. To build by hand:

```bash
./build.sh            # PHP 8.4 and 8.5, both architectures, pushed
./build.sh 8.5        # one version
PUSH=0 ./build.sh 8.5 # build only
SOURCES_EPOCH=$(date +%s) ./build.sh # refresh the libraries now, rather than at the start of the week
```

`build.sh` also attaches an SBOM and provenance when it pushes. The pipeline, which publishes the images customers
receive, does not: its images are signed by digest, and carry no build attestations. Their contents are recorded in
`/usr/share/kipchak-runtime/`.

A plain `docker build` needs `--build-arg PHP_VERSION=8.5.11`, the exact release.

Each architecture compiles PHP and every library from source. Natively, on four cores, one PHP version takes
about 15 minutes; under emulation, several times longer. To build both natively, add a machine of the other
architecture to the builder, as described in `build.sh`.

static-php-cli downloads most library sources from GitHub, and GitHub allows 60 API requests an hour without a
token. `build.sh` uses `GITHUB_TOKEN`, or Composer's GitHub token if that is not set; the pipeline uses
`((github.composer_token))`. Sources are cached for the week.

## Rebuilding from the source set

Every build records what it was built from, and each published build's **source set** is kept on Mamluk's mirror,
`1x.ax/mamluk/kipchak-sources`, for as long as Mamluk offers the image (`NOTICE.md`). With it, `frankenphp` and `php` can be
rebuilt with nothing else reachable, including with a modified library. The image names its set in the
`org.kipchak.sources` label, for example `8.5.12-20261110-arm64`.

A set holds: static-php-cli at `SPC_COMMIT`, with its Composer packages; every source and toolchain archive the build
used, with static-php-cli's record of them (`downloads/`); the Go modules (`gomod/`); the CA certificates; the
exact Debian and Alpine source packages of the build and alpine images; `IMAGES.txt`, the images it was built with
and the Dockerfile frontend, by digest; and `SHA256SUMS`. The mirror keeps each of those images, whole, under the same
digest.

1. Fetch the set, with this recipe (in the image at `/usr/share/kipchak-runtime/source/recipe/`):

   ```bash
   ./fetch-sources.sh 8.5.12-20261111T0648-arm64 ./set   # the image's org.kipchak.sources label
   ```

2. To use a modified library, replace its archive in `set/downloads/` under the same name, and set its `hash` in
   `set/downloads/.cache.json` to the new file's SHA-1, which is how static-php-cli recognises a download as its own.
   For example, for libiconv:

   ```bash
   tar -czf set/downloads/libiconv-1.19.1.tar.gz libiconv-1.19.1   # your modified source
   hash="$(sha1sum set/downloads/libiconv-1.19.1.tar.gz | cut -d' ' -f1)"
   jq --arg h "${hash}" '.libiconv.source.hash = $h' set/downloads/.cache.json > cache.json \
       && mv cache.json set/downloads/.cache.json
   ```

3. Build with no network for any build step (`--network=none`), the set as the `sources` context, and every image
   from the mirror by the digests in `set/IMAGES.txt`:

   ```bash
   M=1x.ax/mamluk/kipchak-sources
   image() { echo "$M/$1@$(awk -v n="$1" '$1 == n { sub(/.*@/, "", $2); print $2 }' set/IMAGES.txt)"; }
   docker buildx build --network=none --no-cache --platform linux/arm64 --target runtime \
       --build-context sources=./set \
       --build-arg BUILDKIT_SYNTAX="$(image dockerfile)" \
       --build-arg FRANKENPHP_BUILDER="$(image builder)" \
       --build-arg DEBIAN_IMAGE="$(image debian)" \
       --build-arg ALPINE_IMAGE="$(image alpine)" \
       --build-arg COMPOSER_IMAGE="$(image composer)" \
       --build-arg PHP_VERSION=8.5.12 --build-arg SOURCES_EPOCH=rebuild \
       -t my-runtime .
   ```

   Sets published before 13 November 2026 have no `dockerfile` line: use the digest on the first line of the recipe's
   `Dockerfile` (`# syntax=docker/dockerfile:1@sha256:...`).

   With a set present, `build-frankenphp.sh` takes static-php-cli, every download and every Go module from it, and the
   network is never tried; the build fails if anything is missing. It still runs every check of a normal build. The
   lookups against upstream that only report how current the libraries are cannot run, and say so.

   Every set is checked this way before it, or any image built with it, is published: the `set-check` stage of the
   Dockerfile takes every download, Go, xcaddy and every Go module from the set with no network, and fails the build
   otherwise.

   **Sets labelled `8.4.27-20261111T0649` or `8.5.12-20261111T0648`.** These were published before xcaddy was pinned,
   and their recipe installs xcaddy from its master branch, which a set cannot answer offline. Before building from one
   of them, add the one file that says which version master meant (the set's own `v0.4.7`), then build as above:

   ```bash
   printf '{"Version":"v0.4.7"}\n' > set/gomod/github.com/caddyserver/xcaddy/@v/master.info
   ```

   The set itself is unchanged on the mirror, so its digest and `SHA256SUMS` still verify what you fetched.

The build and alpine images install packages from Debian and Alpine as they build; their exact source packages are
in the set, in `debian/` and `alpine/`, with the aports commit of each Alpine package in `alpine/COMMITS.txt`.
