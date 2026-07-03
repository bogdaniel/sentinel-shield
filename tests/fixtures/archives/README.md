# Malicious archive fixtures

Tiny, deterministic ZIP fixtures used by `tests/prod/241-artifact-verification.sh`
to prove that `scripts/lib/archive-safety.sh` (via `scripts/verify-release-artifacts.sh`)
REJECTS unsafe CI artifact archives. Each fixture isolates exactly one attack so the
corresponding rejection reason can be asserted precisely.

| fixture | attack | expected reason token |
| --- | --- | --- |
| `traversal.zip` | an entry with a `..` component (`../escape.txt`) | `path-traversal:` |
| `absolute.zip` | an entry anchored at `/` (`/tmp/abs.txt`) | `absolute-path:` |
| `symlink-escape.zip` | a symlink entry pointing outside the root | `symlink:` |
| `duplicate-path.zip` | the same path listed twice (`reports/dup.txt`) | `duplicate-path:` |
| `oversize.zip` | ~1 MiB uncompressed of zeros, a few hundred bytes on disk (zip bomb) | `oversize:` |

They are committed (not generated at test time) so the suite needs no `python3` at
runtime — only `unzip`/`zipinfo`. They are inert: extracting them would (if the guard
were absent) write outside a temp dir, but the guard rejects them before/at extraction.

Regenerate with (requires python3):

    python3 tests/fixtures/archives/generate.py tests/fixtures/archives
