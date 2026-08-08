# review-eval — a growing eval suite for vLLM PR review

Purpose: compare review setups (current pack vs lean personas) and regression-test the
**lean personas** as they evolve. Blind, reproducible, offline.

> **Changing a persona?** Read `RUNBOOK.md` first — it's the workflow + quality bar for
> validating a persona edit against a blind case (this README is the mechanics it builds on).

## Layout
- `cases/<id>/` — `meta.json` (source PR, base/head SHAs, changed files, blind notes),
  `diff.patch` (the change under review), `answer-key.md` (only where we know the ground
  truth).
- `personas/` — `base.md` (always loaded) + domain personas (`parser.md`,
  `openai-frontend.md`). The lean setup under test.
- `brief-lean.md` — the lean reviewer method.
- `harness-rules.md` — shared read-only/blind/output-schema rules for every review arm.
- `judge-rules.md` — the neutral blind judge rubric + output schema.
- `run-<date>/` — archived arm outputs + judge scores + RESULTS.md + the (private) blind map.
- `candidates.md` — real-world PRs to reconstruct into new cases.

## Persona selection
Always load `personas/base.md`, plus every domain persona whose activation paths (top of
each file) match the PR's changed files. Keep it lean; don't load domains the PR doesn't
touch.

## Running a case (isolated A/B, via the Agent tool — NOT gascity)
1. Worktree at head + CPU venv: `git worktree add --detach <wt> <head_sha>` then
   `bash tools/vllm/vllm-testenv.sh --src <wt>` (see [[vllm-cpu-testenv-recipe]]).
2. Launch the review arm(s) as `general-purpose` subagents, model `opus`, each told to read
   `harness-rules.md` first, then its method:
   - **Arm A (current pack):** read `pr-review-pack/agents/reviewer/prompt.template.md`,
     neutralize gc/posture (treat `trusted`, write JSON to OUT), load corpus via
     `tools/vllm/review-knowledge/_manifest.md`.
   - **Arm B (lean):** read `brief-lean.md` + `personas/base.md` + matching domain persona.
   Give both: the `diff.patch`, the worktree, base/head SHAs, the venv python. Both may run
   read-only pytest (`PYTHONPYCACHEPREFIX=$(mktemp -d) <py> -m pytest <ids> -q -p no:cacheprovider`).
3. Judge: strip A/B identity, copy to `Review1`/`Review2` with a private randomized map,
   leak-scan for method tells, then run one `judge-rules.md` judge per case (it may run
   tests to verify claims). Provide `answer-key.md` only where present.

## Adding a case — blind reconstruction of a merged / force-pushed PR
The taint to avoid: the review comments and the merged fix. Recipe:
1. `gh api repos/vllm-project/vllm/issues/<N>/timeline` → find the **original pre-review
   head** (the SHA the `reviewed`/`changes_requested` event points at, before any
   `head_ref_force_pushed`). That head still contains the problem.
2. `base = git merge-base <head> origin/main`; `git diff <base> <head>` → `diff.patch`.
3. Check out `<head>`; **delete the fix ref** (`git update-ref -d refs/...`) so arms can't
   discover it. Never expose the PR#, comments, or merge verdict; instruct arms to air-gap
   (no gh/web).
4. Note in `meta.json` whether existing tests are green at the original head — if the
   catching test was added by the fix, grade the gold catch on **reasoning**, not a red test.

See `run-2026-08-08/RESULTS.md` for the first run. Methodology + outcome in memory:
[[pr-review-eval-harness]], [[pr-review-lean-persona-pivot]].
