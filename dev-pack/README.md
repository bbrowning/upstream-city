# dev-pack — one engineering-workflow pack: review · bug · feature, worktree-isolated

**PR-review, hard-bug fix, and feature-dev are one workflow with different inputs**
— decompose → verify → converge → (optionally) act → check, over a per-rig persona
corpus. This pack hosts all three as sibling lanes over one shared spine, on a
single rig, with the same "zero chance of stomping on each other" guarantee you'd
get from N separate containers by hand — but from **native gascity mechanics
alone** (no phantom `isolation="worktree"` primitive; that does not exist in
v1.4.0). Each agent slot runs inside its **own git worktree**.

| Lane | Kick off | What it does |
|---|---|---|
| **review** | `gc dev-pack review <PR>` | posture-gated PR review → a structured merge verdict (read-only + one trusted auto-check) |
| **bug** | `gc dev-pack bug <bead>` | two independent lanes diagnose + act as each other's second opinion until root cause & fix converge; the stronger implements + tests, the other cross-reviews |
| **feature** | `gc dev-pack feature <bead>` | implement an assignment on a `paude/<bead>` branch, run tests, push |

Helpers: `gc dev-pack materialize <PR>` (durable human checkout) ·
`gc dev-pack summary <bead|PR>` (re-render a stored verdict) ·
`gc dev-pack status <bead>` (a bug arc's phase/round/status).

All lanes share one persona corpus (`$GC_PERSONAS`) and one method spine
(`template-fragments/`: `recovery-header`, `worktree-guard`, and the
lens-parameterized `persona-load`). Each lane is a thin specialization = its entry
artifact + output schema + a formula.

> Grounded against **gascity v1.4.0** (installed binary + source). Every
> mechanism below is verified against live behavior: this pack is built,
> installed on the `vllm` rig, and has run PR reviews and two-opinion hard-bug
> diagnosis end-to-end.

## The flow at a glance (the "aha")

The whole loop, human's-eye view — a review is a **push**, and you never go
hunting for its result:

```
   you ──"review PR 51296"──▶  vllm/lead ──dispatch──▶ reviewer slot (own worktree)
                                                              │
        emits pr-review.v1 verdict on its step bead ◀─────────┘
                                                              │
   inbox ◀── verdict mail — subject + full summary ───────────┘   ← comes to YOU
     │
     ├─ verdict + reasoning + nits are already in the body → make the merge call. Done.
     │
     ├─ want it again later? (verdict mail is ephemeral)
     │      gc dev-pack summary 51296       ← re-render the verdict, LLM-free
     │
     └─ want to see/run the code yourself?
            gc dev-pack materialize 51296   ← durable checkout on disk
            cd <city>/pr-worktrees/vllm/pr-51296
            git diff origin/main...HEAD           ← read it
            # run the reviewer's suggested dynamic_request.command right here
```

A few things make this ergonomic instead of a scavenger hunt:

1. **The verdict comes to you — readable.** On finish, the reviewer drops the full
   summary in your mail (`gc mail check`): a one-line subject (so five parallel
   reviews are still five scannable lines, not five metadata digs) plus a body with
   the verdict's reasoning and every finding — no JSON to parse, nothing to ask the
   lead to render. Re-read any verdict later with `gc dev-pack summary
   <bead|PR>`, and the raw JSON stays on the bead. See
   [Read the verdict](#read-the-verdict-this-is-the-gate).
2. **You can always get the code back.** The reviewer's own worktree is transient
   per-slot scratch (reused across PRs), so after a review closes there is no tree
   on disk with that PR's bits. `gc dev-pack materialize <PR>` re-checks it
   out into a **durable, human-owned** worktree that agent slot-reuse and
   `gc stop --clean` never touch. See
   [Materialize a PR for human review](#materialize-a-pr-for-human-review).
3. **Trusted PRs get tested, not just read.** When the deterministic ceiling is
   `trusted`, the reviewer auto-runs one in-scope check and folds the result into
   the verdict; a `limited` PR surfaces a scoped check you can approve with one
   sling. See [Dynamic checks](#dynamic-checks-running-a-prs-tests).

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
- **Direct sling is the manual / power-user path** (`gc sling vllm/pr-reviewer …`,
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
pre_start = ["{{.CityRoot}}/tools/shared/worktree-setup.sh {{.RigRoot}} {{.WorkDir}} {{.AgentBase}}"]
```

(`worktree-setup.sh` is the **shared spine** script, single-sourced at the city
root in `//tools/shared/`, so `{{.CityRoot}}` resolves right there. A script that
lived *in* this pack would instead use `{{.ConfigDir}}` = the pack dir.)

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
# --- review lane ---
agents/pr-triage/                     # deterministic-first posture triage (1 slot)
agents/pr-reviewer/                   # posture-gated reviewer, pooled up to 2 slots (own worktree each)
agents/pr-runner/                     # human-approved dynamic-check lane (1 slot)
formulas/pr-review.toml               # triage → review TASK + pr-review.v1 verdict contract
formulas/pr-review-dynamic.toml       # human-approved check TASK + pr-review-dynamic.v1 contract
# --- bug lane (two opinions until convergence) ---
agents/bug-worker-a/                  # lane A: diagnose / reconsider / implement / cross-review (1 slot)
agents/bug-worker-b/                  # lane B: same method (shares worker-a's prompt), different model
agents/bug-coordinator/               # protocol driver (1 slot): convergence call, relays, cap, escalation
formulas/hard-bug-round.toml          # one round: two lanes + coordinator reconcile fan-in
formulas/hard-bug-finalize.toml       # implement → cross-review → finalize
# --- feature lane ---
agents/feature-dev/                   # single write lane (1 slot): branch/push, never self-close arc
formulas/feature-dev.toml             # per-run implement TASK + feature-dev.v1 report contract
# --- shared ---
orders/fetch-origin.toml              # read-only `git fetch --prune` on a cooldown (warm refs)
commands/review/                      # `gc dev-pack review <PR>`     — start a PR review
commands/bug/                         # `gc dev-pack bug <bead>`      — start a two-opinion hard-bug run
commands/feature/                     # `gc dev-pack feature <bead>`  — start a feature implementation
commands/materialize/                 # `gc dev-pack materialize <PR>`— durable human checkout
commands/summary/                     # `gc dev-pack summary <bead|PR>`— re-render a verdict readably
commands/status/                      # `gc dev-pack status <bead>`   — a hard-bug arc's durable state
template-fragments/recovery-header.template.md  # `gc prime` recovery note (every prompt)
template-fragments/worktree-guard.template.md   # "you're in your own worktree; abort in rig root" guard
template-fragments/persona-load.template.md     # load base + activated personas; lens-parameterized
assets/scripts/pr-prescan.sh          # deterministic, injection-proof posture ceiling (review)
assets/scripts/posture-latitude.sh    # pure posture → FETCH/EXEC/GATE table (review)
assets/scripts/run-scoped-check.sh    # the deterministic EXEC gate for dynamic checks (review)
assets/scripts/emit-verdict.sh        # review-lane atomic finish: write verdict + close + notify human
assets/scripts/render-verdict.sh      # verdict JSON → human-readable summary (mail body + `summary` cmd)
assets/scripts/emit-json.sh           # bug-lane schema-agnostic atomic finish: write + set outcome + close
assets/scripts/fetch-origin.sh        # the fetch order's exec body
# worktree-setup.sh lives at //tools/shared/ (shared spine — see "How the isolation actually works")
```

The pack is **project-agnostic** — nothing above mentions vLLM. Actually running a
PR's tests needs a project-specific env, kept **out** of the pack: for vLLM that is
`//tools/vllm/vllm-testenv.sh` (a fast CPU-only, no-compile venv builder), wired to
the `vllm` rig via `[[rigs.patches]]` env (`$GC_PR_TEST_VENV`) — see
[Dynamic checks](#dynamic-checks-running-a-prs-tests). The generic gate
(`run-scoped-check.sh`) only consumes `$GC_PR_TEST_VENV`; it never builds it.

The same split applies to the **review personas**: the *mechanism* (the reviewer loads
`base` + the personas a PR's changed paths activate) lives in the pack; the vLLM *content*
lives out of the pack at `//tools/vllm/personas/`, wired via `[[rigs.patches]]` env
(`$GC_PERSONAS`). See [Review personas](#review-personas).

Agents, formulas, and orders are all discovered by **directory convention**
(gascity's `conventionDiscoveryDirNames`), so the manifest carries **no
`[[named_session]]` blocks**. Both agents are *pool* agents (they set
`min/max_active_sessions`), and `gc lint` forbids a `named_session` that targets
a pool-controlled agent — pools are auto-discovered and expanded by the `scope`
in their own `agent.toml`, exactly like hyperscale's `worker` or swarm's
`coder`. `min_active_sessions = 0` makes them on-demand.

## Install

This is a normal pack. Copy it into the city and attach it to the `vllm` rig.

**Prerequisite:** the city (controller/supervisor) must be up (`gc status`). The
`vllm` rig itself does **not** need to be started first — slinging work to an
on-demand slot auto-materializes the rig and the session.

1. Copy the pack into the city (so `{{.ConfigDir}}` → `<city>/dev-pack`
   resolves for the `pre_start` script path):
   ```bash
   cp -rf dev-pack <city>/dev-pack
   ```
2. Attach it to the **`vllm` rig** in `city.toml` via that rig's `includes`
   list (the `Rig` struct has **no `pack` field** — rig-scoped attach is
   `includes` for a local folder / URL, or an `[rigs.imports]` table for named
   V2 bindings). Rig-scope attachment is what stamps `Dir=vllm` on the agents so
   `{{.Rig}}` resolves to `vllm` and their names become `vllm/pr-reviewer` /
   `vllm/feature-dev` (verified: `pack.go:1544` stamps `Dir=rigName` when unset).
   A city-wide attach would leave `{{.Rig}}` empty and the `pre_start` guard
   would (safely) refuse to start. Merge into your existing rig entry — keep its
   current `prefix` / `default_branch`, don't overwrite them:
   ```toml
   [[rigs]]
   name = "vllm"
   prefix = "vllm"                 # keep whatever your live config already has
   default_branch = "main"
   includes = ["dev-pack"]   # bare name → <city>/dev-pack, read in place
   ```
   `includes` takes a path relative to the city root; a bare name resolves to
   `<city>/dev-pack` and is **read in place on every `gc reload`** — no
   import/cache step (that only applies to remote URL refs). Edit a file →
   `gc reload` → live.
3. Reload and verify:
   ```bash
   gc reload                     # or gc restart, per your setup
   gc doctor                     # THIS validates the pre_start script exists on
                                 # disk (the pre-start-scripts check) — not gc lint
   gc formula list               # expect: pr-review, pr-review-dynamic, feature-dev,
                                 #         hard-bug-round, hard-bug-finalize
   gc agent list                 # expect: vllm/pr-triage, vllm/pr-reviewer, vllm/pr-runner,
                                 #         vllm/bug-coordinator, vllm/bug-worker-a, vllm/bug-worker-b,
                                 #         vllm/feature-dev
   gc dev-pack --help            # expect: review, bug, feature, materialize, summary, status
                                 # (discovered per-invocation from commands/, no reload needed)
   ```
   (Confirm exact subcommands with `gc formula --help` / `gc agent --help`.)

> **`gc lint ./dev-pack` is clean** apart from two benign warnings:
> `gc.output_json is deprecated; use drain in v2 formulas`. This is intentional
> — `drain` is for collecting from *many* child beads (fan-out); a single step
> emitting one structured verdict/report uses `output_json`, which is exactly
> what **core's own `mol-review-quorum`** formula does for all its steps. We
> share the warning with core; the pattern is the established one for reviews.

## Run a PR review

**Primary path — ask the lead.** Tell `vllm/lead` what you want reviewed ("review
PR 12345 against main"); it dispatches to a `reviewer` slot and brings the verdict
back. This is the normal flow and needs no command memorization on your part.

**Manual path — the `review` command.** Kick it off yourself with the lane verb;
`<PR>` can be a PR number `N` (the reviewer will `git fetch origin pull/N/head`
itself), a branch, or a sha:

```bash
gc dev-pack review 51296                 # defaults: --rig vllm --base origin/main
gc dev-pack review my-branch --rig vllm --base v0.6.0
gc dev-pack review 51296 --dry-run       # print the gc sling it would run
```

**Power-user path — direct sling.** The verb above is a thin wrapper around this
(what the lead uses under the hood):

```bash
gc sling vllm/pr-reviewer pr-review --formula \
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
# 1. From the sling --json output above, take the root bead id (the `bead_id` field).
# 2. Expand the workflow to find the review step bead:
gc graph <root-bead-id> --tree           # step beads + their status
# 3. Read the verdict off the review step bead:
gc bd show <review-step-bead-id> --json   # -> metadata["gc.output_json"] (raw JSON)
# …or render it as the same readable summary the verdict mail carries:
gc dev-pack summary <review-step-bead-id>   # also accepts a bare PR number
```

Or just open `gc dashboard` — it renders the workflow tree and each bead's
`gc.output_json` without hunting for ids (the friendliest path for a newcomer).

`verdict` ∈ `approve` / `approve_with_nits` / `request_changes` / `blocked`,
with `merge_recommendation` and `findings`. You make the merge call — there is
no mid-workflow human gate.

## Materialize a PR for human review

The verdict tells you *whether* to merge. When you want to see or run the change
**yourself** — read the diff with your own eyes, run the reviewer's suggested
check, poke at a new test — you need the PR's code on disk. The reviewer's
worktree won't have it: those are **per-slot scratch** (`reviewer-1` is reused
across every PR it reviews), so once a review closes nothing on disk holds that
PR's bits. Re-materialize it:

```bash
gc dev-pack materialize 51296          # a PR number → fetches origin pull/51296/head
gc dev-pack materialize my-branch       # or any branch / tag / sha
gc dev-pack materialize 51296 --base v0.6.0   # diff against a different baseline
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
gc dev-pack materialize 51296 --remove
```

> **Env note:** materialize gives you the **code**. To *run* a check in it, build
> the CPU test venv once with `//tools/vllm/vllm-testenv.sh --src .` and use
> `.venv/bin/python -m pytest …` — the very same venv the reviewer/runner use. See
> [Dynamic checks](#dynamic-checks-running-a-prs-tests).

## Dynamic checks: running a PR's tests

Phase 1 only *read* the diff. Phase 2 adds one **test-running capability**, entered
two ways, both gated by the deterministic `pr-prescan.sh` ceiling — never by the LLM:

1. **Trusted auto-run (unattended).** When triage + the reviewer's own re-scan both
   land on `trusted`, the reviewer auto-runs **one** in-scope check
   (`python -m pytest <the PR's relevant test> -q`) through
   `run-scoped-check.sh`, and records the result as `dynamic_check` in its
   `pr-review.v1` verdict. A failing test factors into the verdict; a
   network/env-limited result is reported as `could_not_verify`, not a rejection.
2. **Human-approved run (`limited` PRs).** A `limited` verdict carries a scoped
   `dynamic_request {command, reason}` — the check the reviewer *would* run. You
   approve it by slinging the `pr-review-dynamic` lane with that exact command:
   ```bash
   gc sling vllm/pr-runner pr-review-dynamic --formula \
     --var head_ref=51296 --var base_ref=origin/main \
     --var command='python -m pytest tests/parser/engine/test_deepseek_v4.py -q' \
     --var reason='approved from PR 51296 review verdict' \
     --title 'dynamic check PR 51296' --json
   ```
   The `runner` fetches the PR head into its own worktree and runs it through the
   **same gate** with `--min-ceiling limited`: if the fresh ceiling dropped to
   `restricted`/`block`, the approved command is still **declined** (a correct,
   honest outcome). It emits `pr-review-dynamic.v1` and mails you the full result
   summary (command, outcome, and output tail).

**The gate (`run-scoped-check.sh`) is where safety lives, deterministically:** it
re-derives the ceiling and refuses below the floor, requires prepared-env command
form (`python -m pytest …`, no `.venv/bin/python`, no shell metacharacters),
bounds the target to test paths, pins the head sha (optional), enforces a timeout +
output cap, and records `git status` before/after. A prompt-injected reviewer
cannot widen any of this.

### The test env (vLLM-specific, kept out of the generic pack)

Running the tests needs a Python env with vLLM importable. The trap is the full
CUDA stack (~15GB, long compile) and vLLM's non-GPU test-teardown hook, which
false-fails every test on a GPU-less box. `//tools/vllm/vllm-testenv.sh` sidesteps
both: a **fast (~35s cold / ~6s warm), ~3-5GB, no-compile** CPU venv (uv +
`VLLM_TARGET_DEVICE=empty`), tagged `+cpu` so `current_platform.is_cpu()` is true
and the teardown hook stays quiet. It is deliberately **not** in this pack (the
pack is project-agnostic); it lives in the city's `tools/` and is reusable
standalone:

```bash
//tools/vllm/vllm-testenv.sh --src /path/to/vllm-checkout   # prints <venv>/bin/python
```

Wire it to the `vllm` rig so the reviewer/runner can find or build it, via
`[[rigs.patches]]` on those agents (env reaches the agent's session + scripts —
verified in the gascity source). The gate resolves an interpreter in this order:
`$GC_PR_TEST_VENV` → a worktree-local `.venv` → **`$GC_PREPARE_TEST_ENV`** (a
builder it runs *lazily*, only when a check needs to execute):

```toml
[[rigs]]
name = "vllm"
includes = ["dev-pack"]
  [[rigs.patches]]
  agent = "reviewer"
  env = { UV_CACHE_DIR = "/pvc/workspace/.uv-cache", GC_PREPARE_TEST_ENV = "/pvc/workspace/tools/vllm/vllm-testenv.sh" }
  [[rigs.patches]]
  agent = "runner"
  env = { UV_CACHE_DIR = "/pvc/workspace/.uv-cache", GC_PREPARE_TEST_ENV = "/pvc/workspace/tools/vllm/vllm-testenv.sh" }
```

Keep `UV_CACHE_DIR` on the same (btrfs) filesystem as the worktrees so uv reflinks
the shared wheels instead of copying. Without any of these set, dynamic checks
simply report `could_not_verify` (no runnable env) — the review still lands.

**Notifications are operator policy, not the pack's.** Every review/check finishes
with `emit-verdict.sh`, which writes the verdict, closes the bead, **and** mails the
full human-readable summary (a one-line subject + a body with the summary, merge
recommendation, and every finding, via `render-verdict.sh`) to `$GC_PR_NOTIFY_TO`
(default `human`) — atomically, so the notification can't be skipped. The scanning
inbox (`gc mail inbox`) shows only the subject + a 60-char preview, so the fuller
body never clutters a scan; open a message (`gc mail read`) for the whole thing, or
re-render any stored verdict on demand with `gc dev-pack summary <bead|PR>`. To
route it elsewhere or handle notification your own way, set it in the same
`[[rigs.patches]]` env, e.g. `GC_PR_NOTIFY_TO = ""` to disable the built-in mail
(then, say, drive notifications from your own `bead.closed` order). The generic pack
ships a sensible default; the city decides.

> **Network:** the check RUN is not network-isolated; egress is governed by the
> paude-proxy. Tests may attempt downloads; when the proxy blocks one (e.g.
> openai-harmony's rust client), the agent recognizes the network-egress failure
> and reports `could_not_verify` rather than failing the PR.

## Run a feature

**Primary path — ask the lead.** Describe the change to `vllm/lead`; it scopes a
bead and dispatches it to the single `feature-dev` lane (or, for a quick
low-volume tweak, may just do it itself in the rig root — its prerogative as the
planner). For anything you want isolated on a branch, the lead routes it to the
lane below.

**Manual path — the `feature` command** (rig inferred from the bead prefix, e.g.
`vllm-123` → `vllm`):

```bash
gc dev-pack feature vllm-123               # infers rig; --base origin/main
gc dev-pack feature vllm-123 --rig vllm --base origin/main
gc dev-pack feature vllm-123 --dry-run
```

**Power-user path — direct sling:**

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

## Fix a hard bug (two opinions until convergence)

Some bugs are subtle enough that one lane's confident-but-wrong diagnosis is the
real risk. The **bug** lane runs **two independent worker lanes** (different
models) on the same bug; each produces a root cause + fix sketch and acts as the
other's **second opinion** ("consider or refute — not a mandate"). A
**coordinator** relays those opinions and makes the subjective call on when root
cause, then the fix, have converged; the stronger lane implements + tests, the
other cross-reviews the diff **and its evidence**. Load-bearing keystones (a token
id, a config default, or a causal step in the mechanism) must be **verified, not
guessed** — an unverified keystone caps confidence and hedges the mechanism.

**Primary path — ask the lead** ("investigate vllm-123"). **Manual path — the
`bug` command** (rig inferred from the bead prefix; targets filled in for you):

```bash
gc dev-pack bug vllm-123                    # Stage-1 report-only (default)
gc dev-pack bug vllm-123 --loop             # drive the full convergence loop
gc dev-pack bug vllm-123 --max-rounds 3 --lane-b-model sonnet
gc dev-pack bug vllm-123 --dry-run          # print the gc sling it would run
```

The coordinator re-slings `hard-bug-round` each round and `hard-bug-finalize` to
implement + cross-review. Track the arc's durable state any time (LLM-free):

```bash
gc dev-pack status vllm-123                  # phase / round / status / chosen implementer
```

A second real vendor for lane B is a one-line `[[rigs.patches]]` provider change in
`city.toml` (formulas and prompts unchanged) — see the manifest.

## Review personas

The reviewer's quality comes less from a generic checklist than from a **sharp,
path-specific lens** — the non-obvious things that actually bite in an area. Rather than
one growing blob injected into every review (which bloats context and dilutes attention),
that lens is **partitioned into personas**, and each review loads **only `base` + the
personas the PR's changed paths activate**.

**How it works**

- The personas live at `$GC_PERSONAS` (`//tools/vllm/personas/`): `base.md`
  (cross-cutting reflexes, always loaded) plus domain personas (`parser.md`,
  `openai-frontend.md`). Each is a terse "how you think" reflex list.
- **Personas self-route — no separate manifest.** Each domain persona declares its
  activation paths in an `**Activates on:**` header at the top; the reviewer loads it only
  when a changed path matches (more than one can match). `base.md` always loads.
- The pack's `pr-prescan.sh` stays **project-agnostic**: it reports the changed files
  (`facts.changed_files`) + generic security classes and knows nothing about vLLM domains.
  Persona activation is a plain path-prefix match the reviewer does against those changed
  files — not a security decision, so the deterministic security ceiling stays wholly in
  `pr-prescan.sh`.
- The reviewer (method step 2) reads `base.md` + each persona whose header matches, and
  reviews through that lens. Personas are read fresh each run, so **content edits are live
  on the next review — no `gc reload`** (reload is only for the reviewer prompt or the
  `$GC_PERSONAS` env wiring itself).

**Grow it (the flywheel = edit the persona file)** — when a trusted maintainer catches
something a review missed, fold it back as **one counterfactual reflex** in the right
persona (`base.md` for cross-cutting, a domain persona otherwise), validated against a
blind case. Personas carry only what a strong model does *not* already do on its own —
prune as you add. The full workflow + quality bar live in
`//tools/vllm/eval/RUNBOOK.md`, and the eval harness (`//tools/vllm/eval/`)
regression-tests a persona edit before it ships. (This replaces the old
mine → distill → `learn` invariant-corpus pipeline, now archived at `//tools/vllm/_archive/`.)

## Deliberate boundaries

- **Execution is posture-gated, never LLM-decided.** A reviewer runs code from a
  PR **only** when the deterministic `pr-prescan.sh` ceiling is `trusted`, and even
  then only one in-scope check via `run-scoped-check.sh` (which re-derives the
  ceiling and refuses if it dropped). `limited`/`restricted`/`block` PRs run
  nothing unattended — a `limited` check runs only after a **human** slings the
  `pr-review-dynamic` lane, and that lane re-checks the same deterministic floor. A
  prompt-injected reviewer cannot widen what runs. (Per-worktree sandboxed
  containers — the next isolation tier — remain deferred; today execution is
  contained to this paude container, with egress governed by the proxy.)
- **feature-dev is a single lane** (`max_active_sessions = 1`) by design: one
  writer, one write worktree, no writer-vs-writer races.

## Known bugs (fix before the "Growing up" items below)

- **[BUG · review lane · higher priority] The trusted auto-check can run against the
  BASE tree, not the PR head.** A reviewer's worktree starts detached at the rig HEAD
  (= base), so the PR's changed files don't exist until it fetches + checks out the
  head — but nothing enforces that before the check runs: the checkout is framed as
  optional / "to browse" (`agents/pr-reviewer/prompt.template.md` step 1), `git diff
  base...head` needs no checkout (so the reviewer never notices the tree is at base),
  the EXEC=allow auto-run block requires neither the checkout nor `--expect-head-sha`,
  and the gate only *assumes* the caller checked out (`assets/scripts/run-scoped-check.sh:16-17`;
  its head-SHA pin, GATE 4 `:143-147`, is optional). Result: pytest runs in the base
  tree. A **new** test file is then absent → `rc=4`, which the gate mislabels as
  `outcome:"fail"` (`:196-200` has no rc=4 case) — a spurious fail; a **modified** test
  would silently run against old code and report a meaningless pass/fail (that one won't
  self-correct). Observed on the PR #49227 E2E (bead `vllm-zmks`): the reviewer
  self-corrected (re-`checkout --detach` head, re-ran) and the final verdict was valid —
  but by model judgment, not by the deterministic gate.
  **Fix (defense in depth):** (1) **gate** deterministically verifies the tree is at the
  PR head — a target-path-exists check → honest `skipped "target-absent — checkout the PR
  head"` instead of a bogus `fail`, plus resolve `--head` and compare to `git rev-parse
  HEAD`, skip on mismatch (covers the modified-file case); (2) **prompt** promotes "fetch
  + `git checkout --detach` the PR head" from optional to a required prerequisite of the
  auto-run, and passes `--expect-head-sha` (activating GATE 4). Pre-existing (NOT a
  Phase-2 regression — the merge only renamed things here); ~a dozen lines across the
  gate + prompt; needs its own re-E2E.

## Growing up (later)

- **Rig-carrying PR specifiers for `review` (+ `materialize`).** Today a bare PR
  number is rig-less, so `review` defaults `--rig vllm` and other rigs need an
  explicit `--rig` (`gc dev-pack review --rig vllm 49227`). Make these "just work"
  without `--rig`:
  - `vllm#49227` — `<rig>#<PR>` form: split on `#`, validate the rig exists, use it.
  - `https://github.com/vllm-project/vllm/pull/49227` — a GitHub PR URL: parse
    `owner/repo` + PR number, then map `owner/repo` → the local rig by matching each
    rig's `origin` remote (`gc rig list --json` + `git -C <rig-root> remote get-url
    origin`); fall back to `--rig` / the default only if no remote matches.
  Keep the current bare-number + `--rig` path working; `--rig` stays the explicit
  override. Same parsing belongs in `commands/review/run.sh` and
  `commands/materialize/run.sh` (both take a rig-less PR today).
- **Review local commits / working-tree changes, not just PRs.** Run a full review
  round while iterating locally — a pre-PR (even pre-push) pass on a feature or bug
  fix. The review lane's real entry artifact is a `base...head` diff; a PR is just
  one way to name `head`. Extend `review` (e.g. a `--local` mode) to accept:
  - a **local branch / commit sha** — already largely reachable: the reviewer's
    isolated worktree shares the rig's git object store, so a local ref in the rig
    repo is visible **without a fetch** (skip the PR `pull/N/head` fetch path).
    Default the base to the branch point (`git merge-base origin/main <head>`), not
    a flat `origin/main`.
  - **uncommitted working-tree changes** (the real iterating case) — the reviewer's
    own worktree can't see another tree's dirty state, so snapshot it into a
    throwaway ref the reviewer can diff (`git stash create` / `git commit-tree`), or
    hand it a captured patch. This is the piece that needs real work.
  Posture is largely moot for your own local code (it's trusted; the deterministic
  prescan can still run harmlessly), so `--local` is mostly head/base resolution +
  the working-tree snapshot — not a new machine. Persona routing already keys off
  changed paths regardless of where the diff came from, so it works unchanged.
- **A "simplify" quality pass, distinct from bug review.** During iteration, run a
  pass that hunts **code smells, not bugs** — the `/simplify` complement to the
  correctness-hunting `review` lane. Scope: reuse/duplication (magic strings &
  numbers → named constants), **altitude correctness** (is the change at the right
  layer / place, or bolted onto a symptom?), dead code, naming, premature
  abstraction (YAGNI), over-complex flow. Explicitly **quality-only — it must not
  hunt for bugs** (that's `review`); the two are complementary passes, ideally both
  runnable on local iteration (see the local-commit item above).
  - Shape: a review-lane **variant**, not a new machine — same spine (worktree,
    persona-load, atomic emit), a simplify playbook + its own output schema
    (`simplify.v1`; findings tagged by smell: `duplication` / `altitude` /
    `magic-constant` / `naming` / `dead-code` / `over-abstraction`). Expose as a
    verb (`gc dev-pack simplify <ref>`) or a `--lens quality` dial on `review`.
  - Autonomy dial: report-only vs **apply the fixes in the worktree and hand back a
    diff** (what `/simplify` does) — a local pass probably wants apply + diff.
  - The lens leans on cross-cutting engineering hygiene (DRY/SRP/KISS/YAGNI/
    centralized constants — much of it model-native), so a lean simplify brief may
    beat a heavy domain-persona load.
- **Sharpen the personas** in `//tools/vllm/personas/` with the reflexes that keep
  catching real issues — that's the real reviewer spec (validate via
  `//tools/vllm/eval/RUNBOOK.md`).
- **Broaden dynamic-check coverage**: the CPU venv currently targets the hermetic,
  mock-tokenizer parser/engine unit tests. Widening to `tests/reasoning` /
  `tests/tool_parsers` (which download tokenizers) means pre-warming an HF cache;
  `vllm-testenv.sh --compile` adds real CPU kernels for tests that need them.
- **Per-worktree sandboxed containers**: the next isolation tier for running
  untrusted PR code (deferred) — today execution is contained to this paude
  container with egress governed by the proxy.
- **Quorum**: add a second reviewer step + a synthesis step that `needs` both,
  modeled on core's `mol-review-quorum`. `pr-review.v1` is a subset of that
  formula's `review-quorum.lane.v1`, so the synthesis step consumes these lanes
  unchanged.
- **Auto-trigger**: wrap the review in an order (`event` on PR-open, or `manual`
  fired by `gc order run`) once you trust the gate.
- **More reviewers**: bump `max_active_sessions` in `agents/pr-reviewer/agent.toml`;
  the worktree-per-slot mechanism scales with it unchanged.
