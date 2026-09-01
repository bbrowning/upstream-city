# Dev-pack design and durable contracts

This is the maintainer reference for the current `dev-pack` implementation.
Operator workflows and commands live in [`dev-pack/README.md`](../dev-pack/README.md).
Rig attachment and environment wiring live in
[`docs/rig-bootstrap.md`](rig-bootstrap.md#enable-dev-pack-on-the-rig).

## Architecture

Feature, hard-bug, and review are different inputs to one workflow spine:

```text
entry artifact -> isolated analysis/implementation -> immutable evidence
              -> independent review -> strict synthesis
              -> evidence settlement when needed -> approve or bounded revision
```

The pack follows Gas City's conventional `agents/`, `formulas/`, `commands/`,
`doctor/`, `assets/`, and `template-fragments/` layout. Lane-specific formulas
share the following durable boundaries:

- Feature produces a local implementation and hands `local-change.v1` to the
  shared change lifecycle.
- Hard bug uses one- or two-lane diagnosis formulas, a coordinator-owned bounded
  convergence state, then the same local-change lifecycle.
- Review accepts a PR/ref or immutable local-change provenance. N=2 uses two
  independent reviewer profiles and a synthesizer; N=1 uses the solo formula.
- Settlement is a separate evidence step used only for disputed major findings.
- Command wrappers select policy defaults from
  `dev-pack/assets/workflow-policy.json`; formulas remain static consumers.

Template fragments single-source recovery, method discipline, persona loading,
output requirements, and worktree guards. Shared scripts resolve targets,
construct artifacts, validate schemas, render mail, and update lifecycle state.

Every pooled role has one mandatory first action: `claim-trigger.sh` resolves
`GC_TRIGGER_BEAD_ID` exactly, confirms the route, then claims only that bead while
replacing `gc.session_name` and `gc.work_dir` in the same mutation and verifies the
committed ownership/provenance afterward.
Neither `gc prime` nor ready-list discovery is allowed to select an assignment.
This makes stale provenance repair part of the successful exact claim instead of a
best-effort rollback after a foreign claim.

External PR dispatch has a controller-owned readiness barrier. The launcher first
resolves the advertised GitHub head, fetches it into a staging ref, verifies the
exact SHA, and atomically creates a SHA-named shared ready ref. Only then can the
formula create reviewer work. Lanes retain the PR number for metadata but diff the
pinned commit, recheck remote head drift, and classify a missing object as transient
infrastructure failure rather than review evidence.

## Worktree isolation and reaping

Managed agents never implement in the rig root. Their `pre_start` hook calls the
shared worktree setup and assigns a branch/worktree keyed to the agent slot. Each
slot therefore has its own index and working files while sharing the rig's git
object database. A guarded prompt and emission-time checks verify that the agent
is still in the expected repository, worktree, branch, and SHA.

Managed slot worktrees are disposable. Gas City may reuse or reap them, so no
consumer may treat a slot path as the durable output. The contract is the local
branch plus immutable commit SHA and structured artifact.

Human PR materialization is intentionally separate:

```text
<city>/pr-worktrees/<rig>/pr-<N>
```

These PR-keyed worktrees are outside `.gc`, are never agent slots, and survive
slot reuse and `gc stop --clean`. `materialize --remove` is the explicit cleanup
path. `ask` uses this same real worktree; its interactive rendezvous/session
metadata does not make the worktree an agent-slot scratch tree.

## Durable schemas and closure

### `local-change.v1`

Feature and bug implementations emit the same immutable object after committing.
It records producer rig/workflow/bead, repository and linked-worktree identity,
base ref and resolved SHA, local branch and head SHA, ordered commit messages and
digests, changed paths, verification claims, creation provenance, and revision
lineage. Revision 1 has no predecessor; later revisions name the prior artifact
and the feedback verdict that caused the revision.

Before emission, commit-series validation enforces repository-local policy,
nonempty commit bodies, subject/body separation, wrapping, and line budgets.
It also separates attribution from DCO certification: project-appropriate AI
attribution is allowed, detectable agent/model/bot `Signed-off-by` trailers are
rejected with human extraction guidance, and valid human sign-offs are preserved.
The gate reports immutable evidence and never rewrites commit history or manufactures
a human identity.
Artifact review verifies same-repository identity and that the branch still
resolves to the recorded SHA. Internal-producer execution authority additionally
requires an allowlisted producing workflow and the producer work bead's durable
`gc.lifecycle_json` to bind the exact artifact id, intent, revision, branch, and SHA.
Content addressing alone is not producer provenance. Rewriting history requires a
new artifact revision.

### Review verdicts

Review lanes emit versioned `pr-review.v1`-compatible evidence; quorum synthesis
adds independent-lane provenance while preserving the common summary contract.
Local implementation reviews include artifact id, revision, repository id,
branch, and exact base/head SHAs. The summary renderer and mail emitter consume
the stored evidence rather than an agent's transient prose.

### Lifecycle state

`gc.lifecycle_json` on the parent tracks artifact, branch, head SHA, revision,
disposition, and review lineage. Approval closes only when the reviewed branch
still resolves to the exact approved SHA. Request-changes produces a new commit
and artifact revision. Bounded exhaustion records `gc.lead_escalation_json` and
routes evidence to the rig lead without weakening the local-only or approved-only
closure rules.

## Review posture and dynamic execution

`pr-prescan.sh` deterministically derives the maximum posture from PR metadata and
changed content. Prompts may downgrade that ceiling but cannot raise it. Execution
authority is a separate input: external PR/ref review uses GitHub/operator identity;
canonical local output uses the validated producer lifecycle described above.

- `trusted`: one bounded verification plan may auto-run: at most two distinct
  coverage-axis checks plus one final decisive follow-up.
- `limited`: external input may only propose a human-dispatched dynamic check. A
  canonical internal-producer artifact may run the same bounded plan because its identity
  cap comes from local workflow provenance; content-derived `limited` reasons remain
  visible in the verdict and gate evidence.
- `restricted` or `block`: no changed code runs, regardless of authority.

At `trusted`, external and internal-producer authority receive the same read-only
fetch latitude permitted by the city's network egress sandbox; that sandbox is the
hard destination and method boundary. This does not permit local artifact resolution
to fetch Git refs or contact a repository remote. Internal artifacts capped at
`limited` remain `FETCH=none` even though their validated producer authority permits
one bounded plan.

The original exactly-one/smallest-check rule bounded exposure to changed code,
resource use, captured output, and accidental writes, but coupled that safety limit
to review quality: one passing narrow node could exhaust the allowance without
exercising another independent changed behavior. The replacement separates those
concerns. `run-dynamic-verification.sh` admits one plan with up to two distinct
coverage axes and one final follow-up, while retaining the old aggregate worst-case
envelope of 600 seconds and 64 KiB. The follow-up runs only after planned coverage
passes cleanly; it closes a statically identified keystone rather than retrying.

For every plan entry, `run-scoped-check.sh` independently re-derives posture and,
for internal execution, revalidates the producer ledger binding and exact immutable range. It rejects
restricted/block content regardless of producer, accepts prepared-environment Python
test commands, rejects shell metacharacters and out-of-scope targets, verifies the
expected head, bounds time and output, and records git status before and after.
Network and environment limitations produce `could_not_verify`. Each command is
exact-head pinned and path/command allowlisted, uses the prepared environment,
inherits the city egress boundary, and records cleanliness; a mutation stops the
plan. External limited plans still require exact human approval. Quorum synthesis
preserves every lane's axis-tagged evidence. Settlement remains static-first and
surfaces a decisive bounded request when file:line evidence cannot close the crux.

Trusted-author and internal-producer authority change identity posture only. File-pattern,
dependency, CI, serialization, and dynamic-execution caps still apply, and the
strictest signal wins. Restricted and block signals can never be overridden. Keep
the allowlist tracked because it controls unattended execution eligibility.

## Personas

Rig-specific knowledge lives outside the generic pack at `$GC_PERSONAS` (for
example `tools/vllm/personas/`). `base.md` holds small cross-cutting reflexes;
domain files declare activation paths and contain terse, checkable facts.
Deterministic selection loads base plus only the personas relevant to symptom,
planned, or changed paths.

The same facts serve diagnosis, design, implementation, change-review, and
settlement through lane-specific lenses. Structured outputs record persona traces
for material influences. Persona content is read fresh on each run; changing the
path wiring or prompt requires reload, but editing corpus content does not.

`dev-pack/tests/persona-lifecycle.sh` enforces size budgets, unique activation
domains, valid lens wiring, regression-case coverage, and selective loading.
Project-specific evaluation material belongs beside the rig's corpus, not in the
pack.

## Notification boundary

Schema-aware emitters validate one complete JSON object, store it on the bead,
close only after storage succeeds, and then render readable mail. Notification
routing is operator policy (`GC_PR_NOTIFY_TO`); disabling built-in mail does not
remove the durable bead evidence. Interactive `ask` is intentionally outside this
boundary: it emits, closes, and mails nothing, while asynchronous ask answers are
durable follow-ups chained to the root verdict.

Before any output/provenance mutation, emitters revalidate their target against the
launch trigger (including the uniquely resolved retry attempt), acquire a city-wide
per-bead lock shared across worktrees, and require `gc.output_json` to still be empty.
A competing or stale writer therefore fails closed instead of overwriting a durable
verdict, bug result, feature handoff, or follow-up answer.

## Human attention projection

`gc dev-pack work` is a CLI projection over existing authority, not a workflow or
another state machine. At the city root it reads HQ and every initialized rig; from
inside a rig it reads only that rig unless `--citywide` or `--rig` overrides scope.
All ledger subprocesses use `bd --readonly`. The command never calls mail, writes a
cache, updates a bead, or records its derived group.

The human-facing selection contract is ownership/assignment to an explicit actor
identity or one of the documented attention labels. Negative labels opt out.
Workflow retries, molecule steps, messages, gates, order bookkeeping, and agent
infrastructure are evidence only, so their titles cannot accidentally promote them.
Generic beads remain visible even when they do not carry dev-pack output.

Grouping precedence is deterministic:

1. A closed human bead is RECENTLY FINISHED within the configured window.
2. Canonical blocked/deferred status, hold/wait labels, or unresolved dependencies
   are WAITING ON OTHERS.
3. An explicit action marker, final review/change evidence, or local artifact drift
   under an open human bead is NEEDS YOU. Explicit action markers outrank waits;
   otherwise a trustworthy recorded wait outranks automation completion.
4. `in_progress` or active workflow children are IN FLIGHT.
5. Remaining open work is STALE OR UNCLEAR because it has neither progress nor a
   trustworthy wait.

`dev-pack-work.v1` records the local-ledger authority, observation/source timestamps,
reason, next action, rig/id, and authoritative output pointer for every item. `work
show` adds the raw source bead, parsed output/lifecycle, child evidence, and local
branch comparison; PR review output uses the existing verdict renderer for text.
The offline MVP explicitly defers `--watch` until Gas City exposes an event-driven
read-only multi-store refresh boundary. Routine GitHub review launch first resolves
or creates exactly one external-ref-bearing human source bead under a per-ref lock,
then stamps that source and the exact materialized SHA on the durable result step.
The attention projection reconciles that reviewed SHA with GitHub's current exact
head and state. Legacy results without a reviewed SHA remain actionable uncertainty.

Normal use reuses a fresh disposable GitHub cache and refreshes stale entries;
`--refresh` forces bounded read-only observation and `--no-network` uses only local
evidence/cache. Cache entries are freshness-labeled, atomically replaced, and capped
at 128. `work audit` reads (without acknowledging) message beads, normally hidden
durable outputs, their human sources, and GitHub observations to enforce zero
coverage omissions. Neither projection nor audit changes bead/mail/GitHub state.

The PR handoff intentionally has two phases. `work show` and `feedback` remain pure
readers: they identify the exact reviewed head, link the PR, and render the recommended
GitHub review text. The maintainer submits the review upstream. Only the separate
`reconcile` command may update the source bead, and only after a forced live GitHub read
confirms the current head and the observed `APPROVED` or `CHANGES_REQUESTED` state. This
keeps bead disposition downstream of upstream truth without granting the pack GitHub
write authority or changing human-mail behavior.

## Maintainer gates

- `gc lint dev-pack` validates pack structure and formulas.
- `dev-pack/tests/workflow-contract.sh` binds policy defaults, wrappers, rich
  command help, and the operator runbook.
- `dev-pack/tests/local-only-implementation.sh` rejects publication behavior.
- Artifact, review, closure, persona, escalation, and interactive-terminal tests
  exercise their named contracts.
- `dev-pack/tests/work-attention.sh` locks selection, five-way grouping, scope,
  bounded JSON/show output, internal suppression, watch deferral, and read-only calls.
- Installed formula rendering on each supported rig catches composition drift.

The full copy-paste gate is maintained in the operator runbook. Storage and city
backup behavior is deliberately separate in
[`docs/day2-operations.md`](day2-operations.md).
