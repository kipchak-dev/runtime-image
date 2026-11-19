# Kipchak Runtime Image

The recipe for the Kipchak Runtime Image: a hardened container image for running [Kipchak](https://kipchak.dev) APIs
in production. FrankenPHP and PHP are compiled from source into one static binary, and the image is that binary on an
empty filesystem, with no shell, no package manager and no root user. It is built for PHP 8.4 and 8.5, on
`linux/amd64` and `linux/arm64`.

The recipe is open source, under the [MIT licence](LICENSE). Pre-built, signed images with verified provenance are
included with [Kipchak Enterprise](https://kipchak.dev/docs/enterprise).

The image itself, its variants, how to use it and how to rebuild it are described in
[php-hardened/README.md](php-hardened/README.md). The open-source software it contains, and its licences, are listed
in [php-hardened/NOTICE.md](php-hardened/NOTICE.md).

## Building it yourself

Anyone may build the image from this recipe; see [Building](php-hardened/README.md#building). A build you make
yourself is equivalent to Mamluk's, but not identical to any particular one: static-php-cli resolves most library
sources to their latest release when the build runs, so a fresh build takes the upstream versions current on that day.
This recipe makes no claim of a reproducible build. To rebuild one of Mamluk's images exactly, use the source set that
image names (see [Rebuilding from the source set](php-hardened/README.md#rebuilding-from-the-source-set)).

## Mamluk's images

GitHub Actions builds this recipe on every commit to `master` and each week, into a private staging package. Before an
image is published, Mamluk checks the build's provenance, re-verifies every source it was built from against the
upstream projects, rebuilds the `linux/amd64` binary from those sources on its own builder and compares the result.
Only then is the image copied to Mamluk's registry and signed with Mamluk's key. Mamluk's signature therefore attests
a build checked against this recipe's provenance and against Mamluk's own rebuild.

Support under a Kipchak Enterprise Order covers Mamluk's signed images only, not images built from this recipe by
anyone else.

## Verifying Mamluk's images

Every published image is signed by digest with Mamluk's image signing key. Verify the signature with
[cosign](https://github.com/sigstore/cosign) and Mamluk's published key:

```
cosign verify --insecure-ignore-tlog --key https://bke.maml.uk/signing/bke-images-2026.pub 1x.ax/mamluk/enterprise/php/8.5:franken
```

Mamluk's signatures are not recorded in the public transparency log, by design, so `--insecure-ignore-tlog` is
required. The signature made with the published key is the primary verification.

Each image's build provenance, which names this repository, the workflow and the commit, is recorded with GitHub's
attestations. To check it for an image's digest:

```
gh attestation verify oci://1x.ax/mamluk/enterprise/php/8.5@sha256:<digest> --repo kipchak-dev/runtime-image
```

## Contributing

Pull requests opened on this repository are not merged. To report a problem or propose a change,
[contact Mamluk](https://mamluk.net/contact/). To report a security problem, contact Mamluk rather than opening a
public issue.

## Licence

The contents of this repository are released under the MIT licence. See [LICENSE](LICENSE). The software the image
contains is licensed under its own terms, listed in [php-hardened/NOTICE.md](php-hardened/NOTICE.md).
