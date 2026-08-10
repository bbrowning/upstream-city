# Answer key — caseG (vllm#44993)

Ground truth for grading caseG ONLY. **Domain note:** this change is in structured
output + spec decode (`vllm/v1/structured_output/`, `vllm/v1/core/sched/`), which no
domain persona currently covers — it is included to probe the persona/domain gap. The
change is not obviously *broken*; @yzong-rh's substantive feedback was a **design +
necessity** challenge, and the code was reworked before merge. The findings here are
subtle and not test-detectable — grade on **reasoning only**.

## What the change does
`StructuredOutputManager.should_advance(request)` gains a `new_token_ids` parameter and:
1. Uses `new_token_ids` directly as the current-step delta window instead of the
   placeholder-derived math (`num_computed_tokens - num_output_placeholders`), fixing a
   real bug (#43388): under async scheduling + spec decode with rejected drafts, the
   placeholder count stays > 0 and the computed window starts *past* the reasoning-end
   marker, so `</think>` is missed.
2. For **deferred** backends (JSON/regex/choice/grammar), on the step reasoning ends it
   now drains the post-marker tail of `new_token_ids` into the FSM via
   `grammar.accept_tokens(request.request_id, post_marker)` — **inside
   `should_advance()`** — tolerating rejection with a `logger.warning`.

## @yzong-rh's substantive review (the gold signal)
1. **Surprising side-effect in a query method.** `should_advance()` reads as a predicate
   ("should we advance?") but now *mutates* grammar state via `accept_tokens`. That
   hidden side-effect is surprising and error-prone; the advance/mutation should be
   separated from the should-we-advance decision. (Directly quotable: "We should avoid
   modifying the grammar state inside `should_advance()` if we can since it's a somewhat
   surprising side-effect imo.")
2. **Is the deferral + drain even needed anymore?** The reviewer argued the whole
   "defer JSON/regex/choice/grammar backends + drain post-marker tail" machinery may be
   unnecessary now that reasoning is detected and trimmed correctly:
   - Draft tokens are never grammar-constrained in vLLM; `grammar_bitmask` + rejection
     sampling already guarantee that only grammar-valid tokens are *verified*, so by the
     time `accept_tokens` runs the tail is already valid.
   - There is nothing special about JSON/regex vs `STRUCTURAL_TAG` — the structural-tag
     path already un-defers and works fine (post the #44297 fix).
   - The reviewer ran an E2E JSON repro (Qwen3 MoE, 50/50 schema-valid) **without** the
     deferral and saw 0 failures.
   The high-value call is to **question whether the deferral/drain complexity earns its
   keep** and push for the simpler design (detect + trim, don't defer), rather than
   accept the added branching + the in-predicate grammar mutation.

## Grading the gold catch (per review)
- **catch** — surfaces EITHER (a) the surprising grammar-state side-effect inside the
  query-named `should_advance()` and argues advance should be separated from the
  decision, OR (b) that the defer-backends + post-marker-drain machinery may be
  unnecessary / over-complex given rejection sampling already validates verified tokens
  (bonus: notes STRUCTURAL_TAG already works un-deferred; questions the design vs just
  fixing the #43388 delta-window bug).
- **partial** — notes the `new_token_ids` delta-window fix is good and correctly scoped
  but only gently flags the added drain complexity or the naming/side-effect without
  making the design/necessity argument; or raises a related but weaker concern (e.g.
  just "add a comment").
- **miss** — approves as-is with no design/side-effect/necessity concern; or invents a
  false correctness bug in the (correct) `new_token_ids` window logic. Note: this case
  is out-of-domain for the personas, so a miss here is expected signal about the gap,
  not necessarily a reviewer failure — record whether the miss was for lack of a
  structured-output lens.
