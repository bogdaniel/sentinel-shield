<?php
/**
 * Sentinel Shield adapter — Behat JUnit XML -> reports/raw/behavior-specs.json (v2.2.0).
 *
 * Reads a Behat JUnit report (`behat --format junit --out <dir>`) and writes the canonical
 * Sentinel Shield behavior-specs shape:
 *   { "tool":"behavior-specs", "status":"pass|findings", "spec_count":N, "scenario_count":N,
 *     "orphan_behavior_specifications":0, "missing_behavior_specification":false,
 *     "failures":[...] }
 *
 * Mapping: each <testsuite> is a FEATURE (spec), each <testcase> is a SCENARIO. A scenario
 * with a <failure> or <error> child is a failing scenario.
 *
 * Usage:
 *   php behat-junit-to-behavior-specs.php <junit.xml|-> [output.json]
 *   (default output: reports/raw/behavior-specs.json)
 *
 * Exit: 0 ok; 2 missing/invalid input. NEVER fakes success. Counting scenarios says nothing
 * about whether they describe the right behavior — Sentinel Shield does not guarantee BDD
 * quality (docs/bdd-atdd-evidence.md).
 */

function fail(string $msg): void {
    fwrite(STDERR, "[sentinel-shield][error] behat-behavior-specs-adapter: $msg\n");
    exit(2);
}

$args = array_slice($argv, 1);
if (count($args) < 1) {
    fwrite(STDERR, "Usage: php behat-junit-to-behavior-specs.php <junit.xml|-> [output.json]\n");
    exit(2);
}
$input  = $args[0];
$output = $args[1] ?? 'reports/raw/behavior-specs.json';

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

$prev = libxml_use_internal_errors(true);
$doc = simplexml_load_string($xml);
libxml_use_internal_errors($prev);
if ($doc === false) {
    fail('input is not valid JUnit XML');
}

// iterator_to_array() defaults to PRESERVING KEYS, and SimpleXML uses the ELEMENT NAME as
// the key — so every <testsuite> child collapses onto the single key "testsuite" and only
// the LAST feature survives. A 2-feature report reported 1 spec, 3 scenarios and ZERO
// failures: a failing Behat suite read as clean. Pass false to index numerically.
$suites = $doc->getName() === 'testsuite' ? [$doc] : iterator_to_array($doc->testsuite, false);

$specCount = 0;
$scenarioCount = 0;
$failures = [];

foreach ($suites as $suite) {
    $specCount++;
    $featureName = (string) ($suite['name'] ?? 'unknown feature');
    foreach ($suite->testcase as $case) {
        $scenarioCount++;
        if (isset($case->failure) || isset($case->error)) {
            $failures[] = $featureName . ': ' . (string) ($case['name'] ?? 'unnamed scenario');
        }
    }
}

$result = [
    'tool'     => 'behavior-specs',
    'producer' => 'behat',
    'status'   => count($failures) > 0 ? 'findings' : 'pass',
    'spec_count'     => $specCount,
    'scenario_count' => $scenarioCount,
    // Orphan detection needs a spec->implementation map the JUnit report does not carry.
    // Reporting 0 is a truthful "this producer cannot determine it".
    'orphan_behavior_specifications' => 0,
    'missing_behavior_specification' => $specCount === 0 && $scenarioCount === 0,
    'failures' => $failures,
];

$dir = dirname($output);
if ($dir !== '' && !is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
    fail("could not create output directory: $dir");
}
if (file_put_contents($output, json_encode($result, JSON_PRETTY_PRINT) . "\n") === false) {
    fail("could not write output: $output");
}
fwrite(STDERR, "[sentinel-shield] behat-behavior-specs-adapter: wrote $output (specs=$specCount, scenarios=$scenarioCount)\n");
exit(0);
