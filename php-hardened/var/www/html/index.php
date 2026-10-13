<?php

// Placeholder worker, replaced by the API's own html/index.php.

ignore_user_abort(true);

while (\frankenphp_handle_request(static function (): void {
    header('Content-Type: application/json');
    echo json_encode(['status' => 'ok', 'runtime' => 'kipchak', 'php' => PHP_VERSION]);
})) {
    gc_collect_cycles();
}
