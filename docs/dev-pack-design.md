# Dev-pack convergence — design + port plan

Status: **Phases 0–2 built (local commits; unpushed).** Kickoff doc for the macro
session that merges `pr-review-pack` + `hard-bug-pack` (+ the nascent `feature-dev`
lane) into ONE pack — now `dev-pack`. Phase 2 (lane consolidation) is done: one
`dev-pack/` with lane-prefixed agents (`pr-*`/`bug-*`/`feature-dev`), verb-per-lane
commands (`review`/`bug`/`feature` + `materialize`/`summary`/`status`), one
`GC_PERSONAS`, and the single-sourced lens-parameterized `persona-load` fragment.
Remaining: Phase 3 (N-dial) + Phase 4 (feature lane + governance).
Primitives below are grounded against gascity **v1.4.0** source (`/pvc/workspace/rigs/gascity`,
`cmd/gc/prompt.go`, `internal/config/*`) + the installed `gc`, not the docs (docs drift — see
end). Re-verify against live source before implementing (see [[verify-gascity-against-live-source]]).

## Why (the reframe)

PR-review, bug-fix, and feature-dev are **one workflow with different inputs**:

> decompose → verify claims → converge → (optionally) act → check

over a **per-rig knowledge corpus**. Everything that differs is either the *entry artifact*,
the *output schema*, or a **dial** — not a separate machine. hard-bug's phase machine
(diagnose → converge-root-cause → converge-fix → implement → cross-review) is ~90% of the
general form. This matches gascity's own intended model: one pack "declares those agents,
formulas, and orders" and hosts many roles as sibling `agents/` dirs.

## Grounded primitives (what we build on)

| Need | Mechanism (code-verified) | Verdict |
|---|---|---|
| One pack, many roles | convention dirs `agents/ formulas/ commands/ doctor/ orders/ template-fragments/` (`revision.go:356`); no count limit; `pr-review-pack` already = 4 agents/3 formulas | WORKS |
| **Single-source shared prompt prose** | **template-fragments**: `{{define "x"}}…{{end}}` → `{{template "x" .}}` inline **or** `append_fragments=["x"]`; precedence pack→**city-root wins**→agent (`prompt.go:127-206`); `[agent_defaults] append_fragments` = city-wide | WORKS |
| Shared base prompt, per-lane variation | `agent.toml prompt_template` can point at another agent's file (proven: `hb-worker-b`→`hb-worker-a`); branch via `{{templateFirst}}`/fragments | WORKS |
| Per-rig knowledge | **env idiom**: `GC_…_PERSONAS` dir via `[[rigs.patches]] env` (or `[agent_defaults] env`); read by prompt `{{.GC_…}}` and scripts `$GC_…` (`prompt.go:317-321`). No richer primitive — this fork's axiom is "the model IS the skill system" | WORKS (right idiom) |
| Per-agent knobs | `[[rigs.patches]]` = `AgentOverride` ~40 fields: `env option_defaults provider prompt_template overlay_dir append_fragments pre_start work_dir …` (`config.go:662-795`); env/option_defaults additive-merge | WORKS |
| Physical files in workdir | **overlays** = dir-tree copied into the agent workdir at session start, provider-aware, `settings.json` deep-merged (`internal/overlay/overlay.go`). NOT config, NOT prose | WORKS |
| One entrypoint per lane | `commands/<name>/{command.toml,run.sh}` → `gc <pack> <cmd>` (namespaced); run.sh gets `GC_BIN GC_CITY_PATH GC_PACK_DIR` then `gc sling` (`hard-bug-pack/commands/start`) | WORKS |

Footguns (code-confirmed): **rig-patch `option_defaults` is NOT validated at `gc reload`** — a
bad model silently falls back at launch → gate merges with `gc lint` + E2E, not reload.
"fragment" is **overloaded**: config-fragments (`includes`/TOML merge) ≠ template-fragments
(prompt partials) — we mean the latter. `assets/` + top-level `overlays/` are **not**
convention-discovered (inert unless a path points at them).

## Target architecture — one pack, three lanes, shared spine, orthogonal dials

