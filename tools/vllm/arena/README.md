# model-arena — judged model-vs-model comparisons

A durable, queryable log of every time a coordinator/judge preferred one model's
output over another's, so we can tune workflows over time (drop a reviewer that
always loses; find the effort level with the best tokens-per-win).

**Design principle: log decisions, derive ratings.** Each row in
`decisions.jsonl` is one *judged comparison* (an event). Win-rates, Elo /
Bradley-Terry, and cost curves are all *queries* over this log — never stored as
running state. Comparisons here are **paired** (both models saw the same task),
which is the ideal input for pairwise rating methods.

Storage is JSONL now, a Dolt table later. `decisions.jsonl` is the system of
record and **should be committed** — it captures transcript-derived token counts,
and the transcripts it reads are ephemeral/gitignored, so the backfill is not
reliably re-runnable once they're purged.

## Files

- `decisions.jsonl` — one arena decision per line (`schema: arena-decision.v0.1`).
- `backfill_bug_lane.py` — projects existing `hard-bug-reconcile.v1` beads (Dolt
  `vllm` DB) into `decisions.jsonl`, joining per-participant token counts from the
  per-worker Claude Code transcripts. Idempotent: rewrites the file each run.

## Run

```
python3 tools/vllm/arena/backfill_bug_lane.py          # exports beads, writes decisions.jsonl
python3 tools/vllm/arena/backfill_bug_lane.py --export beads.jsonl   # use a pre-exported dump
```

## Record shape (v0.1)

```
decision_id, source, source_beads[], root_bead, subject_ref, lane, phase, round, at
blind (bool), judge{agent,provider,model,effort}, criterion, aligned, tie
participants[]: slot, provider, model_intent, model_resolved, model_canonical, effort,
                window{start,end}, cost{tokens{input,output,cache_creation,cache_read,total}, messages, model_resolved}
outcome{winner_slot, winner_model_canonical}
reason_tags[], rationale, divergences[], next_action, failure_class, failure_reason
```

- `model_intent` = the bead's `opt_model` (what was *asked for*; can be empty or an
  invalid id). `model_resolved` = the model that actually ran, from the transcript
  (**ground truth**). Prefer `model_resolved` for analysis.
- **Tokens only, no dollars.** `.gc/usage.jsonl` is empty (metering off + Vertex),
  so cost lives in the Claude Code transcripts as token counts; Vertex $ isn't in
  them. Apply a rate table downstream when you want dollars.
- `reason_tags` / `effort` are empty for backfilled rows — they were never recorded
  historically. They're the going-forward fields (see below).

## Example queries

```
# win-rate by canonical model (winner side)
jq -r '.outcome.winner_model_canonical' decisions.jsonl | sort | uniq -c

# output tokens per participant, per model — the bang-for-buck view
jq -r '.participants[] | "\(.model_canonical)\t\(.cost.tokens.output)"' decisions.jsonl

# only decisions where the lanes actually disagreed (real preference signal)
jq -c 'select(.aligned==false)' decisions.jsonl
```

## Caveats (read before acting on the numbers)

- **Non-blind judge.** The bug coordinator is opus-family and sees lane labels, so
  its picks favor its own family and aren't blind. Treat the offline eval judge
  (`../eval/`) as the calibration anchor; down-weight these.
- **Agreement ≠ preference.** Most backfilled rows are `aligned=true` — the lanes
  agreed and the coordinator still named a `stronger_lane` on rigor/coverage. Weak
  signal; keep the `aligned` flag and filter on it.
- **Small, non-independent N.** ~8 decisions over several repeated subjects
  (`vllm-x1y` recurs) — report confidence intervals; don't over-interpret.
- **Token attribution is approximate.** A per-agent × timestamp-window join over
  transcript messages (deduped by `message.id`); assumes a worker wasn't running
  two decisions' lanes concurrently. No `session_id` on the bead to join on.

## Going-forward gaps

- **Effort** is recorded nowhere — must be stamped at emission to accumulate.
- **Live emission** — the bug coordinator could emit an arena row directly; other
  lanes (review/feature) don't compare yet (review quorum is dev-pack Phase 3).
- **Eval projector** — `../eval/run-*/` has a *blind* judge with richer rationale;
  a second projector into this same schema would add the calibration anchor.
