# Bake-off results — current pack vs lean persona (parser reviews)

Blind isolated A/B. Arm A = current 293-line reviewer brief + full 52-invariant corpus
(forced `trusted`). Arm B = lean 22-line brief + 1 parser persona. Same model (opus), same
blind inputs (diff + head checkout + CPU venv + free read-only pytest), air-gapped. Three
neutral blind judges scored Review-1/Review-2 (they could run tests to verify claims).

De-blind map: caseX R1=B,R2=A · caseY R1=A,R2=B · caseZ R1=B,R2=A.

## Scorecard (de-blinded; A=current, B=lean)

| Case | Change | Blind-judge winner | Signal A/B | Noise A/B | Grounded A/B | Gold catch |
|------|--------|--------------------|-----------|-----------|--------------|------------|
| X (gold, 51391) | shared streaming-engine inkling fix, inkling-only tests | **B (lean)** | 0 / 1 | 1 / 0 | 3 / 4 | both **partial** |
| Y (51238) | O(delta) reasoning-end, base + 6 model overrides | **A (current)** | 1 / 0 | 1 / 0 | 5 / 4 | n/a |
| Z (51364) | glm47 optional `<arg_value>` tag | **B (lean)** | 2 / 1 | 0 / 0 | 5 / 5 | n/a |
| **Total** | | **lean 2 – 1** | **A 2 / B 3** | **A 2 / B 0** | **A 4.33 / B 4.33** | |

Context cost (injected per review): **A = 434 lines / 3,679 words** (brief + _manifest +
general + parsers) vs **B = 76 lines / 704 words** (brief + persona) → **~5× leaner**.

## What each got right/wrong (judge-verified)
- **caseX (gold):** Neither blocked it; both only *partial* (neither demanded cross-model
  regression coverage — the real PR was reworked to preserve MiniMax multi-terminal
  wrappers + added ~330 lines of cross-model tests). **B** did a rigorous, judge-verified
  blast-radius analysis (correctly bounded the behavior change to inkling+gemma4) and
  flagged a real thin-streaming-test nit. **A** approved with 0 findings and committed the
  exact fallacy the answer key warns about — "existing engine suite is green ⇒ no
  cross-model regression" (flagged as a false positive by the judge; the catching tests
  didn't exist at that commit).
- **caseY (current wins):** **A** caught a genuine coverage gap — the 6 per-model
  `is_reasoning_end_streaming` overrides have **no parity tests** and can silently drift
  (judge confirmed via grep). **B** hand-verified parity and declared it "thoroughly
  tested," glossing over that untested surface. A real miss for lean.
- **caseZ (lean wins):** **B** empirically verified a truncation→invalid-JSON streaming
  regression (judge reproduced it) + flagged fabricated test fixtures unvalidated vs real
  model output (the persona's fixture-validity reflex). **A** found a lower-value
  whitespace nit.

## Conclusion
- **Over-engineering hypothesis: supported, but not for the hypothesized reason.** The heavy
  brief + 52 invariants did not produce better reviews. A strong frontier model already did
  the high-value investigations *regardless of arm* — both voluntarily ran the full
  cross-model engine sweep on shared-engine changes (Arm A did so despite its brief calling
  for only "one in-scope check").
- **Lean is at least equivalent at ~5× less context** — it edged usefulness (2–1), signal
  (3 vs 2), and noise (0 vs 2, incl. the current pack's one false positive), tied on
  groundedness. n=3, so "competitive + far leaner," not "strictly better."
- **Neither is dominant.** caseY is a real lean miss and points directly at the fix: add one
  reflex — *"shared base + per-model overrides ⇒ every override needs a parity/regression
  test, not just the base."* That is the flywheel working: a real miss → one new
  counterfactual reflex.

## Recommendation
Proceed with the lean-up, but harvest rather than discard: (1) enrich the persona with the
caseY lesson; (2) mine the 52-invariant corpus for the handful of genuinely counterfactual
rules and fold them into personas (drop the obvious/duplicated ones + the dead ceremony);
(3) keep the security/posture layer intact; (4) flywheel = edit the persona file. Consider a
few more cases before deleting the corpus outright.
