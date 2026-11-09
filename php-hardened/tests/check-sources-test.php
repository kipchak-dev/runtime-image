<?php

declare(strict_types=1);

// The guard must fail when it should, including when it could not look. Run: php tests/check-sources-test.php

require dirname(__DIR__) . '/check-sources.php';

$failures = 0;
function check(string $what, bool $passed): void
{
    global $failures;
    echo($passed ? 'ok    ' : 'FAIL  ') . $what . "\n";
    $failures += $passed ? 0 : 1;
}

$source = static fn (string $file): array => ['source' => ['filename' => $file]];
$now = 1_800_000_000;
$report = static fn (array $entries, ?int $at = null): array => ['generated' => $at ?? $now, 'entries' => $entries];
$entry = static fn (string $status, ?float $age = 1.0): array => ['name' => 'lib', 'file' => 'lib.tar.gz', 'ours' => '1', 'newest' => '2', 'age_months' => $age, 'status' => $status];

$lock = ['a' => $source('a'), 'b' => $source('b'), 'c' => $source('c'), 'd' => $source('d'), 'e' => $source('e'), 'none' => ['binary' => []]];
$updates = [
    'a' => ['need-update' => false, 'unsupported' => false, 'old' => '1', 'new' => '1'],
    'b' => ['need-update' => true, 'unsupported' => false, 'old' => '1', 'new' => '2'],
    'c' => ['need-update' => false, 'unsupported' => true, 'old' => null, 'new' => null],
    'd' => ['need-update' => false, 'unsupported' => false, 'old' => '1', 'new' => null],
];
$classified = array_column(classify($lock, $updates, []), 'status', 'name');
check('up to date is current', $classified['a'] === CURRENT);
check('a newer release is behind', $classified['b'] === BEHIND);
check('unsupported is not comparable, not current', $classified['c'] === NOT_COMPARABLE);
check('an empty answer is a failed lookup, not current', $classified['d'] === LOOKUP_FAILED);
check('no answer at all is a failed lookup, not current', $classified['e'] === LOOKUP_FAILED);
check('what has no source is not listed', !isset($classified['none']));

check('behind by 18 months fails the build', pastFailureMargin($entry(BEHIND, 18.0)));
check('control: behind by 17.9 months does not fail the build', !pastFailureMargin($entry(BEHIND, 17.9)));
check('control: an old library that is current does not fail the build', !pastFailureMargin($entry(CURRENT, 40.0)));
check('behind by 6 months alerts', needsAttention($entry(BEHIND, 6.0)));
check('control: behind by 5.9 months does not alert', !needsAttention($entry(BEHIND, 5.9)));
check('behind with no known age alerts', needsAttention($entry(BEHIND, null)));
check('a failed lookup alerts', needsAttention($entry(LOOKUP_FAILED)));

$current = $entry(CURRENT);
check('a missing report alerts', problems(null, $now) !== []);
check('an empty report alerts', problems($report([]), $now) !== []);
check('a stale report alerts', problems($report([$current], $now - 10 * 86400), $now) !== []);
check('nothing compared alerts', problems($report([$entry(NOT_COMPARABLE)]), $now) !== []);
check('a failed lookup in a report alerts', problems($report([$current, $entry(LOOKUP_FAILED)]), $now) !== []);
check('control: a fresh report with a current library is clean', problems($report([$current, $entry(NOT_COMPARABLE)]), $now) === []);

check('a release candidate is marked', isPrerelease('3.2.17RC1') && isPrerelease('igbinary-3.2.17RC1.tar.gz') && isPrerelease('2.0.0-beta.1'));
check('control: a release is not marked', !isPrerelease('3.2.16') && !isPrerelease('v1.2.1') && !isPrerelease('libsodium-1.0.22-RELEASE') && !isPrerelease('REL_18_6') && !isPrerelease('release-79-1') && !isPrerelease('dev-master+b1342da') && !isPrerelease('dev-php7+a7a3b86') && !isPrerelease('zlib-1.4.tar.gz'));

// A hand-pinned Go module: an unreleased commit is never current.
$pseudo = 'v0.30.3-0.20261105213751-6d5a251fbe01';
$unreleased = goPinEntry('github.com/smallstep/certificates', $pseudo, 'v0.30.2', (int) strtotime('2026-11-09 00:00:00 UTC'));
check('an unreleased pin reads as behind, not current', $unreleased['status'] === BEHIND && $unreleased['unreleased'] === true);
check('its age is the commit\'s', $unreleased['age_months'] === 0.1);
check('control: young, so it does not alert', !needsAttention($unreleased));
check('it alerts at six months', needsAttention(goPinEntry('m', $pseudo, 'v0.30.2', (int) strtotime('2027-05-20 00:00:00 UTC'))));
check('it fails the build at eighteen months', pastFailureMargin(goPinEntry('m', $pseudo, 'v0.30.2', (int) strtotime('2028-05-20 00:00:00 UTC'))));
check('a released pin that is the latest is current', goPinEntry('m', 'v0.92.0', 'v0.92.0', $now)['status'] === CURRENT);
check('a released pin with a newer release is behind', goPinEntry('m', 'v0.92.0', 'v0.93.0', $now)['status'] === BEHIND);
check('a pin not linked is a failed lookup', goPinEntry('m', null, 'v0.92.0', $now)['status'] === LOOKUP_FAILED);
check('a proxy that cannot say is a failed lookup', goPinEntry('m', 'v0.92.0', false, $now)['status'] === LOOKUP_FAILED);

