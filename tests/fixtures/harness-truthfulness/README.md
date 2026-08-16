# Harness-truthfulness fixtures

Deliberately broken and deliberately correct shell fixtures for `tests/prod/306`.

They are **not** production tests and must never be discovered as such. Two properties keep
them out: they live outside `tests/prod/`, and none of them is named `NNN-*.sh`. `306` asserts
both, because a broken fixture that leaked into the production sweep would fail the sweep for
the wrong reason — and a fixture that silently stopped being discovered by `306` would take its
detector's evidence with it.

Each detector has a `bad-*` fixture it must reject and a `good-*` control it must accept.

## Known gap: D3 does not analyse inline conditionals

`bad-inline-both-branches-pass.sh` demonstrates a both-branches-pass conditional written
entirely on one line. **D3 does not detect it.** The fixture is retained so the bypass stays
visible and testable rather than forgotten.

An inline grammar was attempted and reverted. It flagged eight real suites; all eight were
classified as tokenizer artefacts — `if` inside multi-line single-quoted awk/jq programs, which
have no `fi`, leaking frames that later assertions attached to. Line-based quote stripping
cannot see that a line sits inside a program quoted from an earlier line.

The multiline detector shares that latent weakness. It reports zero findings today, but it is
silent rather than immune.

## Known gap: D9 does not resolve the diagnostic-argument boundary

`bad-d9-earlier-quote.sh` places an unrelated quoted expression before an unsafe diagnostic.
**D9 does not detect it** — it scans the first quoted string on the line, which is the earlier
one. The fixture is retained so the bypass stays visible.

An anchored version was implemented and reverted: it flagged 19 shipped files, every one an
artefact of `pass`/`fail` appearing as prose inside a double-quoted message or as an argument
word. Deciding whether such a token is a CALL needs double-quote state that spans lines.
