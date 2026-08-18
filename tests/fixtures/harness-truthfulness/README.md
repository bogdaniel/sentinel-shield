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

An inline grammar was attempted and reverted. It flagged eight real suites, classified before
any further parser change: seven were tokenizer artefacts — `if` inside multi-line single-quoted
awk/jq programs, which have no `fi`, leaking frames that later assertions attached to — and the
eighth was `301`'s two `observation-only` sites, which the real detector exempts and the probe
did not. None was a genuine inline both-branches-pass. Line-based quote stripping cannot see
that a line sits inside a program quoted from an earlier line.

D3 now **skips** a line that opens and closes a conditional by itself instead of opening a frame
for it. That is not detection — the gap above is unchanged — but it stops the leak: across
`tests/prod`, files carrying a leaked frame at EOF fall from 53 to 29. The remaining 29 are the
quoted-program case, which needs multi-line quote state. The multiline detector is therefore
silent on the tail of those files rather than immune, and reports zero findings today.

## D5 negative fixtures are single-fault

Each `bad-fidelity-*.json` violates exactly one rule and satisfies every other, so a rejection
is attributable to the fault under test. A fixture carrying two faults would still be rejected
if the rule it was named for stopped working. Rule (d) has two limbs and therefore two fixtures:
`bad-fidelity-inventory.json` (a direct-only entry citing itself) and
`bad-fidelity-missing-citation.json` (a mandatory subject naming no covering suite).

## Known gap: D9 does not resolve the diagnostic-argument boundary

`bad-d9-earlier-quote.sh` places an unrelated quoted expression before an unsafe diagnostic.
**D9 does not detect it** — it scans the first quoted string on the line, which is the earlier
one. The fixture is retained so the bypass stays visible.

An anchored version was implemented and reverted: it flagged 19 shipped files, every one an
artefact of `pass`/`fail` appearing as prose inside a double-quoted message or as an argument
word. Deciding whether such a token is a CALL needs double-quote state that spans lines.

## Both retained bypasses are LEGACY-SYNTAX gaps

`config/harness-assertion-policy.json` removes both classes by construction for the suites
registered there — a registered suite has no `pass`/`fail` to call, and no helper line may carry
a command substitution. `tests/prod/307` proves each rule against its own broken fixture,
including the earlier-quote shape that defeats D9 here.

That does **not** narrow the gaps below. 131 of 3,247 static verdict sites are canonical (~4.03%); the
other 95 suites are carried by the detectors in `tests/prod/306`, with these bypasses exactly as
wide as before. The fixtures stay for that reason.

