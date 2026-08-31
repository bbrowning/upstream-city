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

- `trusted`: at most one in-scope check may auto-run.
- `limited`: external input may only propose a human-dispatched dynamic check. A
  canonical internal-producer artifact may run one scoped check because its identity
  cap comes from local workflow provenance; content-derived `limited` reasons remain
  visible in the verdict and gate evidence.
- `restricted` or `block`: no changed code runs, regardless of authority.

`run-scoped-check.sh` independently re-derives posture and, for internal execution,
revalidates the producer ledger binding and exact immutable range. It rejects
restricted/block content regardless of producer, accepts prepared-environment Python
test commands and (for internal-producer authority only) the exact isolated-uv CI
reproducer form, rejects shell metacharacters and out-of-scope targets, verifies
the expected head, bounds time and output, and records git status before and after.
`--ci-color` unsets inherited `NO_COLOR` and forces a color-capable terminal so
rendered-output assertions can reproduce CI behavior. Network and environment
limitations produce `could_not_verify`.

Before selecting that one check, review lanes run
`scan-rendered-output-assertions.py` over newly added test lines. A raw option-token
assertion against `.output`/`.stdout` is deterministic major evidence when the test
does not use the repository's ANSI-stripping helper; the reported pytest node takes
priority for a `--ci-color` check. This static contract still returns
`request_changes` if the runtime environment cannot be prepared.

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

## Maintainer gates

- `gc lint dev-pack` validates pack structure and formulas.
- `dev-pack/tests/workflow-contract.sh` binds policy defaults, wrappers, rich
  command help, and the operator runbook.
- `dev-pack/tests/local-only-implementation.sh` rejects publication behavior.
- Artifact, review, closure, persona, escalation, and interactive-terminal tests
  exercise their named contracts.
- Installed formula rendering on each supported rig catches composition drift.

The full copy-paste gate is maintained in the operator runbook. Storage and city
backup behavior is deliberately separate in
[`docs/day2-operations.md`](day2-operations.md).
