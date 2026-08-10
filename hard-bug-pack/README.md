# hard-bug-pack

Two independent LLM worker lanes each diagnose a hard bug, then act as each
other's **second opinion** ("consider or refute — *not* a mandate") until they
converge — first on **root cause**, then on the **fix plan** — under a coordinator
that makes the subjective "close enough?" call, relays opinions, caps the rounds,
and escalates to a human when convergence stalls. The stronger lane then
implements + tests, and the other **cross-reviews** the diff *and its verification
evidence*.

It automates a flow you would otherwise run by hand across two terminal tabs.

## How it's built (the one idea that matters)

`gc sling` is fire-and-forget and the formula engine is a compile-time DAG with
only single-step check/retry loops. So the work is split at the natural seam:

- **Within one round → a formula DAG.** `formulas/hard-bug-round.toml` fans out
  two worker lanes and gates a `reconcile` step on **both** (`needs =
  ["lane-a","lane-b"]`), each step routed to its own agent via `gc.run_target`.
  The *controller* drives this — no polling, no races. Same shape as core's
  `mol-review-quorum`.
- **Across rounds and phases → the coordinator agent.** The subjective,
  cross-round, cross-phase loop-back can't live in a static DAG, so it lives in
  `agents/hb-coordinator/prompt.template.md`: after reconciling round N the
  coordinator decides aligned-or-not, then advances the phase, launches round N+1
  (re-slinging the round formula with each lane's prior bead relayed as the
  other's second opinion), or escalates. This is gascity's "keep judgment out of
  Go — judgment lives in the prompt."

Every round is its own durable molecule; the coordinator re-derives phase/round
from the arc bead's persisted `hard-bug-state.v1` on each wake, so the protocol
**resumes** if a session dies.

## The phases

```
diagnose(root_cause) → converge-root-cause → converge-fix
                     → implement → cross-review → done | escalated
```

## Contents (directory convention)

| Path | What |
|---|---|
| `agents/hb-worker-a/` | lane A: diagnose / reconsider / implement / cross-review; own worktree (model from city.toml `option_defaults`) |
| `agents/hb-worker-b/` | lane B; shares worker-a's prompt; model from city.toml `option_defaults`; **one-line swap to codex** |
| `agents/hb-coordinator/` | protocol driver: reconcile, judge convergence, relay, cap, escalate |
| `formulas/hard-bug-round.toml` | one round: two lanes + coordinator reconcile |
| `formulas/hard-bug-finalize.toml` | implement → cross-review → finalize |
| `assets/scripts/emit-json.sh` | atomic finish: MERGE-write `gc.output_json` + close (+ opt notify) |
| `//tools/shared/worktree-setup.sh` | pre_start (shared spine, city-root copy via `{{.CityRoot}}`): one detached worktree per slot |
| `commands/start/` | `gc hard-bug-pack start <arc-bead>` — resolve rig + sling a run (no target-typing) |
| `commands/status/` | `gc hard-bug-pack status <arc-bead>` — LLM-free state render |

## Output contracts (`gc.output_json_schema` per step)

- `hard-bug-diagnosis.v1` — each lane: `root_cause{statement,mechanism,confidence}`,
  `proposed_fix{...}`, `considered_second_opinion{peer_bead,stance,why}`, `evidence[]`.
- `hard-bug-reconcile.v1` — coordinator: `aligned`, `divergences[]`, `stronger_lane`,
  `stuck`, `next_action`, `relay_to_a`, `relay_to_b`.
- `hard-bug-implement.v1` — implementer: `branch`, `pushed`, `head_sha`, `tests[]`, ...
- `hard-bug-crossreview.v1` — reviewer lane: `verdict`, `concurs_with_fix`,
  `concurs_with_evidence`, `findings[]`, `evidence_assessment`.
- `hard-bug-state.v1` — arc bead (coordinator-owned, MERGE-updated): `phase`,
  `rounds{root_cause,fix}`, `max_rounds`, `chosen_implementer`, `status`, `convoy_id`.

## Scope: a generic capability, activated per rig

The pack is project-agnostic. Its agents are `scope = "rig"`, so they exist only in
the rigs whose `includes` list the pack — the same model as `pr-review-pack`. There
is **no auto-detection** of which rig a bug belongs to: the rig is chosen at launch
(by the `start` wrapper's `--rig` / bead-prefix, or by the rig-qualified targets you
sling). Attach it to each rig you want it in:

```toml
# city.toml — e.g. alongside pr-review-pack on the vllm rig
[[rigs]]
name = "vllm"
includes = ["pr-review-pack", "hard-bug-pack"]
```
```bash
gc reload
gc doctor                 # validates the pre_start script path resolves
gc agent list             # expect <rig>/hb-worker-a, <rig>/hb-worker-b, <rig>/hb-coordinator
gc formula list           # expect hard-bug-round, hard-bug-finalize
```

## Run it (staged)

Create an **arc/tracking bead** in the target rig. Simplest: just link the upstream
issue — the lanes have read-only `gh` and fetch it themselves (no body/heredoc needed):

```bash
gc --rig vllm bd create -t bug -p 1 \
  --external-ref "https://github.com/vllm-project/vllm/issues/<N>" \
  --title "hard bug: <short title>"        # -> vllm-XXX
```
Add detail if you like with a one-line `-d "..."`, a `--body-file <file>`, or a heredoc
into `--body-file -`. The lanes read the description AND fetch any linked issue/PR — and
are told to reach their own conclusion, not just defer to a proposed fix.

**Stage 1 — single-shot fan-out + reconcile (no loop).** The `start` wrapper
resolves the rig from the bead prefix (or `--rig`) and fills in the targets; without
`--loop` it runs report-only (the coordinator stops after one reconcile + mail):

```bash
gc hard-bug-pack start vllm-XXX               # rig inferred from "vllm-"; add --rig NAME to override
gc hard-bug-pack start vllm-XXX --dry-run     # preview the exact gc sling it will run
```
Success: `gc graph <root> --tree` shows `lane-a` + `lane-b` closed and `reconcile`
fired *only after both*; each lane bead carries a real `hard-bug-diagnosis.v1`;
`reconcile` carries a coherent `hard-bug-reconcile.v1`; each lane ran in its own
worktree; you got a summary mail. `gc hard-bug-pack status vllm-XXX` renders it.

Under the hood, `start` is just this (drop the wrapper if you want full control):

```bash
gc sling vllm/hb-coordinator hard-bug-round --formula \
  --var bug_bead=vllm-XXX --var phase=root_cause --var round=1 \
  --var max_rounds=3 --var enable_loop=false \
  --var lane_a_target=vllm/hb-worker-a \
  --var lane_b_target=vllm/hb-worker-b \
  --var coordinator_target=vllm/hb-coordinator --json
  # Each lane's model comes from its city.toml option_defaults (see "Choosing the
  # worker model" below); add --var lane_a_model=<m> only to pin a model this run.
```

**Stage 2 — bounded convergence loop.** Add `--loop` (`enable_loop=true`); the
coordinator then drives all subsequent rounds/phases itself (relaying second
opinions, advancing root_cause → fix), capping at `--max-rounds`, escalating via
`hold=mayor` + a mail to the human (`$GC_HARDBUG_NOTIFY_TO`, default `human`) when stuck.

**Stage 3 — implement + cross-review.** Once the fix converges the coordinator
slings `hard-bug-finalize` with the stronger lane as implementer and the other as
cross-reviewer; concur → arc `status=done`; reject → re-enter fix or escalate.

## Choosing the worker model

Each lane's model comes from the agent's `city.toml` `option_defaults` — the formula
no longer pins it. Set it wherever you set other agent config:

- **Cross-vendor (different providers).** Set the model at the provider level. This
  is validated at config load, so a typo fails `gc reload`:
  ```toml
  [providers.claude]
  option_defaults = { model = "opus" }     # lane A (claude)
  ```
- **Same provider, different model per worker.** Use a rig patch on the worker.
  Valid claude values: `opus | sonnet | haiku | fable-5 | opus-4-7 | sonnet-5 |
  sonnet-4-6`. Note: rig-patch `option_defaults` are **not** validated at
  `gc reload` — a typo here is caught at *launch* (logged; the worker falls back to
  its default), not at reload.
  ```toml
  [[rigs.patches]]
  agent = "hb-worker-b"
  option_defaults = { model = "sonnet" }
  ```

To pin a model for a single run instead, pass `--lane-a-model` / `--lane-b-model` to
`start` (or `--var lane_a_model=…` on a raw sling).

## Add a real second vendor later (truly one line)

Lane B is provider-agnostic, and the formula no longer pins its model — so a second
vendor is just a rig patch (add a `[providers.codex]` block + creds first). Nothing
in the formulas or prompts changes:

```toml
# city.toml
[[rigs.patches]]
agent = "hb-worker-b"
provider = "codex"
option_defaults = { model = "gpt-5-codex" }
```
