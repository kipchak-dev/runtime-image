<?php

declare(strict_types=1);

/*
 * Tests github-rate-limit.php against a stand-in GitHub API (PHP's built-in server), with no network: it waits only for
 * a used-up allowance that resets within the limit, and asks once more. Then each rule is removed from a copy of the
 * file, and the case it guards must fail: the negative controls.
 *
 *   php php-hardened/tests/github-rate-limit-test.php
 */

$source = dirname(__DIR__) . '/github-rate-limit.php';
$work = sys_get_temp_dir() . '/rate-limit-test-' . getmypid();
@mkdir($work);
file_put_contents("$work/router.php", '<?php
if ($_SERVER["REQUEST_URI"] !== "/rate_limit") { http_response_code(404); return true; }
header("Content-Type: application/json");
echo file_get_contents(__DIR__ . "/answer.json");
');
$port = 18000 + getmypid() % 1000;
$server = proc_open(['php', '-S', "127.0.0.1:$port", "$work/router.php"], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
for ($i = 0; $i < 50 && !@fsockopen('127.0.0.1', $port); $i++) {
    usleep(100000);
}
$api = "http://127.0.0.1:$port";
$now = 1_800_000_000;

/** Runs the function from $file in a fresh process, so a broken copy can be loaded beside the real one. */
function attempt(string $file, string $api, ?string $answer, int $now): array
{
    global $work;
    if ($answer === null) {
        @unlink("$work/answer.json");
    } else {
        file_put_contents("$work/answer.json", $answer);
    }
    $code = 'require ' . var_export($file, true) . '; $slept = null;'
        . '$r = kipchak_github_rate_limit_wait(' . var_export($api, true) . ', function (int $s) use (&$slept) { $slept = $s; }, fn () => ' . $now . ');'
        . 'echo json_encode([$r, $slept]);';
    return json_decode((string) shell_exec('php -r ' . escapeshellarg($code)), true) ?? [null, null];
}

$answer = fn (int $remaining, int $reset) => json_encode(['resources' => ['core' => ['limit' => 60, 'remaining' => $remaining, 'reset' => $reset]]]);
$cases = [
    'used up, resets in 120 s: waits 125 s, asks again' => [$answer(0, $now + 120), [true, 125]],
    'allowance left: no wait' => [$answer(12, $now + 120), [false, null]],
    'resets in more than an hour: no wait' => [$answer(0, $now + 4000), [false, null]],
    'reset already passed: asks again at once' => [$answer(0, $now - 10), [true, null]],
    'unreadable answer: no wait' => ['{"message":"Not Found"}', [false, null]],
];
$fail = 0;
foreach ($cases as $name => [$body, $expected]) {
    $got = attempt($source, $api, $body, $now);
    $ok = $got === $expected;
    echo ($ok ? 'ok' : 'FAIL') . ": $name" . ($ok ? '' : ' (got ' . json_encode($got) . ')') . "\n";
    $fail |= $ok ? 0 : 1;
}

// Controls: each rule removed, its case must change.
$controls = [
    'no allowance check' => ["if (\$core['remaining'] > 0) {", 'if (false) {', 'allowance left: no wait'],
    'no limit on the wait' => ['if ($wait > $max) {', 'if (false) {', 'resets in more than an hour: no wait'],
    'no shape check' => ["if (!is_array(\$core) || !is_int(\$core['remaining'] ?? null) || !is_int(\$core['reset'] ?? null)) {", 'if (false) {', 'unreadable answer: no wait'],
];
foreach ($controls as $name => [$old, $new, $case]) {
    $text = file_get_contents($source);
    if (substr_count($text, $old) !== 1) {
        echo "FAIL: control $name changed nothing\n";
        $fail = 1;
        continue;
    }
    file_put_contents("$work/broken.php", str_replace($old, $new, $text));
    [$body, $expected] = $cases[$case];
    $got = attempt("$work/broken.php", $api, $body, $now);
    $bites = $got !== $expected;
    echo ($bites ? 'ok' : 'FAIL') . ": control $name" . ($bites ? '' : ': the case still passes') . "\n";
    $fail |= $bites ? 0 : 1;
}

proc_terminate($server);
array_map('unlink', glob("$work/*") ?: []);
@rmdir($work);
echo $fail ? '' : "github-rate-limit: every case and control behaves as stated\n";
exit($fail);
