#!/usr/bin/env bash
# Runs in the static-php-cli directory after build-frankenphp.sh, as its own build step, so that a failure here does not
# throw away the compile. Everything in it can fail the build.
set -euo pipefail

: "${SQLITE_VERSION:?SQLITE_VERSION is required}" "${SQLITE_ARCHIVE:?SQLITE_ARCHIVE is required}" "${SQLITE_SHA3:?SQLITE_SHA3 is required}"
FRANKENPHP_SOURCE_PATH=/go/src/app
cd "${FRANKENPHP_SOURCE_PATH}/dist/static-php-cli"

if [ -f /run/secrets/github_token ]; then
	GITHUB_TOKEN="$(cat /run/secrets/github_token)"
	export GITHUB_TOKEN
fi

# The SQLite archive must be the one sqlite.org publishes, and both binaries and both drivers must report that version.
sqlite_archive="downloads/$(basename "${SQLITE_ARCHIVE}")"
sqlite_sha3="$(php -n -r 'echo hash_file("sha3-256", $argv[1]);' "${sqlite_archive}")"
[ "${sqlite_sha3}" = "${SQLITE_SHA3}" ] \
	|| { echo "${sqlite_archive} has SHA3-256 ${sqlite_sha3}, expected ${SQLITE_SHA3}" >&2; exit 1; }
sqlite_probe='echo SQLite3::version()["versionString"], " ", (new PDO("sqlite::memory:"))->query("select sqlite_version()")->fetchColumn();'
for reported in "$(/out/php -n -r "${sqlite_probe}")" "$(/out/frankenphp php-cli -r "${sqlite_probe}")"; do
	[ "${reported}" = "${SQLITE_VERSION} ${SQLITE_VERSION}" ] \
		|| { echo "Expected SQLite ${SQLITE_VERSION} in sqlite3 and pdo_sqlite, the binary reports: ${reported}" >&2; exit 1; }
done
# A real dbstat query, as the option being set says nothing about whether it reached the library each driver uses.
dbstat_probe='$sqlite3 = new SQLite3(":memory:"); $sqlite3->exec("create table t(x)"); $pdo = new PDO("sqlite::memory:"); $pdo->exec("create table t(x)"); echo $sqlite3->querySingle("select count(*) > 0 from dbstat"), " ", $pdo->query("select count(*) > 0 from dbstat")->fetchColumn();'
for reported in "$(/out/php -n -r "${dbstat_probe}" 2>&1)" "$(/out/frankenphp php-cli -r "${dbstat_probe}" 2>&1)"; do
	[ "${reported}" = '1 1' ] \
		|| { echo "Expected dbstat in sqlite3 and pdo_sqlite, the binary reports: ${reported}" >&2; exit 1; }
done

# The pins that take the binary off go-jose/v3 must have reached it, and v3 must not have.
go=/opt/spc-pkgroot/go-xcaddy/bin/go
"${go}" version -m /out/frankenphp | awk '$1 == "dep" { print $2, $3 }' > /tmp/go-modules.txt
grep -q "^go.step.sm/crypto ${STEP_CRYPTO_VERSION}\$" /tmp/go-modules.txt \
	|| { echo "go.step.sm/crypto is not at ${STEP_CRYPTO_VERSION}" >&2; exit 1; }
grep -q "^github.com/smallstep/certificates ${STEP_CERTIFICATES_VERSION}\$" /tmp/go-modules.txt \
	|| { echo "smallstep/certificates is not at ${STEP_CERTIFICATES_VERSION}" >&2; exit 1; }
if grep -q '^github.com/go-jose/go-jose/v3 ' /tmp/go-modules.txt; then
	echo 'go-jose/v3 is linked into the binary again.' >&2
	exit 1
fi

# Anything still behind upstream straight after a fresh download is pinned, so the weekly refresh will not move it.
echo "--- Compared with upstream"
artifacts="$(jq -r 'to_entries[] | select(.value.source != null) | .key' /out/sources.lock.json | paste -sd, -)"
# A failed check-update reads as failed lookups in the report, which the guard alerts on. The log says why, without the token.
if ! ./bin/spc check-update "${artifacts}" --json --no-motd 2> /tmp/check-update.err > /tmp/check-update.json \
	|| ! jq -e . /tmp/check-update.json > /dev/null 2>&1; then
	echo 'check-update failed, so its lookups will read as failed:'
	cat /tmp/check-update.err /tmp/check-update.json | sed -e "s#${GITHUB_TOKEN:-\$^}#***#g" | tail -n 20 | cut -c1-300
	echo '{}' > /tmp/check-update.json
fi
php -n /usr/local/bin/check-sources.php report /out/sources.lock.json /tmp/check-update.json downloads /out/sources-report.json config/pkg /tmp/go-modules.txt

