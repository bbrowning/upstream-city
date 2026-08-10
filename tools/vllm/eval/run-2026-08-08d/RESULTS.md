# caseY re-run — validating parser reflex #2 (per-model override coverage)

Flywheel validation of the round-1 lean MISS. In round 1 (`run-2026-08-08/`) caseY was a
**current win / lean miss**: the current pack flagged that the six per-model
`is_reasoning_end_streaming` overrides have no parity test, while lean hand-verified parity
and declared the change "thoroughly tested," glossing over the untested surface. That lesson
became `personas/parser.md` reflex #2 ("shared base + per-model overrides need per-model
tests"). This re-run tests whether the reflex flips the miss. Same blind harness, model opus,
same caseY inputs; answer key added for grading.

De-blind map: R1=A (current), R2=B (lean).

## Result

| Arm | round 1 | run-d (after reflex #2) | gold | signal | noise | grounded |
|-----|---------|-------------------------|------|--------|-------|----------|
| **B lean** | **miss** | **catch** · approve_with_nits | catch | 1 | 0 | 4 |
| **A current** | catch | catch · approve_with_nits | catch | 1 | 0 | 5 |

Blind-judge winner: **A (current)**, "by a hair" — but the flywheel goal is met: **caseY
moved lean miss → catch.**

- **Lean now catches it (the flip).** Arm B identified that the only new parity test
  (`test_parser_engine.py`) exercises the base ParserEngine and none of the six per-model
  overrides (qwen3/mistral/kimi_k2/inkling/glm47_moe/gemma4), that a base test + broad suite
  can stay green while an override silently drifts, and demanded a per-override guard — and
  it brute-forced four overrides against their full predicate (all sequences ≤ len 5, one
  token/step) to show they're correct *today* but unguarded. That is reflex #2 firing.
  Critically, unlike round 1 it did **not** declare the change adequately tested.
- **Current still catches it**, as in round 1, with the same coverage-gap finding.
- **Why current edged this run:** groundedness tiebreak. Lean took one false-positive ding
  — it ran the `vllm/reasoning/*_reasoning_parser.py` suites (135 passed) and presented that
  as a "no regressions" check, but those exercise the `vllm.reasoning` class hierarchy, not
  the changed `vllm/parser` ParserEngine overrides — a misattributed verification, not a
  wrong finding. The gold finding itself was judge-verified on both arms.

## Verdict on the reflex
**Validated:** reflex #2 converted caseY from lean miss → catch with no added noise. Both
round-1 (caseY) and round-2 (caseR) lean misses are now catches on re-run.

**Honest caveats:** (1) opus run-to-run variance means these are "validated on the case,"
not isolated A/Bs. (2) This run's lean output had a minor grounding blemish (ran a tangential
suite and over-claimed coverage) — reviewer discipline, not a persona defect; worth watching
but not a reflex to add. (3) n is still small; keep adding cases before Phase-2 cutover.
