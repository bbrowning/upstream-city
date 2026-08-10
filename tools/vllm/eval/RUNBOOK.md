# RUNBOOK — changing a persona and proving it helps

Read this **before editing any file in `tools/vllm/personas/`**. Personas are the live review spec:
a change to them changes every future review. This suite exists so a persona edit is
*validated against a real, blind case* — not merged on a hunch. The mechanics of running
(worktrees, CPU venv, isolated A/B, blind judge) are in `README.md`; this doc is the
**workflow and the quality bar** around them. It is written to be followed months from now
by someone who was not in the room.

## The bar — what earns a place in a persona
Lean personas carry ONLY what a strong frontier model does **not** already do on its own.
Before you add a reflex, it must pass all four tests:

1. **Counterfactual.** A capable model reviewing *without* this line would plausibly miss
   the issue — or not dig far enough to find it. If the model already knows it, or infers
   it from the diff easily, leave it out. (Example from this suite: a "query methods
   shouldn't mutate" reflex was *rejected* — models already know that principle.)
2. **Grounded.** It comes from a real maintainer catch on a real PR, not a guess.
3. **Checkable.** It names a concrete failure or behavior a reviewer can confirm in the
   code or a test — not a vibe or a style preference.
4. **Non-obvious & terse.** State the hard-to-infer kernel and stop; drop mechanism the
   model fills in itself. (Example: the parser "don't decode raw token ids" gotcha keeps
   the one surprising fact — *the detokenizer holds text back, so the id and text streams
   are misaligned* — and drops the U+FFFD / byte-fallback mechanics and the mojibake
   examples.)

Negative knowledge ("do NOT assume X") beats affirmative restatement. **Prune as you add:**
one sharp reflex, not three soft ones. A persona that restates general best practice is
noise that costs context on every review.

**Two consumers now — review AND hard-bug diagnosis.** The personas are injected into the PR
reviewer *and* the hard-bug lanes as one env (`$GC_PERSONAS`) — the same
files. So: (1) validate a persona edit against **both** case families before it ships — a
diagnosis-helping reflex must not add review noise, and vice-versa; (2) keep personas to
**domain facts**; *method* ("prefer static analysis", "ground-truth cheap load-bearing facts
before asserting") lives in the pack prompts, not here — that separation is what lets one
corpus serve both; (3) a **verification reflex** (one that tells a diagnoser to ground-truth
a fact) is a fifth bar test: it must name *what* to fetch and *when* — **cheap AND
load-bearing** — so it can't degenerate into "always fetch everything."

## The flywheel — miss → one reflex → re-run → confirm
**Cases are regression tests for personas.** The loop, every time:

1. **Find a real miss.** A trusted maintainer flagged something a review setup didn't.
   Reconstruct it as a blind case (see *Adding a validation case* below + README
   "Adding a case").
2. **Run the A/B** (README "Running a case"). If the lean arm misses the maintainer's
   catch, that miss is your target.
3. **Add exactly ONE counterfactual reflex** to the right persona — `base.md` (cross-
   cutting), a domain persona (`parser.md`, `openai-frontend.md`), or a per-model persona —
   passing the four-test bar above. Prune anything it makes redundant.
4. **RE-RUN the same case.** The reflex is validated only if: the case moves from
   **miss → catch/partial**, AND the judge shows **no new noise / false positives**.
   Beware the trap this suite actually hit: "noticed but approved anyway" is still a MISS —
   the reflex has to make the reviewer *act*, not just observe.
5. **Archive + commit together.** Put the re-run under `run-<date>/`, and commit the
   persona edit + the case + the run in one commit so the evidence lives with the change
   and anyone can reproduce it.

A reflex that does not flip its case from miss→catch on re-run is not pulling its weight —
rewrite it tighter or drop it. That is the whole discipline.

**Diagnosis cases (hard-bug) are the second case family.** A hard-bug miss — a lane that
guessed a load-bearing fact instead of verifying it, or two lanes that *converged on the same
unverified guess* (correlated error) — reconstructs the same way, with two differences from a
review case: the artifact is a sanitized **bug report** (the arc bead's `description` only,
never its `gc.output_json` answer), and the network rule is a **positive allowlist**, not the
review harness's air-gap — the HF `tokenizer_config.json`/`config.json` fetch *is* the reflex
under test, while the incident's answer (corrected arc state, prior lane beads, this repo's
`run-*/` + memories) stays hidden. Grade the diagnosis, not a diff; "noticed the fact was
uncertain but didn't verify it" is a **MISS**. First case: `cases/caseVPD/` (see its
`meta.json` blind notes). Same bar, same flywheel.

