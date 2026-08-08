# Archived — superseded by lean personas (2026-08-08)

Everything in this directory is the **old invariant-corpus PR-review apparatus**,
retired from the live path in the Phase-2 lean-persona cutover. It is kept for git
history / rollback only — **do not wire it back in.** It may be hard-deleted after a
cycle of production confidence in the personas.

## What's here and what replaced it

- `review-knowledge/` — the per-domain `INV-*` invariant corpus (`general.md`,
  `parsers.md`, `openai_frontend.md`, the `_manifest.md` router, `_seed/` candidates,
  and its own `RUNBOOK.md`). It was injected into the reviewer as `$GC_PR_KNOWLEDGE`.
- `mine-review-comments.sh` + `distill-prompt.md` — the miner that seeded corpus
  candidates from maintainer review comments.
- (Also retired, from the pack itself: `pr-review-pack/commands/learn/` — the `gc
  pr-review-pack learn` appender. Removed via `git rm`; recover from git history.)

**Replaced by:** activation-routed **personas** at `tools/vllm/review-personas/`
(`base.md` always + domain personas that self-route via their `**Activates on:**`
headers), injected into the reviewer as `$GC_PR_PERSONAS`. A blind bake-off (6 cases)
showed the lean personas match/beat this corpus at ~4–5× less injected context.

## The flywheel now

There is no more mine → distill → curate → `learn` pipeline. **The flywheel is: edit
the persona file.** A real maintainer miss becomes one counterfactual reflex added to
the right persona, validated against a blind case. The whole workflow + quality bar
lives in `tools/vllm/review-eval/RUNBOOK.md`.
