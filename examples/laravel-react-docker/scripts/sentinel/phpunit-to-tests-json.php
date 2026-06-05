<?php

declare(strict_types=1);

/**
 * Sentinel Shield — PHPUnit JUnit -> tests.json normalizer.
 *
 * Reads a PHPUnit JUnit XML report and writes the normalized shape the `tests`
 * collector expects:
 *
 *     { "failures": <int>, "errors": <int> }
 *
 * Usage:
 *   php scripts/sentinel/phpunit-to-tests-json.php [input.xml] [output.json]
 *   defaults: reports/raw/phpunit.xml -> reports/raw/tests.json
 *
 * Exit codes: 0 ok, 2 input missing/unreadable/invalid. It does NOT fake success
 * when the report is absent — a missing report is an error, not "0 failures".
 */

$input  = $argv[1] ?? 'reports/raw/phpunit.xml';
$output = $argv[2] ?? 'reports/raw/tests.json';

if (! is_file($input) || ! is_readable($input)) {
    fwrite(STDERR, "[sentinel-shield][error] JUnit report not found/readable: {$input}\n");
    exit(2);
}

$xml = @simplexml_load_file($input);
if ($xml === false) {
    fwrite(STDERR, "[sentinel-shield][error] invalid JUnit XML: {$input}\n");
    exit(2);
}

// PHPUnit emits either a <testsuites> root that already aggregates, or a single
// <testsuite> root. Sum the top-level element's attributes; fall back to summing
// the immediate <testsuite> children when the root carries no totals.
$failures = 0;
$errors   = 0;

$rootFailures = isset($xml['failures']) ? (int) $xml['failures'] : null;
$rootErrors   = isset($xml['errors']) ? (int) $xml['errors'] : null;

if ($rootFailures !== null || $rootErrors !== null) {
    $failures = $rootFailures ?? 0;
    $errors   = $rootErrors ?? 0;
} else {
    foreach ($xml->testsuite as $suite) {
        $failures += isset($suite['failures']) ? (int) $suite['failures'] : 0;
        $errors   += isset($suite['errors']) ? (int) $suite['errors'] : 0;
    }
}

$payload = json_encode(
    ['failures' => $failures, 'errors' => $errors],
    JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES
) . "\n";

if (@file_put_contents($output, $payload) === false) {
    fwrite(STDERR, "[sentinel-shield][error] could not write: {$output}\n");
    exit(2);
}

fwrite(STDERR, "[sentinel-shield] wrote {$output} (failures={$failures}, errors={$errors})\n");
exit(0);
