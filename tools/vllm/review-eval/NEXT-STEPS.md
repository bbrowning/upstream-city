# NEXT STEPS — validate lean personas, then cut over

State as of 2026-08-08: **two** blind bake-offs done (6 cases total). Round 1 (3 cases):
lean ≈ current at ~5× less context (`run-2026-08-08/RESULTS.md`). Round 2 (3 new cases:
caseR/W/G): **lean 2–0 (1 tie)** at ~4× less context — better signal (2 vs 1), less noise
(0 vs 1), higher groundedness, only gold catch (`run-2026-08-08b/RESULTS.md`). Two persona
edits applied from round-2 misses (caseR → parser fixture/decode reflexes; caseG →
base query-method-side-effect reflex). See memories [[pr-review-lean-persona-pivot]] +
[[pr-review-eval-harness]]. Lean setup = `brief-lean.md` + `personas/{base,parser,
openai-frontend}.md`. Old system to replace = `tools/vllm/review-knowledge/` corpus +
`pr-review-pack/agents/reviewer/prompt.template.md` step-2 load + `commands/learn/` +
`mine-review-comments.sh`. **Keep the security/posture layer untouched — it's out of scope.**

OPEN after round 2: (a) caseR is a still-unresolved **shared gold miss** — the sharpened
parser reflexes are untested; re-run caseR to confirm they now fire before trusting the
gate. (b) **Domain-coverage decision (human):** stand up a `structured-output` /
spec-decode persona? n=1 (caseG) so far — per the promotion rule, watch for recurrence
first. (c) The gate wants "no unresolved misses"; caseR keeps it open → add more cases +
re-run, don't cut over yet.

## Phase 1 — Build confidence (expand the eval)
1. Pick 3–5 candidates from `candidates.md`. For each, FIRST verify @bbrowning or @yzong-rh
   actually gave changes-requested / meaningful feedback (`gh api
   repos/vllm-project/vllm/pulls/<N>/reviews`) — skip clean approves.
2. Blind-reconstruct each per README "Adding a case" (original pre-review head from the
   timeline, `base=merge-base(head,origin/main)`, `git diff base..head`, check out head,
   **delete the fix ref**, hide PR#/comments). Add under `cases/`.
3. Run the A/B: Arm A (current `prompt.template.md` + corpus, gc/posture neutralized to
   `trusted`) vs Arm B (`brief-lean.md` + `base` + matching domain persona). Identical blind
   inputs; per-case worktree + CPU venv; both may run read-only pytest. Re-run caseX/Y/Z too.
4. Blind-judge (neutral, may run tests; answer key only where known). Archive to
   `run-<date>/` with the private blind map.
5. Flywheel each round: every lean MISS → add ONE counterfactual reflex to the right
   persona (prune too). If a specific model keeps generating model-specific findings, spin
   up its persona (Harmony/gpt-oss is the likely first — cluster in `candidates.md`).

**DECISION GATE:** lean matches/beats current on signal & noise across the expanded set, at
lower context, with no unresolved misses → go to Phase 2. Otherwise iterate personas / add
cases and re-run.

## Phase 2 — Cut over (retire the old flywheel), only if the gate passes
6. Home the validated personas where the pack reads them: a persona dir + a tiny manifest
   (changed-path glob → persona; `base` always). Reuse the `GC_PR_KNOWLEDGE` dir or add a
   `GC_PR_PERSONAS` env in `city.toml`'s reviewer `[[rigs.patches]]`.
7. Rewrite `pr-review-pack/agents/reviewer/prompt.template.md`: replace the generic
   checklist + step-2 corpus-load with "load `base` + matching personas"; drop the
   `_seed`/candidate/human-write-gate prose. **Leave every posture / worktree / emit-verdict
   line unchanged.**
8. Retire the apparatus from the live path: the `learn` command (`pr-review-pack/commands/
   learn/`), the miner (`mine-review-comments.sh` + `distill-prompt.md`), `_seed/`, and the
   mine→distill→curate RUNBOOK workflow → replace with a one-paragraph "flywheel = edit the
   persona file (counterfactual bar; prune)". Archive `review-knowledge/` (git history) —
   don't hard-delete until a cycle of production confidence.
9. Repoint the reviewer env in `city.toml`; **Ben runs `gc reload`** to activate the
   prompt/env change (persona *content* edits are runtime-live, no reload).
10. E2E verify on the REAL path (the isolated A/B never exercised production wiring):
    `gc sling vllm/reviewer pr-review --formula --var head_ref=<a fresh open parser PR>` →
    confirm personas load via the new router, posture still gates, verdict is good.
11. Commit to `main`; **Ben harvests + pushes from laptop** (container can't push —
    [[paude-container-credential-model]]). Update memory: mark
    [[pr-review-knowledge-flywheel]] fully superseded; update
    [[pr-review-pack-install-run-sequence]] if the corpus path / `learn` command changed.

Ownership: the agent commits to `main` and does read-only gc/gh; **Ben runs every `gc`
mutation (reload/sling) and all `git push`.**