## Adding a validation case — verifying real maintainer feedback
Real cases come from merged/closed PRs where a trusted maintainer (`@bbrowning`,
`@yzong-rh`) gave **substantive** feedback. Two traps, both learned the hard way:

- **The review-level state lies.** A PR can show `APPROVED` while the real, actionable
  feedback lived in *inline review comments*. Do NOT filter on review `state` — pull the
  inline comments and read them:
  ```bash
  gh api "repos/vllm-project/vllm/pulls/<N>/comments?per_page=100" \
    --jq '.[]|select(.user.login=="bbrowning" or .user.login=="yzong-rh")
          | "@\(.user.login) \(.path):\(.line): \(.body)"'
  ```
  Skip clean approves whose only comments are trivial nits — unless the nit *is* the lesson.
- **Reconstruct the PRE-review head, not the merged fix.** Anchor to the commit the
  maintainer actually reviewed: each inline comment carries `original_commit_id`, and that
  SHA is the pre-review head — the code there still contains the problem.
  ```bash
  gh api "repos/vllm-project/vllm/pulls/<N>/comments?per_page=100" \
    --jq '.[]|select(.user.login=="bbrowning" or .user.login=="yzong-rh")|.original_commit_id' | sort -u
  ```
  Then follow README "Adding a case": `base = merge-base(head, origin/main)`;
  `git diff base..head` → `diff.patch`; check out `head`; make sure the **fix commit is
  unreachable** from `head` so the arms can't find it; write `answer-key.md` (grade the
  gold catch on **reasoning** when the catching test was added by the fix). Candidate PRs
  to mine are tracked in `candidates.md`.

## The cutover gate — PASSED 2026-08-08 (cutover done)
The gate for Phase 2 (retiring `review-knowledge/` + the pack's corpus load — see
`NEXT-STEPS.md`) was: lean must **match or beat** the current pack on signal & noise
across the case set, at lower context, with **no unresolved shared gold misses**. That
gate passed (6 cases; both known lean misses converted to catches and re-validated), the
pack was cut over to personas, and the old corpus is archived at
`tools/vllm/_archive/review-knowledge/`. The go-forward loop is the flywheel above: a real
miss → one persona reflex → re-run → confirm.

## Where everything lives
- **Personas (the live review spec):** `tools/vllm/personas/*.md` — the single
  canonical home read by BOTH this harness and the production pack (injected there as
  `$GC_PERSONAS`). `base.md` always loads; each domain persona lists its
  activation-path globs at the top and loads only when a changed path matches.
- **The two methods compared (historical bake-off):** `brief-lean.md` + the personas
  (lean arm, now live) vs the retired pre-cutover pack (the old reviewer prompt in git
  history + the corpus now archived at `tools/vllm/_archive/review-knowledge/`).
- **Cases:** `cases/<id>/{meta.json, diff.patch, answer-key.md?}`.
- **Runs (the evidence):** `run-<date>/` — per-arm `caseX-{A,B}.json`, `judge-caseX.json`,
  `RESULTS.md`, and the private `blind-map.txt` (A=current, B=lean; which arm was shown to
  the judge as Review1/Review2).
- **Scratch (gitignored):** `.wt/<case>/` — the detached worktree at head + its CPU venv,
  rebuilt anytime with `tools/vllm/vllm-testenv.sh --src .wt/<case>` (see README).
- **Shared rules:** `harness-rules.md` (every review arm) and `judge-rules.md` (the judge).
