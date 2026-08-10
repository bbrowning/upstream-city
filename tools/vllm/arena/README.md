# model-arena — judged model-vs-model comparisons

A durable, queryable log of every time a coordinator/judge preferred one model's
(or config's) output over another's, so we can tune workflows over time — drop a
reviewer that always loses, find the effort level with the best tokens-per-win,
or A/B a persona blind.

**Principle: log decisions, derive ratings.** Each row in `decisions.jsonl` is one
*judged comparison* (an event). Win-rates, Elo / Bradley-Terry, and cost curves are
*queries* over this log — never stored as running state. Comparisons are **paired**
(all participants saw the same task), the ideal input for pairwise rating methods.

Storage is JSONL now, a Dolt table later. `decisions.jsonl` **is the system of
record and should be committed** — it holds transcript-derived token counts, and
the transcripts they came from are ephemeral/gitignored, so it isn't reliably
re-derivable once they're purged.

## Sources currently captured

| source | blind? | tokens? | what it compares |
|---|---|---|---|
| `bug-lane-reconcile` | no (coordinator, opus-family, sees lane labels) | yes | production: opus vs sonnet diagnosis lanes |
| `eval-review` | **yes** | no | offline persona/config bake-off (same model, current-pack vs lean-persona) |
| `eval-diagnosis` | **yes** | no | offline N-way, cross-model×treatment diagnosis |

The blind eval rows are the **calibration anchor** for the non-blind production
rows. Don't naively pool them — slice by `blind` and `source`.

## Files

- `decisions.jsonl` — one arena decision per line (`schema: arena-decision.v0.2`).
- `arena_common.py` — shared load/merge/write (idempotent, cost-preserving) +
  `scan_transcript_usage()` (the session/window token join, deduped by message.id).
- `backfill_bug_lane.py` — projects `hard-bug-reconcile.v1` beads + per-worker
  transcript tokens. `project()` is the going-forward entry point; re-run anytime.
- `eval_to_arena.py` — projects `tools/vllm/eval/run-*/` (review + diagnosis).
- `arena_refresh.py` — **the single idempotent capture entry point**: runs every
  projector under a lock, logs to `refresh.log`. Driven by the `arena-capture` gascity
  order (below); also runnable manually / `--loop`. Add new N≥2 sources to `PROJECTORS`.
- `test_arena.py` — hermetic tests for the token math (dedup, session-vs-window).

Every projector merges into the same log by `decision_id`, preserves foreign rows
and prior token counts, and rewrites — so running any of them is always safe.

## Run

```
python3 tools/vllm/arena/arena_refresh.py       # capture ALL sources (idempotent)
python3 tools/vllm/arena/backfill_bug_lane.py   # just the bug lane
python3 tools/vllm/arena/eval_to_arena.py       # just eval review + diagnosis
python3 tools/vllm/arena/test_arena.py          # token-math regression tests
```

## Auto-capture (going-forward) — no manual backfilling

New N≥2 decisions land in the log automatically via **one path**: a gascity order runs
`arena_refresh.py` on a cooldown. Everything funnels through that one idempotent script,
so token counts are captured well within Claude Code's transcript retention
(`cleanupPeriodDays`, ~30d).

- **The mechanism: a gascity order** — `dev-pack/orders/arena-capture.toml` →
  `arena-capture.sh` → `arena_refresh.py`. The controller (the one always-on process
  here) runs it via `exec` on a `cooldown` (no LLM/agent/wisp) — the durable cousin of
  cron; it survives restarts. Same pattern as `jsonl-export`. It's a pack file, so
  `gc reload` activates it (`gc order list` to confirm). A prompter variant is
  `trigger="event"` / `on="bead.closed"` (guarded to reconcile beads, like
  `cascade-nudge-on-blocker-close`); cooldown is used since retention dwarfs any interval.
- **Manual / fallback:** `python3 arena_refresh.py` (or `--loop 6h`).

(An earlier Claude Code Stop hook was removed in favor of this single order path.)

## Token sourcing is HARNESS-SPECIFIC (future-enhancement seam)

Token counts and *how we find them* are specific to the runtime that executed the
model. Each participant records `harness` (the runtime) and `cost_source` (the
method / why-absent):

- **gascity agents** run as full Claude Code sessions, each with its own worktree
  transcript under `~/.claude/projects/-pvc-workspace--gc-worktrees-vllm-<agent>/`.
  The transcript **filename is the Claude Code session UUID**, and each record carries
  `sessionId`, `effort`, and `model`. Tokens are **deduped by `message.id`** (usage
  lines are logged 2–4× per message — don't sum raw lines). There are two join tiers
  (`cost.join` records which was used):
  - **`session` (stable, preferred)** — when the lane bead carries a `gc.cc_session_id`,
    read exactly that session's file. Window-independent, immune to sibling sessions
    accumulating in a reused worktree. → `cost_source:
    "claude-code/worktree-transcript#session"`.
  - **`window` (fallback)** — no stamp: scan all sessions in the worktree, keep records
    within the bead's `[created_at, closed_at]`. Fragile — a loose window (missing
    `closed_at` → +3h) or session reuse can bleed a sibling run's tokens.
    → `cost_source: "claude-code/worktree-transcript#window"`.
  The worker self-stamps `gc.cc_session_id` at emit time (`emit-json.sh`, from
  `$CLAUDE_CODE_SESSION_ID` — pack-only, no gascity change; needs `gc reload`). Rows
  captured before that reload are `#window`; the code uses `#session` for every run
  emitted after it. `effort_resolved` (ground truth) is read from the transcript.
- **eval arms** are Agent-tool subagents, NOT gascity sessions. Their internal
  turns/usage are **not persisted** anywhere — only the parent keeps the spawn
  prompt and the final `tool_result` (no usage). → tokens null,
  `cost_source: "claude-code/agent-tool-subagent(usage-not-persisted)"`.
- **Other harnesses (codex, opencode, …)** will store usage differently and need
  their own extraction adapter + `harness`/`cost_source` values. **Not built yet —
  future enhancement.** `harness` is the field to branch on when adding one.

Dollars are intentionally not computed anywhere — apply a rate table downstream.

## Record shape (v0.2)

```
schema, decision_id, source, source_refs[], root_bead, subject_ref, subject_model,
lane, phase, round, at, pack_commit, blind, mode ("pairwise"|"nway")
judge{kind, agent, provider, model, effort}, criterion, aligned, tie
participants[]: slot, treatment, provider, model_intent, model_resolved,
  model_canonical, effort, effort_source, effort_resolved, effort_resolved_source,
  cc_session_id, harness, window, cost{tokens{input,output,cache_creation,cache_read,
  total}, messages, join, sessions[]}, cost_source, scores, verdict, rank
outcome{winner_slot, winner_model_canonical, ranking[]}
reason_tags[], rationale, divergences[], next_action, failure_class, failure_reason, notes
```

- `model_intent` = what was asked for (bead `opt_model`; often empty/invalid).
  `model_resolved` = what actually ran (stamp or transcript; **ground truth**). Prefer resolved.
- `effort` = INTENT (pack config: city.toml/agent.toml, accurate when projected promptly;
  `effort_source` says where). `effort_resolved` = GROUND TRUTH (bead stamp when present,
  else the transcript's per-message `effort`); `effort_resolved_source` records which.
- `cc_session_id` = the Claude Code session the tokens came from (the stamp, or — in the
  window path — the sole session found). `cost.join` = `session` | `window` (see Token sourcing).
- `pack_commit` = git HEAD at the decision's **first** capture (~run-time when projected
  promptly); pinned across re-projections so idempotent re-runs don't churn the log.
- `reason_tags` is an empty going-forward field (controlled vocab for *why* a side lost).

## Example queries

```
# production win-rate by model (non-blind judge)
jq -r 'select(.source=="bug-lane-reconcile").outcome.winner_model_canonical' decisions.jsonl | sort | uniq -c

# blind persona bake-off: which treatment wins?
jq -r 'select(.source=="eval-review" and .outcome.winner_slot!=null)
       | (.participants[] | select(.slot==(.. ) )) ' decisions.jsonl   # see eval_to_arena summary

# bang-for-buck: output tokens per model, production only
jq -r 'select(.source=="bug-lane-reconcile").participants[] | "\(.model_canonical)\t\(.cost.tokens.output)"' decisions.jsonl

# only real disagreements (drop aligned/agreement rows)
jq -c 'select(.aligned==false)' decisions.jsonl
```

## Caveats

- **Non-blind vs blind.** bug-lane coordinator is opus-family and sees lane labels;
  eval judge is blind. Treat eval as the anchor; down-weight production picks.
- **Agreement ≠ preference.** Most bug-lane rows are `aligned=true` — the lanes
  agreed and the coordinator still named a `stronger_lane`. Weak signal; filter on `aligned`.
- **Small, non-independent N.** ~8 production decisions over repeated subjects; 8+1
  eval. Report CIs; don't over-interpret.
- **Token attribution.** Rows with `cost.join == "window"` are approximate (per-agent ×
  timestamp window; assumes the worktree wasn't serving two sessions in that window).
  `cost.join == "session"` is exact (read from the stamped session file). All existing
  rows are `#window` until gascity stamps `gc.cc_session_id` (see Going-forward gaps).
- **Diagnosis winner/rank is derived** from a verdict ordinal (strong-catch > catch
  > partial > miss); raw grades are in `participant.scores`.
- **Review arms are the same model** (opus) — that axis is persona/config, not model.

## Going-forward gaps

- **Stable session-id token join — code DONE, needs `gc reload` to take effect.** The
  highest-value robustness fix: makes the token join stable instead of a timestamp-window
  guess. It's **pack-only, no gascity change** — the worker already knows its own Claude
  Code session (`$CLAUDE_CODE_SESSION_ID`, which equals the transcript filename), so
  `emit-json.sh` self-stamps `gc.cc_session_id` onto the lane bead when it closes the step.
  `scan_transcript_usage()` prefers that key (reads exactly that session file) and falls
  back to the window; `backfill_bug_lane.py` also reads optional `gc.effort` /
  `gc.model_resolved` stamps, though both are already recovered from the transcript. Rows
  emitted before the reload stay `#window`; everything after is `#session`.
- **Live emission (a nicety, not needed).** The `arena-capture` cooldown order already
  captures within retention; a `trigger="event"`/`on="bead.closed"` order (guarded to
  reconcile beads) would make it prompt. Review/feature lanes don't compare yet (review
  quorum is dev-pack Phase 3); when they do, add their projector to
  `arena_refresh.PROJECTORS` (their `emit-*.sh` gets the same one-line self-stamp).
- **Other-harness token adapters** — codex/opencode usage extraction (see Token sourcing).
- **eval cost** — genuinely unrecoverable for existing runs (subagent usage not persisted).
