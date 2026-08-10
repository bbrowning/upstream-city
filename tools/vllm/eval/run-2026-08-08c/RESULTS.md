# caseR re-run — validating the sharpened parser persona

Single-case flywheel validation: after round 2 (`run-2026-08-08b/`) left caseR a **shared
gold miss** (both arms approved, 0 findings), we sharpened `personas/parser.md` (reject a
hand-rolled fake fixture as combined-flow coverage; never decode raw token ids in a parser
— the detokenizer holds text back, so id/text streams are misaligned). This re-run tests
whether the edit flips the miss. Same blind harness, same model (opus), same caseR inputs.

De-blind map: R1=B (lean), R2=A (current).

## Result

| Arm | run-b (before) | run-c (after) | gold | signal | noise | grounded |
|-----|----------------|---------------|------|--------|-------|----------|
| **B lean** | miss · approve · 0 | **catch · request_changes** | catch | 2 | 0 | 5 |
| **A current** | miss · approve · 0 | partial · approve_with_nits | partial | 1 | 2 | 3 |

Blind-judge winner: **B (lean)**, decisively.

- **Lean caught both gold prongs and reproduced the bug.** It flagged
  `self.model_tokenizer.decode(current_token_ids)` as not multi-token-char safe and backed
  it with a concrete repro the judge **independently verified**: Qwen3-32B astronaut ZWJ
  emoji `🧑‍🚀` (ids `[148738,378,235,145836]`) with the transition delta ending mid-
  sequence emits `🧑` + `U+FFFD` and drops the tail. It also rejected the fabricated
  `_FakeEngineReasoningParser` as unable to catch this and named the real fix (a
  `Qwen3ParserReasoningAdapter` + `Hermes2ProToolParser` regression), and pointed to the
  sibling engine branch's `finish_streaming()` as the right pattern.
- **Current improved but still didn't act.** It went from approve/0-findings (run-b) to
  approve_with_nits, weakly gesturing at the decode-boundary risk in a nit it then
  dismissed as "not a new defect" — a claim the judge scored a **false positive** (the
  engine branch flushes via `finish_streaming()` and does NOT re-decode, so it doesn't have
  the bug; only the new else branch does). It missed the fixture-realism prong entirely.

## Verdict on the persona edit
**Validated on this case:** caseR moved miss → catch with no added noise (lean noise = 0),
and lean's finding language maps directly onto the two sharpened reflexes — they fired and
converted a passive observation into a `request_changes`.

**Honest caveat:** this is not a perfectly controlled A/B. opus has run-to-run variance
(Arm A also drifted, miss → partial with no persona change), so "the persona edit caused
this" is strongly supported but not isolated. Confidence is "validated on caseR," not
"proven in isolation." Re-running periodically guards against regression.
