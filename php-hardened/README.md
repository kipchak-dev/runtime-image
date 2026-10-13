# Hardened Kipchak runtime

A FrankenPHP image for running Kipchak APIs in production, for PHP 8.4 and 8.5, on `linux/amd64` and
`linux/arm64`. It is part of Kipchak Enterprise.

FrankenPHP and PHP are built from source into one static binary, linked against musl with mimalloc as the
allocator. The image is that binary on an empty filesystem (`FROM scratch`), with:

* CA certificates, `php.ini` and a Caddyfile;
* a non-root user (`65532`), which runs the server;
* `/tmp`, the only directory the runtime user can write to. PHP and Caddy keep their temporary files there.

It has no shell, no package manager, no libc and no other programs, so an attacker who gets code execution has
nothing to run. The image is 187 MB, against about 2 GB for the free `franken` image.

Vulnerability scanners see the Go modules in the binary (Caddy and FrankenPHP), but not the C libraries compiled
into it, such as OpenSSL, curl and librdkafka. Instead, the images are rebuilt with the latest release of every
library once a week (see [Updates](#updates)), and each image lists the versions it contains.

`<registry>/<repository>` below stands for the image repository, which is not set up yet.

| Tag | Use |
| --- | --- |
| `<registry>/<repository>:8.5` | Runtime, the latest PHP 8.5 release |
| `<registry>/<repository>:8.5.11` | Runtime, pinned to a PHP release |
| `<registry>/<repository>:8.5-build` | Build stage and CI: the same PHP with Composer, git and a shell |
| `<registry>/<repository>:8.5.11-build` | The build image, pinned to a PHP release |
| `<registry>/<repository>:8.4`, ... | The same for PHP 8.4 |

## Extensions

The extensions are compiled in and cannot be added later. They are:

apcu, bcmath, calendar, ctype, curl, dom, exif, fileinfo, filter, gd, gettext, gmp, iconv, igbinary, intl, ldap,
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
FROM <registry>/<repository>:8.5-build AS build

COPY composer.json composer.lock ./
RUN --mount=type=secret,id=composer-auth,target=/root/.composer/auth.json \
    composer install --no-dev --no-scripts --no-autoloader --no-interaction
COPY . .
RUN composer dump-autoload --no-dev --classmap-authoritative \
    && rm -rf .git .gitignore tests

FROM <registry>/<repository>:8.5

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
  needs the `git` program and does not work in this image.
* **The admin API is off.** The configuration never changes in a running container. Set `CADDY_ADMIN` to
  `localhost:2019` and `CADDY_GLOBAL_OPTIONS` to `metrics` for Prometheus metrics.
* **Plain HTTP, with HTTP/2.** TLS ends at your load balancer or ingress. The server speaks HTTP/1.1 and
  cleartext HTTP/2 (h2c), and manages no certificates.
* **No Mercure or Vulcain.** Caddy is built with only the modules an API needs.
* **No JIT.** OPcache's JIT is not available in musl builds. OPcache itself is.

### Command-line scripts

Run PHP scripts, such as migrations or queue consumers, with FrankenPHP's CLI:

```bash
docker run --rm my-api php-cli /var/www/bin/console migrations:up
```

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
* **Pinned.** FrankenPHP and static-php-cli are pinned in `Dockerfile`; update them deliberately. A new FrankenPHP
  release changes `FRANKENPHP_VERSION`, and usually needs a newer `SPC_COMMIT`. A few of static-php-cli's recipes
  pin a version themselves (SQLite and protobuf, for example), and change only with `SPC_COMMIT`.

## Building

Concourse builds and pushes both PHP versions, for both architectures, from
`concourse-pipelines/pipelines/mamluk/kipchak-runtime.yml`: on every commit, and daily. To build by hand:

```bash
IMAGE=<registry>/<repository> ./build.sh            # PHP 8.4 and 8.5, both architectures, pushed with an SBOM and provenance
IMAGE=<registry>/<repository> ./build.sh 8.5        # one version
IMAGE=<registry>/<repository> PUSH=0 ./build.sh 8.5 # build only
SOURCES_EPOCH=$(date +%s) IMAGE=... ./build.sh      # refresh the libraries now, rather than at the start of the week
```

A plain `docker build` needs `--build-arg PHP_VERSION=8.5.11`, the exact release.

Each architecture compiles PHP and every library from source. Natively, on four cores, one PHP version takes
about 15 minutes; under emulation, several times longer. To build both natively, add a machine of the other
architecture to the builder, as described in `build.sh`.

static-php-cli downloads most library sources from GitHub, and GitHub allows 60 API requests an hour without a
token. `build.sh` uses `GITHUB_TOKEN`, or Composer's GitHub token if that is not set; the pipeline uses
`((github.composer_token))`. Sources are cached for the week.
