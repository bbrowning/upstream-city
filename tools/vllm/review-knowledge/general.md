# general — cross-cutting vLLM review invariants
<!-- id-prefix: GEN -->

The bounded flywheel that applies to **every** vLLM change (loaded alongside any
domain file). Keep entries terse: `[ID] one-line rule — why: the failure it
prevents (provenance)`. Append harvested/seeded rules under "Learned / seeded".

Provenance tags: `(starter)` = hand-authored baseline; `(PR #N, @author)` = mined
from a maintainer review comment; `(learned PR #N)` = folded back from a review the
human corrected.

## Invariants

- [INV-GEN-001] Public API changes (`LLM`, `SamplingParams`, `EngineArgs`, CLI
  flags, OpenAI request/response fields) must be backward compatible — additive,
  deprecate-don't-remove. — why: silent user-facing breakage. (starter)
- [INV-GEN-002] New `EngineArgs`/`ModelConfig`/config fields must plumb through and
  round-trip (CLI ↔ config object ↔ any serialization), not be silently dropped.
  — why: config that parses but never takes effect. (starter)
- [INV-GEN-003] Hot-path changes (scheduler step, model-runner loop, sampling)
  must not add host↔device syncs, `.item()`/`.cpu()` calls, or per-step Python
  overhead. — why: throughput/latency regressions invisible in unit tests. (starter)
- [INV-GEN-004] Changes that affect sampling/output must preserve seeded
  determinism where vLLM promises it. — why: reproducibility guarantees. (starter)
- [INV-GEN-005] The diff should do only what it claims — flag unrelated or
  accidental changes, especially in risky paths. — why: scope creep hides defects.
  (starter)
- [INV-GEN-006] Tests must assert observable behavior through public APIs, not just
  execute the code path; new behavior needs a test that would fail without the
  change. — why: fake coverage (see repo AGENTS.md). (starter)
- [INV-GEN-007] Model-affecting changes (accuracy/output/serving) should carry eval
  or benchmark evidence, not just unit tests. — why: correctness regressions in
  generation quality. (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area general --invariant "..." --from-pr N  appends here -->
