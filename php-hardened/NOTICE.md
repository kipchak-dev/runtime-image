# Notice: open-source software in this image

This image is the Kipchak Runtime Image published by Mamluk. It contains open-source software that is licensed to
you under its own licence, not under the terms on which Mamluk supplied the image. Those licences and the notices
that come with them are in `/usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/`, and the version of every component
is in `/usr/share/kipchak-runtime/sources.txt`. Nothing in the terms on which Mamluk supplied this image limits,
conditions or adds to the rights those licences give you.

## Libraries under the GNU Lesser General Public License

The programs `/usr/local/bin/frankenphp` and `/usr/local/bin/php` are statically linked with these libraries:

| Library | Version | Licence |
|---|---|---|
| libintl, from GNU gettext | 1.0 | GNU LGPL, version 2.1 or (at your option) any later version |
| libiconv, from GNU libiconv | 1.19.1 | GNU LGPL, version 2.1 or (at your option) any later version |
| libcharset, from GNU libiconv | 1.19.1 | GNU LGPL, version 2 or (at your option) any later version |
| GNU MP (libgmp) | 6.3.0 | GNU LGPL, version 3 |

GNU MP is offered under the GNU LGPL version 3 or the GNU GPL version 2 or later. Mamluk uses it under the GNU LGPL
version 3.

No other part of GNU gettext or GNU libiconv is in these programs: not the gettext tools, and not the `iconv`
program.

You may modify these libraries, rebuild the two programs with your modified version, and reverse engineer the
programs to the extent needed to debug such modifications.

To let you do so, this image contains:

- the complete build recipe for the two programs, in `/usr/share/kipchak-runtime/source/recipe/`, with the
  instructions for rebuilding them with a modified library in its `README.md`;
- the source archives of the four libraries named above, exactly as built, in
  `/usr/share/kipchak-runtime/source/libraries/`.

Every other source the recipe uses, at the exact versions this image was built from, is kept by Mamluk at
`1x.ax/mamluk/kipchak-sources` for as long as Mamluk offers this image. The recipe can rebuild the programs from that copy
alone.

## Programs under the GNU General Public License and the Mozilla Public License

Some variants of this image also contain separate programs and data that are not linked with the two programs above:

- the Alpine variant (`franken-alpine`): BusyBox, apk-tools and pax-utils, under the GNU GPL version 2, and the
  Alpine packages listed in `/usr/share/kipchak-runtime/THIRD-PARTY-LICENCES/alpine/`;
- the build variant (`franken-build`): the Debian packages of its base system, under their own licences, including
  the GNU GPL;
- every variant: the certificate bundle from the Debian or Alpine `ca-certificates` package, under the Mozilla Public
  License 2.0.

The exact source packages for the versions in each variant are kept by Mamluk at `1x.ax/mamluk/kipchak-sources` for as long as
Mamluk offers the image.

## Contact

For anything further that one of these licences entitles you to, write to Mamluk at Mamluk LLC-FZ, Meydan
Grandstand, 6th Floor, Meydan Road, Nad Al Sheba, Dubai, United Arab Emirates (Meydan Free Zone, Company
Registration No. 2652439).