# The licence of everything compiled in. Copyright notices must survive, so a licence file comes from the project's own
# source wherever one exists. LICENCE-SOURCES.txt says of every component where its text came from.
echo "--- Licences"
licences=/out/THIRD-PARTY-LICENCES
mkdir -p "${licences}/libraries" "${licences}/go" "${licences}/frankenphp"
record="${licences}/LICENCE-SOURCES.txt"
: > "${record}"
missing=0
# With anything before the word too: github.com/elnormous/contenttype has an UNLICENSE.
licence_files=(-iname '*LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*')

./bin/spc dump-license "${artifacts}" --dump-dir="${licences}/libraries" 2>&1 | tail -n 5
while read -r artifact; do
	# static-php-cli keeps its own copy of a few licences ('@/gmp.txt'). Prefer the file in the project's source.
	recipe="$(grep -rl "^${artifact}:" config/pkg 2> /dev/null | head -n 1 || true)"
	if [ -n "${recipe}" ] && sed -n "/^${artifact}:/,/^[a-z]/p" "${recipe}" | grep -q "license-files:.*@/"; then
		found="$(find "source/${artifact}" -maxdepth 1 -type f \( "${licence_files[@]}" \) 2> /dev/null || true)"
		if [ -n "${found}" ]; then
			rm -f "${licences}/libraries/${artifact}"_LICENSE*.txt
			printf '%s\n' "${found}" | while read -r file; do cp "${file}" "${licences}/libraries/${artifact}_LICENSE_$(basename "${file}").txt"; done
			echo "library ${artifact} original" >> "${record}"
		elif [ "${artifact}" = sqlite ]; then
			# SQLite is public domain and its archive has no licence file.
			echo "library ${artifact} recipe-copy: public domain, its source has no licence file" >> "${record}"
		else
			echo "No licence file in the source of ${artifact}, only static-php-cli's own copy." >&2
			missing=1
		fi
	else
		echo "library ${artifact} original" >> "${record}"
	fi
	# A recipe's file may not be where dump-license looks (llvm-compiler-rt). The shallowest in the downloaded archive.
	if ! find "${licences}/libraries" -name "${artifact}_LICENSE*.txt" -type f -size +0 | grep -q .; then
		archive="downloads/$(jq -r --arg name "${artifact}" '.[$name].source.filename // empty' /out/sources.lock.json)"
		if [ -f "${archive}" ]; then
			inside="$(tar -tf "${archive}" 2> /dev/null | grep -iE '/(LICEN[CS]E|COPYING)[^/]*$' | awk -F/ '{ print NF, $0 }' | sort -n | head -n 1 | cut -d' ' -f2- || true)"
			[ -z "${inside}" ] || tar -xOf "${archive}" "${inside}" > "${licences}/libraries/${artifact}_LICENSE.txt"
		fi
	fi
	if ! find "${licences}/libraries" -name "${artifact}_LICENSE*.txt" -type f -size +0 | grep -q .; then
		echo "No licence text for ${artifact}" >&2
		missing=1
	fi
done < <(jq -r 'to_entries[] | select(.value.source != null) | .key' /out/sources.lock.json | grep -v '^frankenphp$')

# FrankenPHP's own, which is not among the sources static-php-cli can dump.
cp "${FRANKENPHP_SOURCE_PATH}/LICENSE" "${licences}/frankenphp/" && echo "library frankenphp original" >> "${record}" || missing=1

# The Go modules actually linked into the binary, from the binary's own record.
cd "${FRANKENPHP_SOURCE_PATH}/caddy"
while read -r module version; do
	directory="$("${go}" mod download -json "${module}@${version}" | jq -r '.Dir // empty')"
	target="${licences}/go/$(printf '%s' "${module}" | tr '/' '_')"
	mkdir -p "${target}"
	found="$(find "${directory:-/nonexistent}" -maxdepth 1 -type f \( "${licence_files[@]}" \) 2> /dev/null || true)"
	if [ -z "${found}" ]; then
		echo "No licence text for Go module ${module} ${version}" >&2
		missing=1
	else
		printf '%s\n' "${found}" | xargs -I{} cp {} "${target}/"
		printf '%s %s\n' "${module}" "${version}" >> "${licences}/go/MODULES.txt"
		echo "go ${module} original" >> "${record}"
	fi
done < <("${go}" version -m /out/frankenphp | awk '$1 == "dep" || $1 == "mod" { print $2, $3 }' | grep -v ' (devel)$')
[ -s "${licences}/go/MODULES.txt" ] || { echo 'The binary lists no Go modules.' >&2; missing=1; }

printf 'Licence texts: %s original, %s not original\n' "$(grep -c ' original$' "${record}" || true)" "$(grep -vc ' original$' "${record}" || true)"
grep -v ' original$' "${record}" || true
[ "${missing}" = 0 ]
