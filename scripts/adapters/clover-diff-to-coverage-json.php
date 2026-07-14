<?php
/**
 * Sentinel Shield adapter — Clover XML + changed-lines -> normalized diff-coverage.json.
 *
 * Computes CHANGED-LINES (diff) coverage: of the executable lines that a change touched, how
 * many are covered. Reads per-line hit data from Clover (`<line num="X" count="N"/>`) and the
 * set of changed lines produced by scripts/runners/php-diff-coverage.sh (git diff).
 *
 * Usage:
 *   php clover-diff-to-coverage-json.php <clover.xml> --changed-lines <file> \
 *       [--threshold N] [--output <path>]
 *   --changed-lines <file>: one "relative/path.php:LINE" per changed (added/modified) line.
 *   (default output: stdout)
 *
 * Raw output:
 *   { "tool":"diff-coverage", "status":"pass|findings", "changed_lines_coverage_percent":P,
 *     "threshold":T, "changed_executable_lines":N, "covered_changed_lines":C, "violations":V }
 *
 * If NO changed line is an executable line in the Clover report, coverage is vacuously 100
 * (no new testable code) and violations = 0. Exit: 0 ok; 2 missing/invalid input.
 */

function fail(string $msg): void {
    fwrite(STDERR, "[sentinel-shield][error] clover-diff-adapter: $msg\n");
    exit(2);
}

function num01(string $flag, string $raw): float {
    if (!is_numeric($raw)) fail("$flag must be a finite number in 0..100, got '$raw'");
    $n = (float) $raw;
    if (!is_finite($n) || $n < 0 || $n > 100) fail("$flag must be a finite number in 0..100, got '$raw'");
    return $n;
}

$args = array_slice($argv, 1);
if (count($args) < 1) {
    fwrite(STDERR, "Usage: php clover-diff-to-coverage-json.php <clover.xml> --changed-lines <file> [--threshold N] [--output <path>]\n");
    exit(2);
}

$input = $args[0];
$changedFile = '';
$threshold = 80.0;
$output = '-';
for ($i = 1; $i < count($args); $i++) {
    $a = $args[$i];
    $needsVal = in_array($a, ['--changed-lines', '--threshold', '--output'], true);
    if ($needsVal && !isset($args[$i + 1])) fail("$a requires a value");
    switch ($a) {
        case '--changed-lines': $changedFile = $args[++$i]; break;
        case '--threshold':     $threshold = num01('--threshold', $args[++$i]); break;
        case '--output':        $output = $args[++$i]; break;
        default: fail("unknown argument: $a");
    }
}

if (!is_file($input)) fail("clover file not found: $input");
$xml = file_get_contents($input);
if ($xml === false || trim((string) $xml) === '') fail('clover input is empty or unreadable');
$prev = libxml_use_internal_errors(true);
$doc = simplexml_load_string($xml);
libxml_use_internal_errors($prev);
if ($doc === false) fail('input is not valid Clover XML');

if ($changedFile === '') fail('--changed-lines is required');
if (!is_file($changedFile)) fail("--changed-lines file not found: $changedFile");

// Changed set: normalize "path:line" -> [ basename-or-suffix => set(line) ]. We match Clover
// file paths by suffix (Clover uses absolute paths; git uses repo-relative), so index by the
// repo-relative path AND compare via endsWith.
$changed = [];
foreach (preg_split('/\R/', (string) file_get_contents($changedFile)) as $line) {
    $line = trim($line);
    if ($line === '') continue;
    $pos = strrpos($line, ':');
    if ($pos === false) continue;
    $path = substr($line, 0, $pos);
    $ln = (int) substr($line, $pos + 1);
    if ($ln <= 0) continue;
    $changed[$path][$ln] = true;
}
if (!$changed) {
    // No changed lines at all -> vacuously covered.
    $result = ['tool' => 'diff-coverage', 'status' => 'pass', 'changed_lines_coverage_percent' => 100,
        'threshold' => $threshold, 'changed_executable_lines' => 0, 'covered_changed_lines' => 0, 'violations' => 0];
    emit($result, $output);
}

// changed_paths_match(cloverPath): return the changed-set for the file whose repo-relative path
// is a suffix of the Clover path (or vice-versa).
function matchChanged(array $changed, string $cloverPath): ?array {
    $cp = str_replace('\\', '/', $cloverPath);
    foreach ($changed as $rel => $lines) {
        $r = str_replace('\\', '/', $rel);
        if ($cp === $r || str_ends_with($cp, '/' . $r) || str_ends_with($r, '/' . basename($cp)) || basename($cp) === basename($r)) {
            // Prefer a real path-suffix match; basename fallback handles path-root differences.
            if ($cp === $r || str_ends_with($cp, '/' . $r)) return $lines;
        }
    }
    // Fallback: basename match (less precise but avoids missing a file entirely).
    foreach ($changed as $rel => $lines) {
        if (basename(str_replace('\\', '/', $rel)) === basename($cp)) return $lines;
    }
    return null;
}

$totalChanged = 0;
$coveredChanged = 0;
foreach ($doc->xpath('//file') as $file) {
    $path = (string) ($file['name'] ?? '');
    if ($path === '') continue;
    $lines = matchChanged($changed, $path);
    if ($lines === null) continue;
    foreach ($file->line as $l) {
        $num = (int) ($l['num'] ?? 0);
        if ($num <= 0 || !isset($lines[$num])) continue;
        // Executable line touched by the change.
        $totalChanged++;
        if ((int) ($l['count'] ?? 0) > 0) $coveredChanged++;
    }
}

$percent = $totalChanged > 0 ? round($coveredChanged / $totalChanged * 100, 1) : 100;
$violations = ($totalChanged > 0 && $percent < $threshold) ? 1 : 0;
$result = [
    'tool' => 'diff-coverage',
    'status' => $violations > 0 ? 'findings' : 'pass',
    'changed_lines_coverage_percent' => $percent,
    'threshold' => $threshold,
    'changed_executable_lines' => $totalChanged,
    'covered_changed_lines' => $coveredChanged,
    'violations' => $violations,
];
emit($result, $output);

function emit(array $result, string $output): void {
    $json = json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
    if ($output === '-') { echo $json; }
    else {
        $dir = dirname($output);
        if ($dir !== '' && !is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) fail("could not create output directory: $dir");
        if (file_put_contents($output, $json) === false) fail("could not write output: $output");
        fwrite(STDERR, "[sentinel-shield] clover-diff-adapter: wrote $output (percent={$result['changed_lines_coverage_percent']}%, violations={$result['violations']})\n");
    }
    exit(0);
}