// News that a pin can go: said on the day of the release, and only then.
$day = (int) strtotime('2027-02-01 12:00:00 UTC');
$pin = ['name' => 'go:github.com/smallstep/certificates', 'ours' => $pseudo, 'unreleased' => true];
$clean = "module github.com/caddyserver/caddy/v2\nrequire go.step.sm/crypto v0.92.0\n";
$withV3 = $clean . "require github.com/go-jose/go-jose/v3 v3.0.5 // indirect\n";
$hasV3 = static fn (): string => $withV3;
$noV3 = static fn (): string => $clean;
$releases = static fn (string $smallstep, string $smallstepAt, string $caddyAt): Closure => static fn (string $module): array => str_contains($module, 'caddy')
    ? ['Version' => 'v2.12.0', 'Time' => $caddyAt]
    : ['Version' => $smallstep, 'Time' => $smallstepAt];
$old = '2026-11-01T00:00:00Z';
$today = '2027-02-01T06:00:00Z';
check('a smallstep release past the commit says to remove the pin', str_contains(implode(' ', pinNews([$pin], $day, $releases('v0.30.3', $today, $old), $hasV3)), 'remove the unreleased pin'));
check('and not again the next day', pinNews([$pin], $day + 2 * 86400, $releases('v0.30.3', $today, $old), $hasV3) === []);
check('control: a release older than the commit is no news', pinNews([$pin], $day, $releases('v0.30.2', $today, $old), $hasV3) === []);
check('a Caddy release without v3 says the pins can go', str_contains(implode(' ', pinNews([$pin], $day, $releases('v0.30.2', $old, $today), $noV3)), 'no longer needs go-jose/v3'));
check('control: a Caddy release still with v3 is no news', pinNews([$pin], $day, $releases('v0.30.2', $old, $today), $hasV3) === []);
check('a proxy that cannot say alerts', pinNews([$pin], $day, static fn (): bool => false, $hasV3) !== []);
check('control: nothing pinned asks nothing', pinNews([$current], $day, static fn (): bool => false, $hasV3) === []);
check('a report saying the pins are unnecessary alerts', problems(['pins_unnecessary' => true] + $report([$current]), $now) !== []);

// A recipe's own lookup can be wrong: this is ICU as it was, with the build's real values.
$icu = ['need-update' => false, 'unsupported' => false, 'old' => 'release-77-1', 'new' => 'release-77-1'];
$corrected = correctedByLatestRelease($icu, 'release-79.1');
check('a recipe that misses a newer release is corrected', $corrected['need-update'] === true && $corrected['new'] === 'release-79.1');
check('and so reads as behind', array_column(classify(['icu' => $source('icu.tgz')], ['icu' => $corrected], ['icu' => 19.9]), 'status', 'name')['icu'] === BEHIND);
check('and at 19.9 months fails the build', pastFailureMargin(['status' => BEHIND, 'age_months' => 19.9]));
check('control: the latest release is not newer', correctedByLatestRelease(['old' => 'curl-8_23_0', 'need-update' => false], 'curl-8_23_0')['need-update'] === false);
check('control: an older latest release changes nothing', correctedByLatestRelease(['old' => 'v2.0.0', 'need-update' => false], 'v1.9.0')['need-update'] === false);
check('control: no release changes nothing', correctedByLatestRelease($icu, null) === $icu);
check('tags compare whatever their form', versionOf('REL_18_6') === '18.6' && versionOf('curl-8_23_0') === '8.23.0' && versionOf('libsodium-1.0.22-RELEASE') === '1.0.22' && versionOf('dev') === null);

// The commands themselves: a failed lookup is recorded, and then alerts.
$directory = sys_get_temp_dir() . '/check-sources-' . getmypid();
mkdir($directory);
$command = static function (string ...$arguments): int {
    exec(escapeshellarg(PHP_BINARY) . ' -n ' . escapeshellarg(dirname(__DIR__) . '/check-sources.php') . ' ' . implode(' ', array_map('escapeshellarg', $arguments)) . ' 2>&1', $output, $exit);

    return $exit;
};
file_put_contents("{$directory}/lock.json", json_encode(['a' => $source('a.tar.gz')]));
file_put_contents("{$directory}/nothing.json", '{}');
file_put_contents("{$directory}/empty.json", '{}');
file_put_contents("{$directory}/current.json", json_encode(['a' => ['need-update' => false, 'unsupported' => false, 'old' => '1', 'new' => '1']]));
check('an empty source list stops the build', $command('report', "{$directory}/empty.json", "{$directory}/current.json", $directory, "{$directory}/r0.json") === 1);
check('an empty lookup does not stop the build', $command('report', "{$directory}/lock.json", "{$directory}/nothing.json", $directory, "{$directory}/r1.json") === 0);
check('an empty lookup then alerts', $command('alert', "{$directory}/r1.json") === 1);
check('control: a current library does not alert', $command('report', "{$directory}/lock.json", "{$directory}/current.json", $directory, "{$directory}/r2.json") === 0 && $command('alert', "{$directory}/r2.json") === 0);
$pinned = goPinEntry('m', null, false, $now);
check('a report naming a pin that is not linked alerts', problems($report([$current, $pinned]), $now) !== []);
check('a report that cannot be read alerts', $command('alert', "{$directory}/absent.json") === 1);
array_map('unlink', glob("{$directory}/*"));
rmdir($directory);

exit($failures === 0 ? 0 : 1);
