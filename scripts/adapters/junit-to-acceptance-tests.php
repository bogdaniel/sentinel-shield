<?php
/**
 * Sentinel Shield adapter — JUnit XML -> reports/raw/acceptance-tests.json (v2.2.0).
 *
 * Reads any JUnit XML acceptance report (Behat, Codeception, PHPUnit acceptance suite) and
 * writes the canonical Sentinel Shield acceptance-tests shape:
 *   { "tool":"acceptance-tests", "status":"pass|findings", "tests":N, "failures":N,
 *     "skipped":N, "missing_acceptance_evidence":false }
 *
 * JUnit "errors" (a scenario that blew up) are counted as FAILURES: from an acceptance point
 * of view an errored scenario is a scenario that did not pass.
 *
 * Usage:
 *   php junit-to-acceptance-tests.php <junit.xml> [output.json]
 *   php junit-to-acceptance-tests.php -            # read XML from stdin
 *   (default output: reports/raw/acceptance-tests.json)
 *
 * Exit: 0 ok; 2 missing/invalid input. NEVER fakes success — a missing or unparseable report
 * is a hard error, not "0 failures". A report with tests=0 is left for the collector, which
 * treats an empty run as MISSING acceptance evidence (docs/acceptance-test-evidence.md).
 */

function fail(string $msg): void {
    fwrite(STDERR, "[sentinel-shield][error] acceptance-junit-adapter: $msg\n");
    exit(2);
}

$args = array_slice($argv, 1);
if (count($args) < 1) {
    fwrite(STDERR, "Usage: php junit-to-acceptance-tests.php <junit.xml|-> [output.json]\n");
    exit(2);
}
$input  = $args[0];
$output = $args[1] ?? 'reports/raw/acceptance-tests.json';

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

$tests = 0;
$failures = 0;
$errors = 0;
$skipped = 0;

// JUnit aggregates appear on <testsuites> (preferred) or on each <testsuite>. Reading the
// top-level attributes when present avoids double counting nested suites.
$root = $doc->getName();
if ($root === 'testsuites' && (isset($doc['failures']) || isset($doc['errors']))) {
    $tests    = (int) ($doc['tests'] ?? 0);
    $failures = (int) ($doc['failures'] ?? 0);
    $errors   = (int) ($doc['errors'] ?? 0);
    $skipped  = (int) ($doc['skipped'] ?? 0);
} elseif ($root === 'testsuite') {
    $tests    = (int) ($doc['tests'] ?? 0);
    $failures = (int) ($doc['failures'] ?? 0);
    $errors   = (int) ($doc['errors'] ?? 0);
    $skipped  = (int) ($doc['skipped'] ?? 0);
} else {
    foreach ($doc->testsuite as $suite) {
        $tests    += (int) ($suite['tests'] ?? 0);
        $failures += (int) ($suite['failures'] ?? 0);
        $errors   += (int) ($suite['errors'] ?? 0);
        $skipped  += (int) ($suite['skipped'] ?? 0);
    }
}

$totalFailures = $failures + $errors;
$result = [
    'tool'     => 'acceptance-tests',
    'producer' => 'junit',
    'status'   => $totalFailures > 0 ? 'findings' : 'pass',
    'tests'    => $tests,
    'failures' => $totalFailures,
    'skipped'  => $skipped,
    'missing_acceptance_evidence' => $tests === 0,
];

$dir = dirname($output);
if ($dir !== '' && !is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
    fail("could not create output directory: $dir");
}
if (file_put_contents($output, json_encode($result, JSON_PRETTY_PRINT) . "\n") === false) {
    fail("could not write output: $output");
}
fwrite(STDERR, "[sentinel-shield] acceptance-junit-adapter: wrote $output (tests=$tests, failures=$totalFailures)\n");
exit(0);
