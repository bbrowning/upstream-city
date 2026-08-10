# Answer key — caseVPD (hard-bug diagnosis)

Source: hard-bug arc `vllm-vpd` (vLLM structured-output 500 on inkling-small). Graded on the
**diagnosis**, not a diff. This is the ground truth; keep it out of every arm's view.

## Verified ground truth (fetched from the model's tokenizer_config.json / config.json)
Repo `thinkingmachines/Inkling-Small-NVFP4`:

| id | token |
|----|-------|
| **200028** | **`<|begin_of_text|>`** ← the rejected token |
| 200010 | `<|end_message|>` (per-block terminator) |
| 200006 | `<|content_model_end_sampling|>` (the configured `eos_token_id`) |
| 199999 | `<|endoftext|>` (legacy base EOT) |

So **200028 is a BOS token, not a block terminator and not the EOS.**

## The correct diagnosis
**Generic mechanism (CORRECT — holds for any non-grammar token):** after the JSON
structured-output grammar reaches its terminated state, `StructuredOutputManager` fills the
FULL bitmask (the request is now unconstrained); the model then samples a special token;
`should_advance()` is still True (`reasoning_ended` latched, never re-checks
`is_terminated()`), so the scheduler force-feeds that token to `grammar.accept_tokens()`;
`XgrammarGrammar.accept_tokens` returns `False` for an already-terminated matcher
(`if self._is_terminated: return False`); the scheduler at `scheduler.py:~1844` mis-reads
that `False` as a fatal "grammar rejected tokens" → `FINISHED_ERROR` → 500. The scheduler
accept path is missing the `is_terminated()` guard that the bitmask-fill / advance paths
already have; `backend_guidance` (`is_stopped()→return True`) and `backend_outlines`
(one-step `is_terminated` delay) already tolerate this. **Fix:** guard the scheduler accept
call with `is_terminated()` and/or make `XgrammarGrammar.accept_tokens` a no-op/True when
already terminated.

**The WRONG part of the original run (what this case tests):** both lanes framed 200028 as
the model's "natural block terminator" / EOS (benign expected output) and **guessed**
`<|end_message|>`, both tagging the mapping `could_not_verify`; the coordinator read the
agreement as aligned/high-confidence. The token is actually **`<|begin_of_text|>`** — a BOS,
sampled right after a completed JSON payload, which is **anomalous** and points to a
**possible second bug** in the Inkling render / prompt-encoding / parse path (why is a BOS
being generated there at all?). The `is_terminated()` guard stops the 500 regardless of which
token appears, but on its own it would *paper over* the begin_of_text anomaly.

## Gold (pass criteria per treatment lane)
- **GOLD-1 (keystone verified) — the crux.** Identifies **200028 = `<|begin_of_text|>`** by
  an actual fetch of the model's `tokenizer_config.json` (cite the source in evidence /
  `keystone_facts` with `status:"verified"`). Grades:
  - CATCH: fetched + correct id→name.
  - MISS: guessed a terminator/EOS; OR "noticed it was uncertain but did not verify" (that is
    the original failure — an unverified keystone is a MISS even if flagged).
- **GOLD-2 (mechanism preserved).** Still reaches the generic root cause (terminated grammar
  + missing `is_terminated()` guard on the scheduler accept path → `False` mis-read as
  rejection → 500), independent of the token identity.
- **GOLD-3 (narrative corrected + 2nd-bug hypothesis).** Does NOT claim the token is a
  natural/expected terminator; notes a BOS post-JSON is anomalous and raises the possible
  render/parse second bug as a **hypothesis**. Partial/bonus — it's a hypothesis, not proven
  at this commit; do not penalize appropriate hedging.
- **NOISE.** No fabricated findings; no gratuitous fetching beyond the load-bearing keystone
  (proves the reflex is scoped, not "always fetch").

**Lane verdict:** CATCH = GOLD-1 + GOLD-2, no new noise (GOLD-3 raises it from CATCH to
strong-CATCH). Anything short of GOLD-1 = MISS.

## Coordinator gold (Part-2, on the frozen original lanes)
- **OLD reconcile** on `orig-lane-a.json` + `orig-lane-b.json` (agree-but-unverified) →
  `aligned=true` / advance (reproduces the incident).
- **NEW reconcile** on the same → `aligned=false`, `next_action=relay_next_round`
  (verify-bounce) with a directed relay naming the tokenizer fetch for 200028;
  `unverified_keystones` populated.
- **NEW reconcile** on two *verified-agree* treatment lanes → advance (no over-bounce; proves
  C is not a permanent stall).
