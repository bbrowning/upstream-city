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
- `arena_common.py` — shared load/merge/write (idempotent, cost-preserving).
- `backfill_bug_lane.py` — projects `hard-bug-reconcile.v1` beads + per-worker
  transcript tokens. Backfill AND going-forward: re-run after each hard-bug run.
- `eval_to_arena.py` — projects `tools/vllm/eval/run-*/` (review + diagnosis).

Every projector merges into the same log by `decision_id`, preserves foreign rows
and prior token counts, and rewrites — so running any of them is always safe.

## Run

```
python3 tools/vllm/arena/backfill_bug_lane.py   # bug lane (exports beads, joins tokens)
python3 tools/vllm/arena/eval_to_arena.py       # eval review + diagnosis
```

## Token sourcing is HARNESS-SPECIFIC (future-enhancement seam)

Token counts and *how we find them* are specific to the runtime that executed the
model. Each participant records `harness` (the runtime) and `cost_source` (the
method / why-absent):

- **gascity agents** run as full Claude Code sessions, each with its own worktree
  transcript under `~/.claude/projects/-pvc-workspace--gc-worktrees-vllm-<agent>/`.
  Tokens are recovered by an agent × timestamp-window scan, **deduped by
  `message.id`** (usage lines are logged 2–4× per message — don't sum raw lines).
  → `cost_source: "claude-code/worktree-transcript"`.
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
  model_canonical, effort, effort_source, harness, window, cost{tokens{input,
  output,cache_creation,cache_read,total}, messages}, cost_source, scores, verdict, rank
outcome{winner_slot, winner_model_canonical, ranking[]}
reason_tags[], rationale, divergences[], next_action, failure_class, failure_reason, notes
```

- `model_intent` = what was asked for (bead `opt_model`; often empty/invalid).
  `model_resolved` = what actually ran (transcript; **ground truth**). Prefer resolved.
- `effort` on bug-lane rows is resolved from pack config (city.toml/agent.toml) — an
  *intent* proxy, accurate when projected promptly. `effort_source` says where it came from.
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
- **Token attribution is approximate** (per-agent × timestamp window; assumes a
  worker wasn't running two decisions concurrently; no `session_id` on the bead).
- **Diagnosis winner/rank is derived** from a verdict ordinal (strong-catch > catch
  > partial > miss); raw grades are in `participant.scores`.
- **Review arms are the same model** (opus) — that axis is persona/config, not model.

## Going-forward gaps

- **Effort at source** — stamp effort into the bead at dispatch (gascity follow-up)
  so it's captured exactly, not re-derived from config.
- **Live emission** — the coordinator could emit an arena row directly; review/feature
  lanes don't compare yet (review quorum is dev-pack Phase 3).
- **Other-harness token adapters** — codex/opencode usage extraction (see Token sourcing).
- **eval cost** — genuinely unrecoverable for existing runs (subagent usage not persisted).
