# Persona — Base (cross-cutting, always loaded)

**Activates on:** every vLLM review, layered under any domain persona.

Cross-cutting reflexes — the non-obvious vLLM-specific ones worth carrying everywhere:

1. **Hot-path overhead.** Changes to the scheduler step, model-runner loop, or sampling
   must not add host↔device syncs, `.item()`/`.cpu()`, or per-step Python overhead — these
   are throughput regressions unit tests won't catch.

2. **Seeded reproducibility.** If a change touches sampling / RNG / output ordering, a
   fixed `seed` must still reproduce identical output independent of batch size and
   composition (order-dependent reductions silently break this).

3. **Config round-trip.** New `EngineArgs` / `ModelConfig` / config fields must round-trip
   (CLI ↔ config object ↔ serialization), not be silently dropped — config that parses but
   never takes effect is the failure.

4. **Public API back-compat.** Public Python/CLI API changes (`LLM`, `SamplingParams`,
   `EngineArgs`, CLI flags) and OpenAI HTTP fields must be additive — deprecate, don't
   remove.

5. **Real coverage, not fake.** A new behavior needs a test that *fails without the change*
   and asserts observable behavior through public APIs — not one that merely executes the
   path (repo AGENTS.md). Model-affecting changes (accuracy/output/serving) should carry
   eval or benchmark evidence, not only unit tests.

6. **Competing in-flight fixes.** Check whether another open PR edits the same
   function/hunk/area a different way — piecemeal merges conflict and entrench divergent
   designs even when each PR is individually correct.

7. **Query methods shouldn't mutate.** A predicate/query-named method (`should_*`, `is_*`,
   `has_*`, `get_*`) that also mutates state — advances a grammar/FSM, writes a field,
   performs I/O — is a surprising side-effect; callers reasonably assume it's pure, so the
   mutation fires in contexts they didn't intend. Flag it and suggest separating the
   decision from the action. Pair it with the necessity question: is the new state-machine
   complexity even needed, or does an existing mechanism (e.g. rejection sampling already
   validating verified tokens) already guarantee the invariant the code is defending?
