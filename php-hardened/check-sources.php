<?php

declare(strict_types=1);

/**
 * Whether the libraries compiled into the runtime have fallen behind their upstream releases.
 *
 * static-php-cli fetches the latest release of most libraries, but a recipe can pin one, as its SQLite recipe does, and
 * then the weekly refresh never moves it and no scanner sees it. The build runs this straight after downloading the
 * sources, so whatever is still behind is pinned rather than waiting for a refresh.
 *
 *   php check-sources.php report <sources.lock.json> <check-update.json> <downloads dir> <report.json> <recipes dir> <go modules>
 *       Writes the report. Fails if anything is behind by the failure margin. A lookup that fails is recorded rather
 *       than fatal, so that a hiccup at GitHub does not throw away hours of compiling; the alert below then fires.
 *   php check-sources.php alert <report.json>
 *       Fails if anything needs attention: behind by the alert margin, a lookup that failed, a report that is empty
 *       or stale, or news that a pin can go. The pipeline runs this each day, so that a failure reaches Talk.
 *
 * A lookup that fails is never counted as current. What has no comparable version is listed as such, so that nobody
 * reads it as checked.
 *
 * A RECIPE'S OWN LOOKUP IS NOT ENOUGH. It finds the newest release its pattern matches, so a pattern that stops matching
 * reports an old release as the latest: ICU's looked for -src.tgz after the archive became -sources.tgz, and 77.1 read as
 * current with 79.1 out. So every source fetched from GitHub releases is also compared with the project's latest release.
 * That also shows a library on an older line by the recipe's choice, such as OpenSSL 3; its age says whether that matters,
 * because a line still being patched has recent files.
 */

const ALERT_MONTHS = 6;
const FAIL_MONTHS = 18;
const STALE_DAYS = 9;

const CURRENT = 'current';
const BEHIND = 'behind';
const NOT_COMPARABLE = 'no comparable version';
const LOOKUP_FAILED = 'lookup failed';

// Go modules pinned by hand to leave go-jose/v3 behind, in the build's own arguments.
const GO_PINS = ['go.step.sm/crypto', 'github.com/smallstep/certificates'];

/**
 * @param array<string, array<string, mixed>> $lock static-php-cli's downloads/.cache.json
 * @param array<string, array<string, mixed>> $updates spc check-update --json, by artifact
 * @param array<string, float|null> $ages months since each source file's release, by artifact
 * @return list<array<string, mixed>>
 */
function classify(array $lock, array $updates, array $ages): array
{
    $entries = [];
    foreach ($lock as $name => $artifact) {
        if (!is_array($artifact['source'] ?? null)) {
            continue;
        }
        $update = $updates[$name] ?? null;
        $entry = ['name' => $name, 'file' => $artifact['source']['filename'] ?? $artifact['source']['dirname'] ?? null, 'ours' => $update['old'] ?? null, 'newest' => $update['new'] ?? null, 'age_months' => $ages[$name] ?? null];
        $entry['prerelease'] = isPrerelease($entry['ours'] ?? $entry['file']);
        $entry['status'] = match (true) {
            !is_array($update) => LOOKUP_FAILED,
            (bool) ($update['unsupported'] ?? false) => NOT_COMPARABLE,
            ($update['new'] ?? null) === null || ($update['new'] ?? '') === '' => LOOKUP_FAILED,
            (bool) ($update['need-update'] ?? false) => BEHIND,
            default => CURRENT,
        };
        $entries[] = $entry;
    }

    return $entries;
}

/**
 * Whether a version is a release candidate, alpha or beta, so that the report says so.
 */
function isPrerelease(?string $version): bool
{
    return $version !== null && preg_match('/\d[._-]?(?:alpha|beta|rc)[._-]?\d*(?:\.[a-z.]+)*$/i', $version) === 1;
}

/**
 * A hand-pinned Go module. An unreleased commit is never current: it reads as behind, with the age of that commit, so that it
 * alerts and then fails on the same margins as any other pin, and is replaced as soon as a release has it.
 *
 * @param string|false $latest the module's latest release from the Go proxy; false when the proxy could not say
 * @return array<string, mixed>
 */
