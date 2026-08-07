# pr-review-pack — parallel PR review + one feature-dev lane, worktree-isolated

Run **N read-only PR reviewers in parallel with 1 feature-dev writer** on a
single rig, with the same "zero chance of stomping on each other" guarantee you
get from running N separate containers by hand — but from **native gascity
mechanics alone** (no phantom `isolation="worktree"` primitive; that does not
exist in v1.4.0).

Each agent slot runs inside its **own git worktree**, so parallel reviewers can
each sit on a different PR (or the same one) and the writer can hold a dirty
branch, all without touching the shared rig checkout or each other.

> Grounded against **gascity v1.4.0** (installed binary + source at HEAD
> `a7297c5`), verified claim-by-claim in
> `../VERIFICATION-vs-live-v1.4.0.md`. The original design doc was written
> without the live city and several of its claims did not hold up; this pack is
> the corrected artifact.

## The flow at a glance (the "aha")

The whole loop, human's-eye view — a review is a **push**, and you never go
hunting for its result:

```
   you ──"review PR 51296"──▶  vllm/lead ──dispatch──▶ reviewer slot (own worktree)
                                                              │
        emits pr-review.v1 verdict on its step bead ◀─────────┘
                                                              │
   inbox ◀── one-line verdict mail (gc mail check) ───────────┘   ← comes to YOU
     │
     ├─ enough?  you make the merge call. Done.
     │
     └─ want to see/run it yourself?
            gc pr-review-pack materialize 51296     ← durable checkout on disk
            cd <city>/pr-worktrees/vllm/pr-51296
            git diff origin/main...HEAD             ← read it
            # run the reviewer's suggested dynamic_request.command right here
```

Two things make this ergonomic instead of a scavenger hunt:

