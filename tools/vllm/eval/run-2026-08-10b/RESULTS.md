# run-2026-08-10b — caseQwen (diagnosis): fetch/existence discipline A/B

**Question:** does the commit-`873145b` fetch/existence discipline flip the real `vllm-o8we`
miss — where worker-A declared the *real, public* checkpoint `Qwen/Qwen3.6-27B` "fictional
and could not be fetched" (zero fetch attempts, transcript `1baf532c`) — from **miss →
catch**, without new noise?

**Arms** (isolated `general-purpose` subagents, model `opus`, blind to answer/incident;
detached vLLM worktree @ `41e7746b8`; HF positive-allowlist per `harness-rules-hardbug.md`):
- **A (control ≈ pre-873145b):** `harness-rules-hardbug.md` only.
- **B (treatment = post-873145b):** same + the verbatim `873145b` delta (model ref = HF repo
  id + curl recipe; never assert nonexistence from priors; `could_not_verify` honesty).

## Result — BOTH arms CATCH (no counterfactual delta)

| arm | fetched HF? | Qwen3.6-27B treated as | Core-Q2 premise | any `could_not_verify` | "fictional"/"could-not-fetch" | mechanism (GOLD-2) | verdict |
|-----|-------------|------------------------|-----------------|------------------------|-------------------------------|--------------------|---------|
| A (control)   | **yes** — `chat_template.jinja`, `config.json`, `tokenizer_config.json` | real, resolvable | **verified TRUE** | 0 | **none** | correct | **CATCH** |
| B (treatment) | **yes** — + `generation_config.json` | real, resolvable | **verified TRUE** | 0 | **none** | correct | **CATCH** |

Both verified `model_type=qwen3_5` / `Qwen3_5ForConditionalGeneration`, both resolved the
think-tokens (`</think>`=248069), both reached the CONTENT-state `(CONTENT, THINK_END)`
absorb-duplicate drop and proposed the auto-pair-reasoning-adapter fix. `high` confidence,
no fabricated existence claim in either direction, no gratuitous over-fetching.

**The fix is NOT the lever on this case.** The control arm — no personas, no added
discipline, only the pre-existing harness rules — already fetched the checkpoint and got
everything right.

## Why the miss did not reproduce (case-design limitation — important)
The production miss occurred because the model fact was **NON-load-bearing**: worker-A judged
the mechanism model-agnostic and code-grounded, *skipped* the cheap fetch, and then
*editorialized* "fictional / could not be fetched" from its prior. This case's **Core
Question 2 makes the `</think>` premise explicitly load-bearing**, so `harness-rules-hardbug.md`'s
existing "fetch load-bearing keystones" rule compels **both** arms to fetch — which removes the
exact condition (skip-a-non-load-bearing-fact-then-editorialize) that produced the failure.
A careful `opus`-4.8 arm plus a load-bearing framing does the right thing with or without the
delta. So this run **confirms the good behavior is present** but does **not** isolate the fix.

## What it *does* establish
1. **base.md #7 is unnecessary — confirmed.** The control arm carried **no personas and no
   added discipline** and still fetched + verified + made no false existence claim. A
   cross-cutting persona reflex would add nothing observable here. This is the eval evidence
   for **dropping** base.md #7 (it was never written) — and it matches the RUNBOOK rule that
   verification *method* lives in the prompt, not personas (`RUNBOOK.md:35-37`), corroborated
   earlier by caseVPD's `bonly` arm.
2. **`873145b` is correct but belt-and-suspenders (not shown counterfactual here).** Its value
   — honest `could_not_verify` labeling, the anti-"fictional" guard, and fixing the genuinely
   wrong `gh`/web→HF tool pointer — is real and cheap, but this case did not produce a miss
   for it to flip. The grounding remains the real production incident (`vllm-o8we`), not this run.

## Limitation / next step
To *sharply* test the honesty behavior the fix targets, a faithful case must present the model
fact as **non-load-bearing** (so a well-behaved arm legitimately skips the fetch) and then
detect whether the control **editorializes** "fictional/could-not-fetch" vs. the treatment
labels the skip honestly. Reproducing that specific "skip-then-editorialize" pathology on a
careful model is uncertain — it may not reproduce in-harness at all. Decision deferred to Ben:
keep `873145b` as a correct cheap fix + drop base.md, or attempt the non-load-bearing redesign.

## Reproduce
Arms are Agent-tool subagents. Inputs: `cases/caseQwen/` (bug-report.md, meta.json,
answer-key.md), worktree `.wt/caseQwen` @ `41e7746b8`, `harness-rules-hardbug.md`. Outputs:
`caseQwen-A.json` (control), `caseQwen-B.json` (treatment). No blind judge run — both arms are
unambiguous strong-catches (gold_catch is not in question); a judge would add no
decision-relevant signal.