**SPINE (shared, in the pack) — the thing worth converging:**
- `template-fragments/`: `method-discipline` (verify keystones; ground-truth cheap facts;
  hedge unverified mechanisms — today's B tweak, single-sourced), `persona-load` (load base +
  the personas whose `Activates on:` matches the lane's entry paths/subsystems; skip
  out-of-lane lenses), `second-opinion` (consider/refute discipline), `output-atomic`
  (emit-json/verdict close), `worktree-guard`.
- shared scripts (dedupe on merge): `emit-json.sh` (generic; hard-bug already uses it),
  `worktree-setup.sh` (**both packs ship one — collapse to one**), posture/prescan/fetch
  (posture lane only).
- generic agents: a **worker** (runs the lane's decompose/act) + a **coordinator** (drives the
  outer loop; runs convergence only when opinions N≥2). Reuse hard-bug's coordinator as the
  driver.

**LANES (thin specializations = entry artifact + output schema + playbook; a formula + a
per-lane prompt fragment):**
- **review**: diff/PR → merge verdict; posture-gated (triage→posture→fetch/execute); N usually 1.
- **bug**: symptom/bead → root-cause + fix; N=1 (solo) or 2 (cross-opinion).
- **feature**: intent/spec → implementation + tests; autonomy = implement.

**DIALS (orthogonal, per-run vars/patches) — the "make 2nd opinion optional" insight:**
- **opinions N=1..k.** The reconcile/second-opinion machinery is gated on N≥2. **B (self-verify
  keystones) applies at every N; C (correlated-convergence gate) only exists at N≥2.** At N=1
  the coordinator degenerates to a self-check pass (or is skipped). This is the seam that makes
  hard-bug a generic bug-fixer and lets review reuse the same engine.
- **autonomy**: report-only → implement+push (already the `enable_loop`/finalize split).
- **posture**: trusted → gated (the triage ladder; a bug/feature from an external issue opts in).

**KNOWLEDGE (per-rig, OUTSIDE the pack):** `tools/<rig>/personas/` (rename from
`review-personas`; tri-consumer). One env (`GC_PERSONAS`, rig-scoped value via a patch) read by
all lanes. Reflexes carry per-lane **lenses** (review / diagnosis / design) — same fact, one
home (e.g. `parser.md #4` already has review + diagnosis lenses).

**EVAL / FLYWHEEL (per-rig, OUTSIDE the pack):** `tools/<rig>/eval/` (rename from `review-eval`),
**three case families** (review, diagnosis, feature). This is the governance engine ↓.

## Leanness governance — actively fight corpus bloat (LOAD-BEARING)

Three consumers pulling from one corpus multiplies the tendency to accrete verbose low-value
cruft. Counter-pressures, enforced not hoped:
1. **The bar stays** (four tests: counterfactual / grounded / checkable / terse; + the 5th for
   verification reflexes: name *what* to fetch and *when*). Additive-only to validated reflexes.
2. **Budget the always-loaded context.** Hard line-count caps: `base.md` ≤ ~40 lines, each
   domain persona ≤ ~80. Adding a reflex must fit budget or **evict a weaker one** (`prune as
   you add`, enforced by a size check, not etiquette).
3. **Every reflex is a regression test or it's deleted.** A reflex with no case that flips
   miss→catch on its account is unproven. Periodic **prove-your-keep sweep**: re-run cases with
   the reflex removed; if the case still catches, the reflex is dead weight → evict.
4. **Attribution + decay.** Record which reflex fired in which catch (evidence provenance). A
   reflex that never fires across a window of real runs → review for removal.
5. **Cross-lane is eviction pressure, not accretion.** A reflex must earn its keep in ≥1 lane
   AND not add noise to the others (validate against all case families — already in RUNBOOK). If
   it helps bug but noises review, it becomes a **lane lens**, not a base reflex.
6. **Lint/CI gate on the corpus:** size budget + "every reflex has a case" + no duplicate
   `{{define}}` names + no orphan lenses.

## Port plan (phased; each phase E2E-gated; nothing live until `gc reload` + Ben pushes)

