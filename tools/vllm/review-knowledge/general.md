# general — cross-cutting vLLM review invariants
<!-- id-prefix: GEN -->

Loaded on **every** vLLM review, layered under any domain file. Shape:
`[ID] rule — why: the failure it prevents (provenance)`. The rule states *what* to
check (imperative; no how-to / no command — that's the reviewer's method); the why is
one clause. Append learned/seeded rules under "Learned / seeded".

Provenance: `(starter)` baseline · `(PR #N, @author)` mined from a maintainer comment ·
`(learned #N)` folded back from a corrected review.

## Invariants

- [INV-GEN-001] Public Python/CLI API changes (`LLM`, `SamplingParams`, `EngineArgs`,
  CLI flags) must stay backward compatible — additive, deprecate-don't-remove. — why:
  silent user-facing breakage. (OpenAI HTTP fields → INV-OAI-005.) (starter)
- [INV-GEN-002] New `EngineArgs`/`ModelConfig`/config fields must round-trip (CLI ↔
  config object ↔ serialization), not be silently dropped. — why: config that parses
  but never takes effect. (starter)
- [INV-GEN-003] Hot-path changes (scheduler step, model-runner loop, sampling) must not
  add host↔device syncs, `.item()`/`.cpu()`, or per-step Python overhead. — why:
  throughput regressions invisible to unit tests. (starter)
- [INV-GEN-004] If the change touches sampling/RNG/output ordering, a fixed `seed` must
  still reproduce identical output independent of batch size/composition. — why:
  order-dependent reductions break seeded reproducibility. (starter)
<!-- [INV-GEN-005] retired 2026-08-07: generic code-review truism ("diff does only
  what it claims"), not vLLM-specific and already the prescan/triage's job — noise.
  ID left as a tombstone; never reuse it (citation IDs must be stable). -->
- [INV-GEN-006] New behavior needs a test that fails without the change and asserts
  observable behavior through public APIs, not just executes the path. — why: fake
  coverage (repo AGENTS.md). (starter)
- [INV-GEN-007] Model-affecting changes (accuracy/output/serving) should carry eval or
  benchmark evidence, not only unit tests. — why: generation-quality regressions.
  (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area general --invariant "..." --from-pr N  appends here -->
- [INV-GEN-008] Flag when another open PR edits the same function/hunk — competing in-flight fixes are a merge/coordination risk even when each is correct. — why: piecemeal merges conflict and entrench divergent designs. (learned #51391)
