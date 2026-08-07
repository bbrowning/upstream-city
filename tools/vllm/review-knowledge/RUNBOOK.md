# Review-knowledge RUNBOOK — how to grow & curate the PR-review flywheel

Operational guide for this directory: what it is, how the reviewer uses it, and the
exact steps to add/curate/accept invariants. For the *design* rationale (why per-domain,
posture gating) see the pack + the project memory; this file is the day-to-day procedure.

## What's here
- `general.md` — cross-cutting invariants, loaded on **every** review.
- `<domain>.md` (`parsers`, `openai_frontend`, …) — per-domain invariants, loaded only
  when a PR touches that domain. (`parsers` unifies tool-call + reasoning + the shared
  Parser Engine — they interact and share a substrate.)
- `_manifest.md` — the router: changed-path substring → which `<domain>.md` to load.
- `_seed/` — miner output: `<domain>.candidates.md` (curate → accept) and
  `candidates-raw.jsonl` (raw mined comments; git-ignored).

Each invariant is one line: `[ID] rule — why: the failure it prevents (provenance)`.
The **rule states *what* to check** (imperative; no how-to, command, or inline example —
those are the reviewer's *method*, not the knowledge line); the **why is one clause**
naming the failure. Keep it terse — the whole matching corpus is injected into a review,
so length is context cost. Provenance tags: `(starter)` baseline · `(PR #N, @author)`
mined from a maintainer comment · `(learned #N)` folded back from a corrected review
(no date — git history has it).

## How the reviewer consumes it (important properties)
- Files are **read fresh each review** → content edits (learn/seed/manual) are **LIVE on
  the next review with NO `gc reload`**. Reload is only for prompt/command/env changes.
- The reviewer loads `general.md` + the `<domain>.md` files the PR's changed paths match
  in `_manifest.md`. Bounded context: one flywheel per domain.
- Knowledge dir is injected to the reviewer agent as `$GC_PR_KNOWLEDGE` via the rig
  `[[rigs.patches]]` env. When running tools from a human shell, export it or pass
  `--knowledge-dir`. (Don't rely on `{{.ConfigDir}}` — it renders empty in prompts.)

## Write access — the human gate (non-negotiable)
The live `<domain>.md`/`general.md` files are **human-write-only**. Autonomous agents
(reviewer, lead, any dispatched worker) must NOT edit them or run `learn --invariant`
against the live corpus — a review step must never mutate the knowledge it was graded
against. To propose an invariant, an agent appends one `- ` bullet to
`_seed/<domain>.candidates.md` (the miner's staging file) and surfaces it in its output;
a human curates + accepts via `learn --from-candidates` (Workflow B). **Dispatch
briefs/prompts must route proposals to candidates, not a live `learn` append.**
Enforcement is convention today (single-user container); the backstop is `git diff`
review before harvest/push — which is what caught the premature INV-PARSE-001. Hard
enforcement (read-only corpus mount, separate agent user) lands with the deployment
migration.

## Is a candidate signal or noise? (the curation bar)
An invariant only earns its place if it **changes the review**. Truth is table stakes.
Ask, in order:
1. **Counterfactual:** would a strong model already do the right thing without this line?
   If yes → noise. Signal is non-obvious; **negative/counterintuitive rules ("you'll
   naturally do X, but X is wrong here because Y") beat affirmative best-practice.**
2. **Grounded:** names a real, current symbol/file/flag in this tree (re-check source —
   a stale mechanism is worse than a vague one).
3. **Checkable:** a read-only reviewer can confirm/refute it from the diff and cite
   `file:line` (not "please add an eval" boilerplate).
4. **Attributable:** has provenance; over time, earns/loses its place by whether its
   citations get confirmed (the future feedback loop).

**Asymmetric reject bar:** a MINED candidate has a real maintainer PR behind it — reject
it only for PR-specific nits, pure process/doc rules, generic style, or render minutiae.
Prune a `(starter)` (no evidence behind it) more freely.

## Workflow A — fold back ONE lesson (after a human corrects a verdict)
```
gc pr-review-pack learn --area <domain> \
  --invariant "<one-line rule — why: ...>" \
  --from-pr <N> --author @handle
```
Appends to `<domain>.md` under "## Learned / seeded invariants" with a fresh ID, stamped
`(learned #N by @handle)`. (No `<domain>.md`? create it — see "New domain".)

## Workflow B — seed from history (mine → distill → curate → accept)
1. **Mine** maintainer comments (CODEOWNERS-filtered, ~1 API call/PR):
   `//tools/vllm/mine-review-comments.sh` → `_seed/candidates-raw.jsonl`.
2. **Distill** per `//tools/vllm/distill-prompt.md` → `_seed/<domain>.candidates.md`
   (one `- ` bullet per candidate, provenance preserved).
3. **Curate** — edit `_seed/<domain>.candidates.md` against the bar above:
   - keep → leave the `- ` bullet (tighten wording freely; strip any nit tangled in it);
   - reject → delete the line, or demote to a `#` comment with a reason (kept for audit,
     skipped by `learn`).
4. **Accept** (run **once per file** — `learn` is NOT idempotent):
   ```
   KDIR=/pvc/workspace/tools/vllm/review-knowledge
   for area in tool_parsers reasoning openai_frontend; do
     bash /pvc/workspace/pr-review-pack/commands/learn/run.sh \
       --from-candidates "$KDIR/_seed/$area.candidates.md" --knowledge-dir "$KDIR"
   done
   ```
   (or `gc pr-review-pack learn --from-candidates <file>` once the pack command is reloaded.)
5. **Verify:** each `<domain>.md` gained the expected count under "Learned / seeded":
   `awk '/## Learned/{p=1}p' <domain>.md | grep -c '^- \[INV-'`
6. **Neutralize + commit:** so a future accidental re-run is a no-op, comment out the
   accepted bullets and stamp the file (learn skips `#` lines). One-liner per file:
   `sed -i -E 's/^- /# [accepted] /' _seed/<area>.candidates.md` then prepend a
   `# STATUS: ACCEPTED <date> -> <area>.md as INV-...NNN` line. Commit the `<domain>.md`
   files + neutralized candidates together.

## `learn` mechanics & gotchas (from `pr-review-pack/commands/learn/run.sh`)
- Appends **every** `- `/`* ` bullet in the file; skips `#` and blank lines.
- Strips any leading `[INV-...]` on a bullet, then assigns a fresh **auto-incremented**
  `[INV-<PFX>-NNN]` = (max NNN currently in `<domain>.md`) + 1. `<PFX>` comes from the
  file's `<!-- id-prefix: X -->` header (else derived from the area name).
- Preserves the bullet's own provenance verbatim.
- **NOT idempotent** — re-running re-appends everything. Accept once, then neutralize.
- Needs `$GC_PR_KNOWLEDGE` or `--knowledge-dir`. LLM-free, deterministic.

## ID discipline (non-negotiable — the feedback loop depends on it)
IDs are **stable, permanent citation handles**. Never renumber or reuse an ID. When you
retire an invariant, replace it with a tombstone comment (e.g.
`<!-- [INV-GEN-005] retired <date>: <reason> -->`) rather than deleting the line and
letting a later add reuse the number. The reviewer cites IDs in `evidence`; churn breaks
attribution.

## Add a NEW domain
1. Add a row to `_manifest.md`: `| <domain>.md | when a changed path contains `/<dir>/` | notes |`.
2. Create `<domain>.md` with a `<!-- id-prefix: XXX -->` header + a "## Invariants" and
   "## Learned / seeded invariants" section.
3. Keep the miner's path patterns (`//tools/vllm/mine-review-comments.sh`) in sync with
   the new manifest row.

## Pointers
- Miner: `//tools/vllm/mine-review-comments.sh` · Distill: `//tools/vllm/distill-prompt.md`
- Appender: `//pr-review-pack/commands/learn/run.sh`
- Rubric & feedback-loop design notes: project memory `pr-review-invariant-signal-vs-noise`