function goPinEntry(string $module, ?string $ours, string|false $latest, int $now): array
{
    $entry = ['name' => "go:{$module}", 'file' => null, 'ours' => $ours, 'newest' => $latest === false ? null : $latest, 'age_months' => null, 'prerelease' => false, 'unreleased' => false];
    if ($ours === null || $latest === false) {
        return ['status' => LOOKUP_FAILED] + $entry;
    }
    if (preg_match('/-(?:0\.)?(\d{14})-[0-9a-f]{12}$/', $ours, $commit) === 1) {
        $at = DateTimeImmutable::createFromFormat('YmdHis', $commit[1], new DateTimeZone('UTC'));

        return ['status' => BEHIND, 'unreleased' => true, 'age_months' => $at === false ? null : round(($now - $at->getTimestamp()) / (30.44 * 86400), 1)] + $entry;
    }

    return ['status' => version_compare(ltrim($latest, 'v'), ltrim($ours, 'v'), '>') ? BEHIND : CURRENT] + $entry;
}

/**
 * A module's latest release from the Go proxy, with when it was published. False when it could not say.
 *
 * @return array{Version: string, Time: string}|false
 */
function goLatestRelease(string $module): array|false
{
    $body = @file_get_contents("https://proxy.golang.org/{$module}/@latest", false, stream_context_create(['http' => ['timeout' => 20]]));
    $release = is_string($body) ? json_decode($body, true) : null;

    return is_string($release['Version'] ?? null) && $release['Version'] !== '' ? ['Version' => $release['Version'], 'Time' => (string) ($release['Time'] ?? '')] : false;
}

function goLatest(string $module): string|false
{
    return goLatestRelease($module)['Version'] ?? false;
}

/**
 * The go.mod of a module's release. False when the proxy could not say.
 */
function goModOf(string $module, string $version): string|false
{
    return @file_get_contents("https://proxy.golang.org/{$module}/@v/{$version}.mod", false, stream_context_create(['http' => ['timeout' => 20]]));
}

/**
 * What says an unreleased pin should now be removed: a smallstep release past the pinned commit, or a Caddy release that no
 * longer needs go-jose/v3. Said once per release: only within a day of its publication, because the job runs daily and keeps
 * no state. A run it misses is caught by the build's own notice and by the six and eighteen month margins.
 *
 * @param list<array<string, mixed>> $entries
 * @param callable(string): (array{Version: string, Time: string}|false) $release
 * @param callable(string, string): (string|false) $mod
 * @return list<string>
 */
function pinNews(array $entries, int $now, callable $release, callable $mod): array
{
    $fresh = static fn (string $time): bool => $time !== '' && strtotime($time) !== false && $now - (int) strtotime($time) < 25 * 3600;
    $news = [];
    $pinned = false;
    foreach ($entries as $entry) {
        if (!(bool) ($entry['unreleased'] ?? false)) {
            continue;
        }
        $pinned = true;
        $module = substr((string) $entry['name'], 3);
        $latest = $release($module);
        if ($latest === false) {
            $news[] = "Could not ask the Go proxy about {$module}, whose pin is an unreleased commit.";
            continue;
        }
        $base = preg_replace('/-.*$/', '', (string) $entry['ours']);
        if (version_compare(ltrim($latest['Version'], 'v'), ltrim((string) $base, 'v'), '>=') && $fresh($latest['Time'])) {
            $news[] = "{$module} released {$latest['Version']}, past the pinned commit {$entry['ours']}: remove the unreleased pin in the Dockerfile.";
        }
    }
    if (!$pinned) {
        return $news;
    }
    $caddy = $release('github.com/caddyserver/caddy/v2');
    $goMod = $caddy === false ? false : $mod('github.com/caddyserver/caddy/v2', $caddy['Version']);
    if ($caddy === false || $goMod === false) {
        $news[] = 'Could not ask the Go proxy about Caddy, whose go-jose/v3 dependency the pins exist for.';
    } elseif (!str_contains($goMod, 'github.com/go-jose/go-jose/v3') && $fresh($caddy['Time'])) {
        $news[] = "Caddy {$caddy['Version']} no longer needs go-jose/v3: take that release through FrankenPHP and remove the pins in the Dockerfile.";
    }

    return $news;
}
/**
 * The comparable part of a version or tag, dotted: release-79.1, REL_18_6 and curl-8_23_0 become 79.1, 18.6 and 8.23.0.
 */
function versionOf(?string $tag): ?string
{
    return $tag !== null && preg_match('/\d+(?:[._-]\d+)*/', $tag, $found) === 1 ? (string) preg_replace('/[_-]/', '.', $found[0]) : null;
}

/**
 * A recipe's answer corrected by the project's latest release.
 *
 * @param array<string, mixed> $update
 * @return array<string, mixed>
 */
function correctedByLatestRelease(array $update, ?string $latest): array
{
    $ours = versionOf($update['old'] ?? null);
    $newest = versionOf($latest);
    if ($ours === null || $newest === null || !version_compare($newest, $ours, '>')) {
        return $update;
    }

    return ['need-update' => true, 'new' => $latest] + $update;
}

