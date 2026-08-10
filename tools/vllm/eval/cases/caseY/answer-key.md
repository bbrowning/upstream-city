# Answer key — caseY (vllm#51238)

Ground truth for grading caseY ONLY. This case was a **lean MISS in round 1**
(`run-2026-08-08/`): the current pack (Arm A) caught the coverage gap; lean (Arm B)
hand-verified parity and declared it "thoroughly tested," glossing over the untested
surface. The lesson was folded into `personas/parser.md` reflex #2; this case is the
regression test for that reflex. Correct call is at least `approve_with_nits` with the
coverage gap raised (a strong reviewer may `request_changes` for the missing per-model
tests).

## What the change does
It rewrites `is_reasoning_end_streaming` to an **O(delta)** check (perf fix) not just in the
base/engine, but as a specialized override in **six per-model parsers**:
`vllm/parser/gemma4.py`, `glm47_moe.py`, `inkling.py`, `kimi_k2.py`, `mistral.py`,
`qwen3.py` (plus base `abstract_parser.py` and `engine/{adapters,parser_engine}.py`). The
**only** test touched is `tests/parser/engine/test_parser_engine.py` — the engine/base
level. **Zero** per-model test files are added or changed.

## Why it's a gap (the lesson)
Each of the 6 per-model `is_reasoning_end_streaming` overrides now carries its own
model-specific O(delta) logic. A green engine/base test does NOT exercise those overrides —
an override can silently drift from the base predicate (wrong window, off-by-one on the
delta boundary, a model whose end marker spans the delta) while both the base test and a
broad suite run stay green. The perf rewrite is exactly the kind of change that regresses a
single model's reasoning-end detection without any red test. Each override needs a
parity/regression test asserting it agrees with the intended behavior on that model's
actual token stream — not just the base.

## Grading the gold catch (per review)
- **catch** — identifies that the change specializes `is_reasoning_end_streaming` across the
  base + ~6 per-model parsers while the only new test is engine/base-level, so the
  per-model overrides are untested and can silently drift; demands a per-override
  parity/regression test. Bonus: names specific models (gemma4/glm47/inkling/kimi_k2/
  mistral/qwen3), greps the override sites, or notes a base test + broad suite can both pass
  while an override is wrong.
- **partial** — notes the change touches many per-model parsers OR that the testing is thin
  at the per-model level, but stops short of tying it to base-vs-override drift and does not
  demand per-override coverage.
- **miss** — treats the change as adequately tested (leans on the engine/base test),
  approves without raising the per-override coverage gap; OR hand-verifies parity across the
  overrides and declares it "thoroughly tested" without requiring a test (this was lean's
  round-1 miss — verifying it yourself once is not the same as leaving a regression guard).

## Note for grading
Tests are green at head (the added engine test passes). The gap is a *missing* test, so
grade the gold catch on **reasoning** (visible in the diff: 6 overrides changed, 1
engine-level test), not on a red test.
