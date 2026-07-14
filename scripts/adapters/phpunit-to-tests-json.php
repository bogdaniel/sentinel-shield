<?php
/**
 * Sentinel Shield adapter — PHPUnit JUnit XML -> reports/raw/tests.json.
 *
 * Reads a PHPUnit JUnit XML report and writes the canonical Sentinel Shield tests
 * shape: { "failures": N, "errors": N }. The `tests` collector maps that to
 * test_failures (failures + errors).
 *
 * Usage:
 *   php phpunit-to-tests-json.php <junit.xml> [output.json]
 *   php phpunit-to-tests-json.php -            # read XML from stdin
 *   (default output: reports/raw/tests.json)
 *
 * Produce the input with:  phpunit --log-junit junit.xml
 *
 * Exit: 0 ok; 2 missing/invalid input. NEVER fakes success — a missing or
 * unparseable report is a hard error, not "0 failures".
 */

function fail(string $msg): void {
    fwrite(STDERR, "[sentinel-shield][error] phpunit-adapter: $msg\n");
    exit(2);
}

$args = array_slice($argv, 1);
if (count($args) < 1) {
    fwrite(STDERR, "Usage: php phpunit-to-tests-json.php <junit.xml|-> [output.json]\n");
    exit(2);
}
$input  = $args[0];
$output = $args[1] ?? 'reports/raw/tests.json';

if ($input === '-') {
    $xml = file_get_contents('php://stdin');
} else {
    if (!is_file($input)) {
        fail("input file not found: $input");
    }
    $xml = file_get_contents($input);
}
if ($xml === false || trim($xml) === '') {
    fail('input is empty or unreadable');
}

// Parse defensively; surface real parse errors (never swallow into a clean report).
$prev = libxml_use_internal_errors(true);
$doc = simplexml_load_string($xml);
libxml_use_internal_errors($prev);
if ($doc === false) {
    fail('input is not valid JUnit XML');
}

// JUnit aggregates appear on <testsuites> (preferred) or on each <testsuite>.
// Sum every <testsuite> that is NOT nested inside another <testsuite> would
// double count; instead read the top <testsuites> attributes when present,
// else sum top-level <testsuite> nodes.
$failures = 0;
$errors   = 0;
$tests    = 0;
$skipped  = 0;

$root = $doc->getName();
if ($root === 'testsuites' && (isset($doc['failures']) || isset($doc['errors']))) {
    $failures = (int) ($doc['failures'] ?? 0);
    $errors   = (int) ($doc['errors'] ?? 0);
    $tests    = (int) ($doc['tests'] ?? 0);
    $skipped  = (int) ($doc['skipped'] ?? 0);
} elseif ($root === 'testsuite') {
    $failures = (int) ($doc['failures'] ?? 0);
    $errors   = (int) ($doc['errors'] ?? 0);
    $tests    = (int) ($doc['tests'] ?? 0);
    $skipped  = (int) ($doc['skipped'] ?? 0);
} else {
    // <testsuites> without aggregate attrs: sum direct child <testsuite> nodes.
    foreach ($doc->testsuite as $suite) {
        $failures += (int) ($suite['failures'] ?? 0);
        $errors   += (int) ($suite['errors'] ?? 0);
        $tests    += (int) ($suite['tests'] ?? 0);
        $skipped  += (int) ($suite['skipped'] ?? 0);
    }
}

$result = ['failures' => $failures, 'errors' => $errors, 'tests' => $tests, 'skipped' => $skipped];

$dir = dirname($output);
if ($dir !== '' && !is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
    fail("could not create output directory: $dir");
}
if (file_put_contents($output, json_encode($result, JSON_PRETTY_PRINT) . "\n") === false) {
    fail("could not write output: $output");
}
fwrite(STDERR, "[sentinel-shield] phpunit-adapter: wrote $output (failures=$failures, errors=$errors)\n");
exit(0);
