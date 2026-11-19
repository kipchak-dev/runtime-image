#!/bin/sh
# Checks a source set's record of where each download came from (downloads/.download-urls) before the set is written.
# Every published set carries this file, and anyone can read it, so it may hold only public addresses (condition P5 of
# Amendment 1 to the kipchak-runtime-github plan). Mamluk's promote job uses it to download every archive again and
# compare it with the set's copy (A4).
#
#   check-download-urls.sh FILE
#
# Each line is: URL <tab> request headers, joined by " | " (may be empty) <tab> file name. The URL is the address the
# build requested, before any redirect. The check refuses:
#   - a URL that is not https://, or that has no host;
#   - a host that is Mamluk's own or not public: 1x.ax, *.maml.uk, *.mamluk.net, *.bahriya.cloud, *.bahriya.net,
#     localhost, *.local, *.internal, *.svc, an IP address;
#   - a query string that carries a credential or a signature (token, access_token, sig, signature, X-Amz-*,
#     X-Goog-*, Expires with a signature);
#   - a header that carries a credential (Authorization, Cookie, or any header naming a token or key);
#   - a line without exactly three fields, or a file name with a slash.
#
# Exit codes: 0 every line is public; 1 a line is refused (each refused line is named, with its reason); 2 no file.
set -u
FILE="${1:-}"
[ -f "$FILE" ] || { echo "check-download-urls: no file '$FILE'" >&2; exit 2; }

awk -F '\t' '
function refuse(why) { printf "check-download-urls: line %d refused (%s): %s\n", NR, why, $1; bad = 1 }
{
    if (NF != 3) { refuse("not three tab-separated fields"); next }
    url = $1; headers = $2; name = $3
    if (name == "" || name ~ /\//) { refuse("file name is empty or has a slash") }
    if (url !~ /^https:\/\/[^\/?#]+(\/|$)/) { refuse("not an https address with a host"); next }
    host = url; sub(/^https:\/\//, "", host); sub(/[\/?#].*$/, "", host); sub(/:[0-9]+$/, "", host)
    host = tolower(host)
    if (host ~ /@/) refuse("credentials in the address")
    if (host == "1x.ax" || host ~ /\.1x\.ax$/ || host ~ /(^|\.)maml\.uk$/ || host ~ /(^|\.)mamluk\.net$/ \
        || host ~ /(^|\.)bahriya\.(cloud|net)$/ || host == "localhost" || host ~ /\.(local|internal|svc|localdomain)$/ \
        || host ~ /^[0-9.]+$/ || host ~ /^\[/) refuse("not a public host: " host)
    q = ""; if (index(url, "?") > 0) q = tolower(substr(url, index(url, "?") + 1))
    if (q ~ /(^|&)(token|access_token|auth|sig|signature|x-amz-[a-z-]*|x-goog-[a-z-]*|key)=/) refuse("a credential or signature in the query")
    if (tolower(headers) ~ /(^| \| )(authorization|cookie|proxy-authorization|[a-z-]*(token|key|secret)[a-z-]*):/) refuse("a credential in the headers")
}
END { exit bad }
' "$FILE" || { echo "check-download-urls: $FILE holds an address that may not be published" >&2; exit 1; }
echo "check-download-urls: $(grep -c . "$FILE" | tr -d ' ') addresses, all public"
