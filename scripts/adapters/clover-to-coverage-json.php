<?php
/**
 * Sentinel Shield adapter — PHPUnit/Pest Clover XML -> normalized coverage.json.
 *
 * Reads a Clover coverage report (phpunit/pest --coverage-clover) and writes the
 * canonical Sentinel Shield coverage shape consumed by scripts/collectors/coverage.sh:
 *   { "tool":"coverage", "status":"pass|findings", "line_percent":.., "branch_percent":..,
 *     "method_percent":.., "class_percent":.., "thresholds":{..}, "violations":N,
 *     "regression":bool, "baseline":{..} }
 *
 * Percentages are aggregated over every <file><metrics> leaf (avoids double-counting the
 * package/project rollups). A metric with a zero denominator is treated as NOT MEASURED:
 * its percent is 0 and it can never raise a threshold violation (so a project with no
 * branches is not falsely failed by branch_min).
 *
 * Usage:
 *   php clover-to-coverage-json.php <clover.xml|-> \
 *       [--line-min N] [--branch-min N] [--method-min N] [--class-min N] \
 *       [--baseline <file.json>] [--fail-on-decrease true|false] [--output <path>]
 *   (default output: stdout)
 *
 * Exit: 0 ok; 2 missing/invalid input. NEVER fakes success — a missing/unparseable
 * Clover report is a hard error, not "100% covered".
 */

function fail(string $msg): void {
    fwrite(STDERR, "[sentinel-shield][error] clover-adapter: $msg\n");
    exit(2);
}

$args = array_slice($argv, 1);
if (count($args) < 1) {
    fwrite(STDERR, "Usage: php clover-to-coverage-json.php <clover.xml|-> [--line-min N] [--branch-min N] [--method-min N] [--class-min N] [--baseline <file>] [--fail-on-decrease true|false] [--output <path>]\n");
    exit(2);
}

$input = $args[0];
$output = '-';
$thr = ['line_min' => 0.0, 'branch_min' => 0.0, 'method_min' => 0.0, 'class_min' => 0.0];
$baselineFile = '';
$failOnDecrease = false;

for ($i = 1; $i < count($args); $i++) {
    $a = $args[$i];
    $needsVal = in_array($a, ['--line-min', '--branch-min', '--method-min', '--class-min', '--baseline', '--fail-on-decrease', '--output'], true);
    if ($needsVal && !isset($args[$i + 1])) fail("$a requires a value");
    switch ($a) {
        case '--line-min':   $thr['line_min']   = (float) $args[++$i]; break;
        case '--branch-min': $thr['branch_min'] = (float) $args[++$i]; break;
        case '--method-min': $thr['method_min'] = (float) $args[++$i]; break;
        case '--class-min':  $thr['class_min']  = (float) $args[++$i]; break;
        case '--baseline':   $baselineFile = $args[++$i]; break;
        case '--fail-on-decrease': $failOnDecrease = in_array(strtolower($args[++$i]), ['1', 'true', 'yes', 'on'], true); break;
        case '--output':     $output = $args[++$i]; break;
        default: fail("unknown argument: $a");
    }
}

$xml = $input === '-' ? file_get_contents('php://stdin') : (is_file($input) ? file_get_contents($input) : fail("input file not found: $input"));
if ($xml === false || trim((string) $xml) === '') fail('input is empty or unreadable');

$prev = libxml_use_internal_errors(true);
$doc = simplexml_load_string($xml);
libxml_use_internal_errors($prev);
if ($doc === false) fail('input is not valid Clover XML');

// Aggregate leaf <file><metrics>. Fall back to any <metrics> if no per-file metrics.
$nodes = $doc->xpath('//file/metrics');
if (!$nodes) $nodes = $doc->xpath('//project/metrics');
if (!$nodes) $nodes = $doc->xpath('//metrics');
if (!$nodes) fail('no <metrics> found in Clover report');

$sum = [
    'statements' => 0, 'coveredstatements' => 0,
    'conditionals' => 0, 'coveredconditionals' => 0,
    'methods' => 0, 'coveredmethods' => 0,
    'classes' => 0, 'coveredclasses' => 0,
];
foreach ($nodes as $m) {
    foreach (array_keys($sum) as $k) {
        if (isset($m[$k])) $sum[$k] += (int) $m[$k];
    }
}

// pct(covered, total): NOT MEASURED (total 0) -> [0.0, false]; else [pct, true].
$pct = function (int $covered, int $total): array {
    if ($total <= 0) return [0.0, false];
    return [round($covered / $total * 100, 1), true];
};
[$linePct, $lineM]   = $pct($sum['coveredstatements'], $sum['statements']);
[$branchPct, $brM]   = $pct($sum['coveredconditionals'], $sum['conditionals']);
[$methodPct, $mM]    = $pct($sum['coveredmethods'], $sum['methods']);
[$classPct, $cM]     = $pct($sum['coveredclasses'], $sum['classes']);

// A threshold violates only when the metric was MEASURED and min > 0.
$violations = 0;
if ($lineM && $thr['line_min'] > 0 && $linePct < $thr['line_min']) $violations++;
if ($brM && $thr['branch_min'] > 0 && $branchPct < $thr['branch_min']) $violations++;
if ($mM && $thr['method_min'] > 0 && $methodPct < $thr['method_min']) $violations++;
if ($cM && $thr['class_min'] > 0 && $classPct < $thr['class_min']) $violations++;

// Regression vs baseline (line/branch), only when fail_on_decrease and a baseline exists.
$regression = false;
$baselineOut = null;
if ($baselineFile !== '' && is_file($baselineFile)) {
    $bRaw = file_get_contents($baselineFile);
    $b = json_decode((string) $bRaw, true);
    if (is_array($b)) {
        $bLine = isset($b['line_percent']) ? (float) $b['line_percent'] : null;
        $bBranch = isset($b['branch_percent']) ? (float) $b['branch_percent'] : null;
        $baselineOut = ['line_percent' => $bLine, 'branch_percent' => $bBranch];
        if ($failOnDecrease) {
            if ($bLine !== null && $lineM && $linePct < $bLine) $regression = true;
            if ($bBranch !== null && $brM && $branchPct < $bBranch) $regression = true;
        }
    }
}

$result = [
    'tool' => 'coverage',
    'status' => ($violations > 0 || $regression) ? 'findings' : 'pass',
    'line_percent' => $linePct,
    'branch_percent' => $branchPct,
    'method_percent' => $methodPct,
    'class_percent' => $classPct,
    'thresholds' => $thr,
    'violations' => $violations,
    'regression' => $regression,
];
if ($baselineOut !== null) $result['baseline'] = $baselineOut;

$json = json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
if ($output === '-') {
    echo $json;
} else {
    $dir = dirname($output);
    if ($dir !== '' && !is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) fail("could not create output directory: $dir");
    if (file_put_contents($output, $json) === false) fail("could not write output: $output");
    fwrite(STDERR, "[sentinel-shield] clover-adapter: wrote $output (line=$linePct%, branch=$branchPct%, violations=$violations, regression=" . ($regression ? 'true' : 'false') . ")\n");
}
exit(0);