/**
 * The GitHub repository a recipe fetches its releases from, or null when it does not.
 */
function releaseRepository(string $recipes, string $name): ?string
{
    $file = "{$recipes}/lib/{$name}.yml";
    $file = is_file($file) ? $file : "{$recipes}/ext/{$name}.yml";
    $recipe = is_file($file) ? (string) file_get_contents($file) : '';

    return preg_match('/^\s+type: ghrel\s*\n\s+repo: (\S+)/m', $recipe, $found) === 1 ? $found[1] : null;
}

/**
 * The tag of a repository's latest release. Null when it has no releases; false when GitHub could not say.
 */
function latestRelease(string $repository): string|false|null
{
    $token = (string) getenv('GITHUB_TOKEN');
    $context = stream_context_create(['http' => [
        'ignore_errors' => true,
        'timeout' => 20,
        'header' => "User-Agent: kipchak-runtime\r\nAccept: application/vnd.github+json\r\n" . ($token === '' ? '' : "Authorization: Bearer {$token}\r\n"),
    ]]);
    $body = @file_get_contents("https://api.github.com/repos/{$repository}/releases/latest", false, $context);
    $status = http_get_last_response_headers()[0] ?? null;
    if ($body === false || $status === null) {
        return false;
    }
    if (str_contains($status, ' 404')) {
        return null;
    }
    $tag = json_decode($body, true)['tag_name'] ?? null;

    return is_string($tag) && $tag !== '' ? $tag : false;
}

/**
 * A library behind its upstream with no known age needs attention at the alert margin, not silence.
 *
 * @param array<string, mixed> $entry
 */
function pastFailureMargin(array $entry): bool
{
    return $entry['status'] === BEHIND && $entry['age_months'] !== null && $entry['age_months'] >= FAIL_MONTHS;
}

/**
 * @param array<string, mixed> $entry
 */
function needsAttention(array $entry): bool
{
    return $entry['status'] === LOOKUP_FAILED
        || ($entry['status'] === BEHIND && ($entry['age_months'] === null || $entry['age_months'] >= ALERT_MONTHS));
}

/**
 * @param array<string, mixed>|null $report
 * @return list<string> what needs attention; empty when nothing does
 */
function problems(?array $report, int $now): array
{
    if ($report === null || !is_array($report['entries'] ?? null) || $report['entries'] === []) {
        return ['The report is missing or empty, so nothing was checked.'];
    }
    $problems = [];
    if (($now - (int) ($report['generated'] ?? 0)) > STALE_DAYS * 86400) {
        $problems[] = 'The report is older than ' . STALE_DAYS . ' days, so the weekly build has not run.';
    }
    $checked = array_filter($report['entries'], static fn (array $entry): bool => $entry['status'] === CURRENT || $entry['status'] === BEHIND);
    if ($checked === []) {
        $problems[] = 'No library could be compared with upstream.';
    }
    if ((bool) ($report['pins_unnecessary'] ?? false)) {
        $problems[] = 'FrankenPHP no longer needs go-jose/v3 by itself: remove the pins in the Dockerfile.';
    }
    foreach ($report['entries'] as $entry) {
        if (needsAttention($entry)) {
            $problems[] = "{$entry['name']}: {$entry['status']} (ours " . ($entry['ours'] ?? $entry['file'] ?? '?') . ', newest ' . ($entry['newest'] ?? '?') . ', ' . ($entry['age_months'] ?? '?') . ' months old)';
        }
    }

    return $problems;
}

/**
 * Months since the newest file in a source archive, which is close to the date it was released.
 */
function ageInMonths(string $file, int $now): ?float
{
    if (!is_file($file)) {
        return null;
    }
    $listing = str_ends_with($file, '.zip')
        ? shell_exec('unzip -l ' . escapeshellarg($file) . ' 2>/dev/null')
        : shell_exec('tar --list --verbose --full-time -f ' . escapeshellarg($file) . ' 2>/dev/null');
    if (!is_string($listing) || preg_match_all('/\b(20\d\d-\d\d-\d\d)\b/', $listing, $dates) === 0) {
        return null;
    }
    $newest = max(array_filter(array_map('strtotime', $dates[1]), static fn ($date): bool => $date !== false && $date <= $now));

    return round(($now - $newest) / (30.44 * 86400), 1);
}