- **Phase 0 — spine extraction (no behavior change).** Create the pack dir (name TBD). Dedupe
  `worktree-setup.sh`; move generic scripts in. Extract `method-discipline` / `persona-load` /
  `second-opinion` / `output-atomic` template-fragments from the current prompts; repoint the
  *existing* pack prompts to `{{template …}}`/`append_fragments`. Gate: `gc lint` clean + one
  review + one hard-bug E2E behave identically.
- **Phase 1 — knowledge unification.** `tools/vllm/review-personas` → `tools/vllm/personas`;
  single `GC_PERSONAS` via `[agent_defaults] env`; all lanes read it. `review-eval` → `eval`
  (keep families). Gate: reviewer + hard-bug still pass their cases.
- **Phase 2 — lane consolidation. [DONE — local commit, unpushed]** Merged both packs into
  one `dev-pack/` (dir + `pack.toml` name); agents lane-prefixed for cross-pack clash-safety
  (`pr-triage`/`pr-reviewer`/`pr-runner`, `bug-coordinator`/`bug-worker-a`/`bug-worker-b`,
  `feature-dev`); only real collision was the two byte-identical fragments (collapsed to one).
  Command UX is verb-per-lane under `gc dev-pack`: `review`/`bug`/`feature` (kick-off) +
  `materialize`/`summary`/`status` (helpers); `start`→`bug`, added `review`+`feature` wrappers.
  `persona-load` single-sourced as **one lens-parameterized fragment**
  (`{{template "persona-load" "review"|"diagnosis"}}`) now that the merge gives one
  `template-fragments/`. city.toml `includes=["dev-pack"]`; patch targets repointed. Gates:
  `gc lint dev-pack` ok + `gc doctor`; Ben runs `gc reload` + review AND hard-bug E2E.
- **Phase 3 — the N-dial.** Make the second opinion optional in the bug lane (N var; N=1 skips
  reconcile, keeps self-verify); generalize the coordinator to drive any lane's outer loop.
  Gate: prove an N=1 bug run and an N=2 bug run.
- **Phase 4 — feature lane + governance.** Grow `feature-dev` into the full
  decompose→design→implement→test→cross-review over the spine; add the feature case family + the
  leanness lint gate. Gate: feature E2E + the corpus lint gate green.
- **Retire** `pr-review-pack` + `hard-bug-pack` (archive) once the pack passes all lane E2Es.

## Open decisions (macro session)
1. **Pack name** — resolved: **`dev-pack`** (Phase 2; Ben may rename later — agents are
   lane-prefixed, not pack-prefixed, so a rename won't churn agent names).
2. **One generic coordinator + lane var, or per-lane coordinators?** (lean: one generic.)
3. **Knowledge env name**: generic `GC_PERSONAS` (rig-scoped value) vs `GC_<RIG>_PERSONAS`.
   (lean: generic name, per-rig value via patch.)
4. **Phase machine**: formulas are compile-time DAGs (can't be one fully-generic formula), so
   lanes stay separate formulas that all consume the shared spine fragments. Confirm.
5. **Rename churn tolerance** (`review-personas`→`personas` touches eval + reviewer prompt +
   city env). Do it in Phase 1 behind E2E.

## Watch-outs (from code grounding)
- **Namespace collisions on merge:** agents/formulas/commands share one pack namespace;
  template-fragments collide by `{{define}}` name (last-loaded wins). Rename dups; collapse the
  two `worktree-setup.sh`.
- **`option_defaults` typos are silent** at reload → `gc lint` + E2E, never reload alone.
- **Lanes stay pool agents** (a `[[named_session]]` on a pool agent fails lint).
- **overlays ≠ fragments ≠ patches** — file-staging vs shared prose vs per-lane knob; use the
  right layer.
- **Docs drift:** command dispatch is `gc <pack> <cmd>` (not top-level `gc <cmd>` as the docs
  show); docs are silent on fragments/overlays/patches — trust the source.

Related: [[hard-bug-verification-gap-fix]] (the B/C discipline this generalizes),
[[pr-review-lean-persona-pivot]] (persona single-source + the harvest-don't-dump ethos),
[[pr-review-eval-harness]] (the flywheel + case families), [[pr-review-invariant-signal-vs-noise]]
(the four-test bar), [[verify-gascity-against-live-source]].
