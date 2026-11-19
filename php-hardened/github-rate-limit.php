<?php

declare(strict_types=1);

/**
 * Waits for GitHub's anonymous API allowance to reset. Called by the static-php-cli patch in build-frankenphp.sh only
 * after a request to api.github.com was refused with the token (an organisation's IP allow list) and then failed without
 * it. On a shared GitHub Actions runner the address's 60 anonymous requests an hour may already be used by others; the
 * request then succeeds once the allowance resets.
 *
 * It reads /rate_limit, which does not count against the allowance. It waits only when the core allowance is used up
 * (remaining 0) and resets within $max seconds, then returns true, and the caller asks once more. In every other case
 * (allowance left, a reset too far away, an unreadable answer) it returns false at once, and the request fails as before.
 *
 * @param callable(int): mixed|null $sleep for the tests; defaults to sleep()
 * @param callable(): int|null      $now   for the tests; defaults to time()
 */
function kipchak_github_rate_limit_wait(string $api = 'https://api.github.com', ?callable $sleep = null, ?callable $now = null, int $max = 3600): bool
{
    $sleep ??= 'sleep';
    $now ??= 'time';
    $context = stream_context_create(['http' => [
        'timeout' => 30,
        'ignore_errors' => true,
        'header' => "User-Agent: kipchak-runtime-build\r\nAccept: application/vnd.github+json\r\n",
    ]]);
    $body = @file_get_contents(rtrim($api, '/') . '/rate_limit', false, $context);
    $data = is_string($body) ? json_decode($body, true) : null;
    $core = is_array($data) ? ($data['resources']['core'] ?? null) : null;
    if (!is_array($core) || !is_int($core['remaining'] ?? null) || !is_int($core['reset'] ?? null)) {
        return false;
    }
    if ($core['remaining'] > 0) {
        return false;
    }
    $wait = $core['reset'] - $now() + 5;
    if ($wait > $max) {
        return false;
    }
    if ($wait > 0) {
        $sleep($wait);
    }
    return true;
}
