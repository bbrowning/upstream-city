# run-2026-08-10 — caseVPD blind replay (hard-bug verification gap: A+B+C)

**Question:** does the A+B+C fix bundle close the gap that let the original `vllm-vpd` run
ship a confident diagnosis resting on a *guessed* token identity (200028), and does it do so
without new noise?

**Family:** diagnosis (first hard-bug case). Blind boundary + positive HF allowlist per
`cases/caseVPD/meta.json` and `harness-rules-hardbug.md`. Arms run standalone via the Agent
tool (general-purpose subagents), NOT gascity. Code at vLLM `41e7746b8`.

Ground truth (verified, `thinkingmachines/Inkling-Small-NVFP4`): **200028 = `<|begin_of_text|>`**
(a BOS) — not `<|end_message|>` (200010), not the EOS `<|content_model_end_sampling|>` (200006).

## Part 1 — lane behavior (blind diagnosis)

| arm | setup | token 200028 | fetched tokenizer? | confidence | judge verdict |
|-----|-------|--------------|--------------------|------------|---------------|
| baseline-opus | OLD method, no personas | **guessed** `<\|end_message\|>`/terminator, *deferred* the check | no | medium | **MISS** |
| treat-sonnet | A+B (method + personas) | `<\|begin_of_text\|>` ✓ | yes | medium | catch |
| treat-opus | A+B (method + personas) | `<\|begin_of_text\|>` ✓ | yes | high | catch |
| bonly-opus | B only (method, no personas) | `<\|begin_of_text\|>` ✓ | yes | medium | **strong-catch** |

Judge was blind to arm identity (anonymized `review1..4`, private `blind-map.txt`).

- **The gap is closed: miss → catch.** baseline reproduces the exact incident in-harness —
  it guessed a block terminator and pushed the tokenizer decode into `verification_plan`
  ("noticed but didn't verify" = MISS). Every fixed arm fetched `tokenizer_config.json` and
  got 200028 = `<|begin_of_text|>`. Notably baseline's *mechanism* was still correct
  (GOLD-2=yes) — confirming the original run's generic mechanism held; the sole failure was
  the unverified keystone, which is exactly what this case tests.
- **B (the method fix) is the decisive lever; A (personas) is complementary.** `bonly-opus`
  — the method fix with **no personas** — was the single strongest diagnosis (verified
  keystone + the full generic mechanism: terminated grammar, full mask, `accept_tokens`
  False via `_is_terminated`, missing `is_terminated()` guard + the BOS-anomaly second-bug
  hypothesis). This matches the red-team's P1 prediction and validates the design principle
  *method lives in the prompt, domain facts in the personas*: the fetch behaviour is driven
  by the prompt rule, not the persona. A remains worth shipping for generality (bugs where
  the method won't name the specific fetch) and for the shared-corpus goal, but it is not
  what closes this case.
- **Residual noise (all mild, none fabricated):** treat-opus over-elevated an *unconfirmed*
  async/MTP speculative-decoding trigger at `confidence:high` (the confidence-cap rule fired
  on named-fact keystones but not on this unverified *mechanism* link — see follow-up);
  treat-sonnet is the weakest catcher (verified the keystone but misframes the defect as
  "grammar correctly rejects, filter special tokens", GOLD-2 partial) and tagged some
  reasoning-derived claims `verified` without a source; redundant repeat-fetches in
  treat-opus/bonly. No arm invented findings.

## Part 2 — coordinator convergence gate (C)

| arm | input | aligned | gate_fired | next_action | meaning |
|-----|-------|---------|------------|-------------|---------|
| reconcile-old | frozen original lanes (agree-but-unverified) | **true** | n/a | advance_phase | reproduces the incident: bakes the guess into agreed_root_cause |
| reconcile-new | same frozen lanes | **false** | (verify_bounce) | relay_next_round | gate fires: directed bounce to fetch the 200028 identity |
| reconcile-new-verified | the two *verified* treatment lanes | false | **false** | relay_next_round | **no over-bounce** — the gate correctly does NOT fire on verified keystones |

- **C fires exactly when it should.** On the original agree-but-unverified pair the NEW
  rubric flips `aligned=true → false` with a `verify_bounce` naming the tokenizer fetch; the
  OLD rubric advances (the incident).
- **No permanent stall / no misfire.** On two lanes that both *verified* the keystone, the
  gate does not fire (`gate_fired=false`). The NEW coordinator still relayed another round —
  but explicitly *"for a substantive mechanism reconciliation (not a verify-bounce)"*,
  because the two treatment lanes genuinely diverge on mechanism (opus's timing-race +
  tolerant/fatal asymmetry vs sonnet's weaker "filter special tokens"). That is the
  two-opinion protocol working as designed — it distinguishes a correctness gate from a real
  disagreement, and would converge on the stronger (opus/bonly) mechanism next round.

## Verdict
All pass criteria met: miss→catch (Part 1), aligned→verify_bounce (Part 2), no over-bounce
on verified inputs, no fabricated noise. **A+B+C validated; B is the load-bearing fix.**
Ready to propose live (pending Ben `gc reload`).

## Follow-ups surfaced
- **Confidence-cap scope.** The cap ("unverified keystone ⇒ confidence ≤ medium") caught
  named-fact keystones but not treat-opus's unverified *mechanism* link (async/MTP trigger).
  Consider extending the rule to a load-bearing unverified *mechanism* step, not just a
  named fact. (Method/prompt tweak; not a blocker.)
- **The real second bug** the corrected token identity exposes: *why does inkling-small emit
  `<|begin_of_text|>` after a completed JSON payload?* treat-opus/bonly both raised it
  (render/parse or boundary-race). Worth a dedicated hard-bug arc.

## Reproduce
Arms are Agent-tool subagents (see the parent session). Inputs: `cases/caseVPD/`
(bug-report.md, answer-key.md, meta.json, orig-lane-{a,b}.json), worktree
`.wt/caseVPD` @ 41e7746b8, `harness-rules-hardbug.md`. Outputs + `blind-map.txt` here.