/**
 * The newest SQLite from the machine-readable row of sqlite.org's download page. Its recipe is a fixed URL, which
 * static-php-cli cannot check. Null when the page cannot be read.
 *
 * @return array{need-update: bool, unsupported: bool, old: string, new: string}|null
 */
function sqliteUpdate(string $ours): ?array
{
    $page = @file_get_contents('https://www.sqlite.org/download.html');
    if ($page === false || preg_match('/^PRODUCT,[^,]+,\d{4}\/sqlite-autoconf-(\d{7})\.tar\.gz,/m', $page, $row) !== 1) {
        return null;
    }

    return ['need-update' => (int) $row[1] > (int) $ours, 'unsupported' => false, 'old' => $ours, 'new' => $row[1]];
}

if (realpath($argv[0] ?? '') !== __FILE__) {
    return;
}

$now = time();
switch ($argv[1] ?? '') {
    case 'report':
        [, , $lockFile, $updatesFile, $downloads, $reportFile, $recipes, $goModules] = $argv + [6 => '', 7 => ''];
        $lock = json_decode((string) file_get_contents($lockFile), true);
        $updates = json_decode((string) file_get_contents($updatesFile), true);
        if (!is_array($lock) || $lock === []) {
            fwrite(STDERR, "The source list is empty, so nothing can be checked.\n");
            exit(1);
        }
        $updates = is_array($updates) ? $updates : [];
        $ages = [];
        foreach ($lock as $name => $artifact) {
            $filename = is_array($artifact['source'] ?? null) ? ($artifact['source']['filename'] ?? null) : null;
            $ages[$name] = is_string($filename) ? ageInMonths("{$downloads}/{$filename}", $now) : null;
            if ($name === 'sqlite' && is_string($filename) && preg_match('/autoconf-(\d{7})/', $filename, $ours) === 1) {
                $updates[$name] = sqliteUpdate($ours[1]);
            }
            $repository = releaseRepository($recipes, (string) $name);
            if ($repository !== null && is_array($updates[$name] ?? null) && !(bool) ($updates[$name]['unsupported'] ?? false)) {
                $latest = latestRelease($repository);
                if ($latest === false) {
                    unset($updates[$name]);
                } else {
                    $updates[$name] = correctedByLatestRelease($updates[$name], $latest);
                }
            }
        }
        $entries = classify($lock, array_filter($updates), $ages);
        $linked = [];
        foreach (is_file($goModules) ? (array) file($goModules, FILE_IGNORE_NEW_LINES) : [] as $line) {
            [$module, $version] = explode(' ', (string) $line) + [1 => null];
            $linked[$module] = $version;
        }
        foreach ($goModules === '' ? [] : GO_PINS as $module) {
            $entries[] = goPinEntry($module, $linked[$module] ?? null, goLatest($module), $now);
        }
        file_put_contents($reportFile, json_encode(['generated' => $now, 'alert_months' => ALERT_MONTHS, 'fail_months' => FAIL_MONTHS, 'pins_unnecessary' => is_file(dirname($reportFile) . '/go-pins-unnecessary'), 'entries' => $entries], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
        foreach ($entries as $entry) {
            printf("%-22s %-22s %s -> %s, %s months%s\n", $entry['name'], $entry['status'], $entry['ours'] ?? '?', $entry['newest'] ?? '?', $entry['age_months'] ?? '?', ($entry['prerelease'] ? ', A PRERELEASE' : '') . (($entry['unreleased'] ?? false) ? ', AN UNRELEASED COMMIT' : ''));
        }
        $past = array_values(array_filter($entries, 'pastFailureMargin'));
        foreach ($past as $entry) {
            fwrite(STDERR, "{$entry['name']} is {$entry['age_months']} months old and behind {$entry['newest']}: past the " . FAIL_MONTHS . " month margin. Update it, or override its recipe in build-frankenphp.sh.\n");
        }
        exit($past === [] ? 0 : 1);
    case 'alert':
        $report = json_decode((string) @file_get_contents($argv[2] ?? ''), true);
        $problems = problems(is_array($report) ? $report : null, $now);
        if (is_array($report) && is_array($report['entries'] ?? null)) {
            $problems = [...$problems, ...pinNews($report['entries'], $now, goLatestRelease(...), goModOf(...))];
        }
        foreach ($problems as $problem) {
            fwrite(STDERR, $problem . "\n");
        }
        echo $problems === [] ? "Sources are within their margins.\n" : '';
        exit($problems === [] ? 0 : 1);
    default:
        fwrite(STDERR, "Usage: php check-sources.php report <lock> <updates> <downloads> <report> | alert <report>\n");
        exit(2);
}