1. **The verdict comes to you.** On finish, the reviewer drops a one-line summary
   in your mail (`gc mail check`) with the dashboard link — five parallel reviews
   become five lines in a queue, not five metadata digs. See
   [Read the verdict](#read-the-verdict-this-is-the-gate).
2. **You can always get the code back.** The reviewer's own worktree is transient
   per-slot scratch (reused across PRs), so after a review closes there is no tree
   on disk with that PR's bits. `gc pr-review-pack materialize <PR>` re-checks it
   out into a **durable, human-owned** worktree that agent slot-reuse and
   `gc stop --clean` never touch. See
   [Materialize a PR for human review](#materialize-a-pr-for-human-review).

Everything below is the detail behind those arrows.

## How you drive it (through the rig `lead`)

This city gives each rig a **`lead`** — a rig-scoped singleton planner/dispatcher
that is your entrypoint for that rig (the `mayor` is reserved for cross-rig /
citywide work). Since almost all work here is single-rig, the normal flow is:

- **You talk to `vllm/lead`** ("review PR 12345", "implement X"). The lead plans,
  files/《claims》 the bead, and **dispatches** to the right lane — a `reviewer`
  slot for a review, `feature-dev` for a change — then surfaces the result back to
  you. (It files/claims a bead for the work first.) It discovers those lanes and
  formulas dynamically (`gc agent list` /
  `gc formula list`) once this pack is attached to the rig, so the shared lead
  prompt needs no pack-specific edits.
- **Direct sling is the manual / power-user path** (`gc sling vllm/reviewer …`,
  shown below). Use it to kick something off yourself, or for scripting; it's the
  exact mechanism the lead uses under the hood.

Either way **you make the merge call** — the lead can gather verdicts, but there
is no automated merge gate.

### The `lead` and the "nobody works in the rig root" rule

The lead's working dir **is** the rig root (by design — it plans with the code
warm in front of it, and may do low-volume work directly there). That is a
*sanctioned* exception, and it does not weaken this pack's guarantee, because:

- The isolation guarantee is about the **parallel / pool agents** (the reviewers
  and feature-dev) — the ones that could actually collide. Those never touch the
  rig root; each is in its own worktree.
- The lead is a **singleton** (one per rig), so it cannot race itself, and it
  sits in a *different* working dir than the worktree agents — no file collision
  between the lead and a reviewer/feature-dev running at the same time.
- **Guidance:** for anything that wants isolation or parallelism (concurrent
  reviews, a change you'll iterate on a branch), have the lead **dispatch to the
  lanes** rather than editing in the rig root itself. The read-only `fetch-origin`
  order only updates refs, so it's safe alongside the lead working in the root.

## How the isolation actually works (the one idea to understand)

A **rig-scoped** session with an empty `work_dir` resolves straight to the rig
root (verified: `internal/workdir/workdir.go:241-256`). So if you just bumped
`max_active_sessions` to 2, both reviewers would open in the *same* checkout at
the *same* HEAD — exactly the stomping you're trying to avoid.

The fix, in every agent's `agent.toml`:

```toml
work_dir  = ".gc/worktrees/{{.Rig}}/{{.AgentBase}}"
pre_start = ["{{.ConfigDir}}/assets/scripts/worktree-setup.sh {{.RigRoot}} {{.WorkDir}} {{.AgentBase}}"]
```

(`{{.ConfigDir}}` resolves to **this pack's dir** — where the script actually
lives once installed — not the city root; `{{.CityRoot}}` would `exit 127`.)

- A bounded pool (`max_active_sessions > 1`) statically expands to numbered
  slots `reviewer-1`, `reviewer-2` (`SupportsInstanceExpansion` +
  `poolInstanceName`). `{{.AgentBase}}` differs per slot, so each resolves to a
  **distinct** `work_dir` → a distinct worktree. That is the linchpin.
- `pre_start` runs **before** the session is created, so the agent opens up
  *inside* its worktree. `worktree-setup.sh` creates a **detached** worktree at
  the rig's current HEAD (detached so N slots never fight over a branch
  checkout), writes a `.beads/redirect` back to the shared ledger, and — as a
  safety net — **refuses to run if the target is the rig root itself** (loud
  fail instead of a silent stomp if `work_dir` is ever misconfigured).
- `pre_start` has **no per-bead context** (no bead-ID template var exists), so
  it only guarantees *isolation*. The job-specific checkout is the agent's own
  first step: the reviewer fetches the PR ref, feature-dev branches `paude/<bead>`.

Worktrees are cheap here: measured **~0.36s / ~111MB** per detached add on vLLM
(objects are shared with the rig root; only the working tree is written).

### Why this is safe with the reaper

gascity's worktree reaper (`reapClosedBeadWorktrees`) only removes a worktree
whose name parses as a **closed bead ID**. Agent-named worktrees (`reviewer-1`,
`feature-dev`) never parse as a bead ID, so they are **never** reaper-eligible.
On top of that the reaper has a git-safety gate (uncommitted/unpushed/stashed →
skip) and never deletes branches. **Naming constraint:** never name a slot
`<rig-prefix>-<something>` that could look like a configured bead ID.

## What's here

```
pack.toml                             # manifest (schema 2); no [[named_session]] — see note below
agents/reviewer/agent.toml            # read-only reviewer, pooled up to 2 slots
agents/reviewer/prompt.template.md    # reviewer METHOD: checklist + read-only discipline
agents/feature-dev/agent.toml         # single write lane (1 slot)
agents/feature-dev/prompt.template.md # feature-dev METHOD: branch/push, never self-close arc
formulas/pr-review.toml               # per-run review TASK + pr-review.v1 verdict contract
formulas/feature-dev.toml             # per-run implement TASK + feature-dev.v1 report contract
orders/fetch-origin.toml              # read-only `git fetch --prune` on a cooldown (warm refs)
commands/materialize/                 # `gc pr-review-pack materialize <PR>` — durable human checkout
assets/scripts/worktree-setup.sh      # pre_start: make each slot's detached worktree
assets/scripts/fetch-origin.sh        # the fetch order's exec body
```

Agents, formulas, and orders are all discovered by **directory convention**
(gascity's `conventionDiscoveryDirNames`), so the manifest carries **no
`[[named_session]]` blocks**. Both agents are *pool* agents (they set
`min/max_active_sessions`), and `gc lint` forbids a `named_session` that targets
a pool-controlled agent — pools are auto-discovered and expanded by the `scope`
in their own `agent.toml`, exactly like hyperscale's `worker` or swarm's
`coder`. `min_active_sessions = 0` makes them on-demand.

## Install

This is a normal pack. Copy it into the city and attach it to the `vllm` rig.

**Prerequisite:** the city and the `vllm` rig must be **running** first (`gc
status` to check; `gc start` / bring the rig up if not). With the rig stopped,
nothing below will spin up a session.

1. Copy the pack into the city (so `{{.ConfigDir}}` → `<city>/pr-review-pack`
   resolves for the `pre_start` script path):
   ```bash
   cp -rf pr-review-pack <city>/pr-review-pack
   ```
2. Attach it to the **`vllm` rig** in `city.toml` via that rig's `includes`
   list (the `Rig` struct has **no `pack` field** — rig-scoped attach is
   `includes` for a local folder / URL, or an `[rigs.imports]` table for named
   V2 bindings). Rig-scope attachment is what stamps `Dir=vllm` on the agents so
   `{{.Rig}}` resolves to `vllm` and their names become `vllm/reviewer` /
   `vllm/feature-dev` (verified: `pack.go:1544` stamps `Dir=rigName` when unset).
   A city-wide attach would leave `{{.Rig}}` empty and the `pre_start` guard
   would (safely) refuse to start. Merge into your existing rig entry — keep its
   current `prefix` / `default_branch`, don't overwrite them:
   ```toml
   [[rigs]]
   name = "vllm"
   prefix = "vllm"                 # keep whatever your live config already has
   default_branch = "main"
   includes = ["pr-review-pack"]   # bare name → <city>/pr-review-pack, read in place
   ```
   `includes` takes a path relative to the city root; a bare name resolves to
   `<city>/pr-review-pack` and is **read in place on every `gc reload`** — no
   import/cache step (that only applies to remote URL refs). Edit a file →
   `gc reload` → live.
3. Reload and verify:
   ```bash
   gc reload                     # or gc restart, per your setup
   gc doctor                     # THIS validates the pre_start script exists on
                                 # disk (the pre-start-scripts check) — not gc lint
   gc formula list               # expect: pr-review, feature-dev
   gc agent list                 # expect: vllm/reviewer, vllm/feature-dev
   gc pr-review-pack --help      # expect: the `materialize` command (discovered
                                 # per-invocation from commands/, no reload needed)
   ```
   (Confirm exact subcommands with `gc formula --help` / `gc agent --help`.)

> **`gc lint ./pr-review-pack` is clean** apart from two benign warnings:
> `gc.output_json is deprecated; use drain in v2 formulas`. This is intentional
> — `drain` is for collecting from *many* child beads (fan-out); a single step
> emitting one structured verdict/report uses `output_json`, which is exactly
> what **core's own `mol-review-quorum`** formula does for all its steps. We
> share the warning with core; the pattern is the established one for reviews.

> The exact `city.toml` wiring is the one step to confirm against your live
> config before installing — see the pre-install checklist in
> `../VERIFICATION-vs-live-v1.4.0.md`.

## Run a PR review

**Primary path — ask the lead.** Tell `vllm/lead` what you want reviewed ("review
PR 12345 against main"); it dispatches to a `reviewer` slot and brings the verdict
back. This is the normal flow and needs no command memorization on your part.

**Manual path — direct sling.** Kick it off yourself (this is what the lead does
under the hood). `head_ref` can be a branch, a sha, or a PR number `N` (the
reviewer will `git fetch origin pull/N/head` itself):

```bash
gc sling vllm/reviewer pr-review --formula \
  --var base_ref=origin/main \
  --var head_ref=<pr-branch-or-sha-or-N> \
  --title "review <pr>" --json          # --json prints the dispatch result, incl. the root bead id
```

Run it again for a second PR while the first is still going — the second reviewer
lands in `reviewer-2`'s own worktree. No coordination needed. (Two reviews the
lead dispatches concurrently isolate exactly the same way.)

### Read the verdict (this is the gate)

These formulas require `formula_compiler >= 2.0.0`, so they compile to a **v2
workflow** (a DAG), **not** a convoy. `gc convoy …` subcommands explicitly do
*not* operate on workflow roots (`gc convoy --help`), so read the verdict via the
workflow tree instead:

```bash
# 1. From the sling --json output above, take the root bead id.
# 2. Expand the workflow to find the review step bead:
gc graph <root-bead-id> --tree           # step beads + their status
# 3. Read the verdict off the review step bead:
gc bd show <review-step-bead-id> --json   # -> metadata["gc.output_json"]
```

Or just open `gc dashboard` — it renders the workflow tree and each bead's
`gc.output_json` without hunting for ids (the friendliest path for a newcomer).

`verdict` ∈ `approve` / `approve_with_nits` / `request_changes` / `blocked`,
with `merge_recommendation` and `findings`. You make the merge call — there is
no mid-workflow human gate.

> The exact JSON field the root id lands in, and the precise `gc graph` output,
> are pinned during the first live run (below) — this pack has not yet been slung,
> so treat the id-discovery commands as the shape, confirmed on first use.

## Materialize a PR for human review

The verdict tells you *whether* to merge. When you want to see or run the change
**yourself** — read the diff with your own eyes, run the reviewer's suggested
check, poke at a new test — you need the PR's code on disk. The reviewer's
worktree won't have it: those are **per-slot scratch** (`reviewer-1` is reused
across every PR it reviews), so once a review closes nothing on disk holds that
PR's bits. Re-materialize it:

```bash
gc pr-review-pack materialize 51296          # a PR number → fetches origin pull/51296/head
gc pr-review-pack materialize my-branch       # or any branch / tag / sha
gc pr-review-pack materialize 51296 --base v0.6.0   # diff against a different baseline
```

That fetches the ref and checks it out **detached** into a durable, human-owned
worktree at:

```
<city>/pr-worktrees/<rig>/pr-<N>       # e.g. pr-worktrees/vllm/pr-51296
```

Why a separate path (not the reviewer's worktree): it lives **outside `.gc/`**, so
`gc stop --clean` never reaps it; it's **PR-keyed**, so many PRs coexist; and it's
never an agent slot, so slot reuse can't stomp it. It shares the rig's git object
store, so the checkout is cheap (~seconds, ~100MB working tree). The command
prints the head sha, a `--stat` against the base, and the next steps:

```bash
cd <city>/pr-worktrees/vllm/pr-51296
git diff origin/main...HEAD                   # read the change
# then run the reviewer's suggested dynamic_request.command right here
```

It is **idempotent**: re-run to no-op if already current, or `--force` to move an
existing checkout to a newer head. Tear it down when finished:

```bash
gc pr-review-pack materialize 51296 --remove
```

> **Env caveat:** this materializes the **code** — enough to read, diff, and
> review by hand. Actually *running* vLLM's tests needs its build/venv, which this
> paude container does not carry; run those where vLLM builds. (This is the same
> gap the Phase-2 `dynamic_request` auto-run lane will need to close — see the
> reviewer method + the posture-design memory.)

## Run a feature

**Primary path — ask the lead.** Describe the change to `vllm/lead`; it scopes a
bead and dispatches it to the single `feature-dev` lane (or, for a quick
low-volume tweak, may just do it itself in the rig root — its prerogative as the
planner). For anything you want isolated on a branch, the lead routes it to the
lane below.

**Manual path — direct sling:**

```bash
gc sling vllm/feature-dev feature-dev --formula \
  --var bead_id=<the-assignment-bead-id> \
  --title "implement <thing>"
```

feature-dev branches `paude/<bead_id>` off `origin/main` **in its own
worktree**, implements, runs tests, and **pushes** (the durable output). It does
**not** open a PR unless the assignment says to, and it **never closes the
arc/tracking bead** — that closes on a real checkpoint (PR opened, CI green,
merged), not on self-report.

## Deliberate boundaries (not yet crossed)

- **Reviewers are read-only.** They inspect a diff and emit a verdict; they run
  no PR-supplied build/test steps. Giving a reviewer execution rights over
  untrusted upstream code on the gascity host is the exact risk container
  isolation exists to contain — it's a separate, explicit decision, not implied
  by this pack.
- **feature-dev is a single lane** (`max_active_sessions = 1`) by design: one
  writer, one write worktree, no writer-vs-writer races.

## Growing up (later)

- **Customize the reviewer checklist** in `prompt.template.md` with the
  follow-up questions you always end up asking — that's the real reviewer spec.
- **Quorum**: add a second reviewer step + a synthesis step that `needs` both,
  modeled on core's `mol-review-quorum`. `pr-review.v1` is a subset of that
  formula's `review-quorum.lane.v1`, so the synthesis step consumes these lanes
  unchanged.
- **Auto-trigger**: wrap the review in an order (`event` on PR-open, or `manual`
  fired by `gc order run`) once you trust the gate.
- **More reviewers**: bump `max_active_sessions` in `agents/reviewer/agent.toml`;
  the worktree-per-slot mechanism scales with it unchanged.
