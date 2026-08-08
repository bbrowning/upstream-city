# Bake-off results (round 2) — current pack vs lean persona (parser + one OOD)

Blind isolated A/B, same protocol as `run-2026-08-08/`. Arm A = current reviewer brief
(`prompt.template.md`) + `review-knowledge/` corpus (forced `trusted`). Arm B = lean
brief + matching persona(s). Same model (opus) both arms, identical blind inputs (diff +
detached head checkout + CPU venv + free read-only pytest), air-gapped. One neutral blind
judge per case (could run tests + had the answer key). Three **new** real-world cases,
each reconstructed from the original pre-review head (the commit @bbrowning/@yzong-rh
actually reviewed), fix/comments withheld.

De-blind map: caseR R1=A,R2=B · caseW R1=B,R2=A · caseG R1=A,R2=B.

## Cases (all verified: a trusted maintainer gave substantive feedback pre-merge)
- **caseR — vllm#47606** (gold; parser). `DelegatingParser` reasoning→tool transition for
  the mixed **engine-based reasoning parser + non-engine tool parser** case. @bbrowning
  requested changes: the `decode(current_token_ids)` recovery isn't multi-token-char safe
  (should flush via the reasoning parser like the `if self._engine_based` branch), and the
  coverage is a fabricated fixture, not real qwen3-reasoning + hermes-tool.
- **caseW — vllm#48846** (parser). MiniMax M2 arg converter drops `.strip()` to preserve
  whitespace (correct). @yzong-rh gave test nits; the higher-signal call is **cross-model
  blast radius** — the sibling `_qwen3_arg_converter` has the identical `.strip()` bug
  (the real PR grew to fix qwen3 + minicpm5xml).
- **caseG — vllm#44993** (OUT OF DOMAIN: structured output + spec decode; no persona
  activates). `should_advance()` gains a `new_token_ids` delta window (fixes #43388) and
  now **mutates grammar state inside the query method**. @yzong-rh challenged the design
  (surprising side-effect) and the necessity of the defer+drain machinery. Included to
  probe the domain-coverage gap.

## Scorecard (de-blinded; A=current, B=lean)

| Case | Blind-judge winner | Signal A/B | Noise A/B | Grounded A/B | Gold catch A/B |
|------|--------------------|-----------|-----------|--------------|----------------|
| R (gold, 47606) | **tie** | 0 / 0 | 0 / 0 | 4 / 4 | miss / miss |
| W (48846) | **B (lean)** | 0 / 1 | 0 / 0 | 4 / 5 | miss / **catch** |
| G (44993, OOD) | **B (lean)** | 1 / 1 | 1 / 0 | 4 / 5 | miss / miss |
| **Total** | **lean 2 – 0 (1 tie)** | **A 1 / B 2** | **A 1 / B 0** | **A 4.0 / B 4.67** | **B 1 / A 0** |

Context cost (injected per review, lines / words):
- parser cases (R, W): **A = 434 / 3,679** vs **B = 121 / 1,082**
- no-domain case (G): **A = 361 / 2,898** vs **B = 53 / 459**
- across all 3: **A = 1,229 / 10,256** vs **B = 295 / 2,623** → **~4× leaner** (lines),
  ~3.9× (words).

## What each got right/wrong (judge-verified)
- **caseR (gold) — SHARED MISS.** Both approved with 0 findings. Neither flagged that the
  new else-branch `self.model_tokenizer.decode(current_token_ids)` has no holdback for
  multi-token characters (the sibling `if self._engine_based:` branch does it right via
  `finish_streaming()`/`flush_delta.content`), and neither challenged the fabricated
  `_FakeEngineReasoningParser` as inadequate coverage. Lean (B) came closest — it ran the
  combined engine reasoning+tool suites, enumerated which real parsers set
  `engine_based_streaming=True`, and *noticed* the test pairs a fake reasoning parser with
  a real Hermes tool parser + real Qwen3 tokenizer — but framed the fake as adequate
  rather than a gap, so it didn't rise to `partial`. **This is the actionable gap this
  round.**
- **caseW — lean wins (gold catch).** Lean (B) flagged the sibling `_qwen3_arg_converter`
  still `.strip()`s at lines 65/74 (same defect class, concrete corrupted-value example,
  correctly scoped as follow-up) — the cross-model blast-radius reflex firing. Current (A)
  approved with 0 findings and never raised the cross-model gap. (Judge note: neither
  named `minicpm5xml`, the other sibling the real PR fixed.)
- **caseG (OOD) — lean wins narrowly, both miss gold.** Neither surfaced the
  query-method-with-side-effect smell or the "is the defer+drain even needed" necessity
  argument (expected — no structured-output persona). Current (A) paired a real minor
  (now-inaccurate `reasoning_end_token_index` field comment) with a generic "add
  integration coverage" suggestion (scored noise); lean (B) gave one concrete, verified
  finding (the three `should_advance` callers now diverge on delta-window semantics) and
  ran extra cross-component suites.

## Conclusion
Consistent with round 1: **lean is at least equivalent, and here modestly ahead (2–0, 1
tie), at ~4× less context** — better signal (2 vs 1), less noise (0 vs 1), higher
groundedness (4.67 vs 4.0), and the only gold catch. n is now 6 cases total; the picture
is stable ("competitive-to-better, far leaner"), not a blowout.

**Two gaps to fix (flywheel):**
1. **caseR (lean miss, in-domain) → sharpen the parser persona.** The reflexes existed
   (fixtures-match-real-output; token-ids-over-text) but didn't fire hard enough on a
   *fabricated combined-flow fixture* or on *raw `decode()` of a token-id slice*. Add one
   counterfactual reflex making both non-negotiable. (Applied — see `personas/parser.md`.)
2. **caseG (shared miss, out-of-domain) → the domain-coverage gap.** (a) A generic,
   cross-cutting lesson — *a predicate/query-named method (`should_*`/`is_*`/`has_*`) that
   mutates state is a surprising side-effect* — belongs in `base.md` (applied). (b) Whether
   to stand up a **structured-output / spec-decode** persona is a scoping call for a human:
   n=1 so far; per the promotion rule, watch for recurrence before adding a whole domain.

## Reproduce
Cases live in `cases/case{R,W,G}/` (diff + meta + answer-key). Per-case detached
worktrees at head + CPU venvs were built under `.wt/case{R,W,G}/` via
`tools/vllm/vllm-testenv.sh`. Arm/judge outputs + the private blind map are in this dir.
