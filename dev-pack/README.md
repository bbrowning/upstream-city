# dev-pack operator runbook

`dev-pack` provides one local engineering workflow with feature, hard-bug, and
review entrypoints. It decomposes work, verifies claims, converges independent
opinions, implements when requested, and checks the exact resulting artifact.

The normal entrypoint is the owning rig's `lead`. Ask it in plain language:

- “Implement this feature.”
- “Fix this bug.”
- “Review PR N.”

The lead creates or identifies the rig bead and dispatches the quality-first
command. Use the commands below when operating the workflow directly. Formula
and agent names are implementation details; direct `gc sling` is reserved for
diagnostics and deliberate custom orchestration.

## Safety contract

Feature and bug work is strictly **local-only**. Agents work in isolated git
worktrees and may create local commits and branches, but never push, publish,
open or modify a PR, merge, or otherwise mutate a remote. PR review is read-only.
Only a human decides whether to extract or publish a result.
The operator extracts commits from the verified local branch when a separate,
explicit publication process is desired.

Feature and bug parents close only after review approves the exact immutable
artifact. Their final handoff includes the local **branch + exact HEAD SHA**;
verify that the branch still resolves to that SHA before using it.

## Presets and defaults

Quality is the default. `--fast` and `--solo` are explicit N=1 opt-downs.

| Workflow | Quality default | Explicit alternatives | Bound |
|---|---|---|---|
| Feature | implementation, then N=2 independent review, strict synthesis, revision or approval | `--fast` / `--solo`: N=1 review | maximum 3 revisions |
| Hard bug | N=2 diagnosis, bounded convergence, implementation, then N=2 review | `--fast` / `--solo`: N=1 diagnosis and review; `--report-only`: N=2 diagnosis without implementation | 3 convergence rounds per phase; maximum 3 revisions |
| PR/local review | N=2 independent review and strict synthesis | `--fast` / `--solo`: N=1; `--lanes`: select profiles | human merge checkpoint |

For bugs, `--n` controls diagnosis breadth and `--review-n` controls reviewers
of the implemented fix. They are independent. `--max-rounds` controls diagnosis
depth; `--max-review-iterations` controls artifact revisions. The authoritative
defaults live in `assets/workflow-policy.json` and are guarded by
`tests/workflow-contract.sh`.

Inspect any command's complete current flags with `--help`.

## Feature work

Ask `<rig>/lead` to implement the feature, or dispatch an existing rig bead:

```bash
gc dev-pack feature vllm-123
gc dev-pack feature vllm-123 --fast
gc dev-pack feature vllm-123 --review-n 2 \
  --review-lanes sonnet-xhigh,gpt56luna-xhigh
gc dev-pack feature vllm-123 --dry-run
```

The implementation lane commits coherently on an isolated local branch and
emits a `local-change.v1` artifact. The shared lifecycle reviews that exact SHA,
uses evidence settlement for disputed major findings, and either approves the
artifact or requests another bounded revision. The tracking bead does not close
on the implementer's self-report.

## Hard-bug work

Ask `<rig>/lead` to fix the bug, or dispatch its rig bead:

```bash
gc dev-pack bug vllm-456
gc dev-pack bug vllm-456 --fast
gc dev-pack bug vllm-456 --report-only
gc dev-pack bug vllm-456 --n 2 --review-n 1
gc dev-pack bug vllm-456 --dry-run
```

At N=2, independent diagnosis lanes converge on root cause and fix shape before
one writer implements. Agreement without evidence is not convergence: uncertain
load-bearing claims are sent back for verification. `--report-only` stops after
the durable diagnosis and performs no implementation.

Track the arc without invoking an agent:

```bash
gc dev-pack status vllm-456
```

## Review a PR or local change

Review accepts a PR number, `rig#PR`, local branch/ref, local-change artifact, or
implementation-output bead:

```bash
gc dev-pack review 53174 --rig vllm
gc dev-pack review vllm#53174 --fast
gc dev-pack review paude/vllm-123 --rig vllm --base origin/main
gc dev-pack review --artifact /path/to/local-change.json --rig vllm
gc dev-pack review <implementation-step-bead> --rig vllm
gc dev-pack review 53174 --rig vllm --lanes sonnet-xhigh,gpt56luna-xhigh
gc dev-pack review 53174 --rig vllm --dry-run
```

Local refs and artifacts are resolved inside the selected rig without a remote
fallback. Reviewers verify the exact base/head pair immediately before reading
the diff. N=2 runs independent profiles followed by strict synthesis; the most
conservative supported verdict wins.

Results arrive as readable mail and remain durable as structured verdict
evidence. Re-render a stored verdict without an LLM:

```bash
gc dev-pack summary 53174
gc dev-pack summary <verdict-bead>
```

### Materialize a reviewed PR

Create a durable human-owned checkout of the real PR:

```bash
gc dev-pack materialize 53174 --rig vllm
cd <city>/pr-worktrees/vllm/pr-53174
git diff origin/main...HEAD
```

Re-running is idempotent. Use `--force` to refresh a moved PR head, which
discards local changes in that materialized tree. Remove it when finished:

```bash
gc dev-pack materialize 53174 --rig vllm --remove
```

### Ask about a reviewed PR

`ask` has two modes with the same setup. Both materialize the actual PR into its
durable real worktree and load the original verdict and every earlier asynchronous Q&A.

| Durable async answer (question present) | Interactive PR chat (no question) |
|---|---|
| `gc dev-pack ask 51296 "does this handle empty batches?"` | `gc dev-pack ask 51296` |
| A one-shot agent answers from the real worktree, mails the answer, and durably chains it to the verdict. | Opens or reattaches one persistent coding-assistant session per PR in the real worktree. |
| Later async questions see every prior async round. | Requires a terminal. Detach with `Ctrl-b d`; rerun the same command to reattach with session history intact. |

Interactive history is session-only: it emits no result bead, closes nothing,
and mails nothing. Use the question-present form when the answer must be durable,
mailed, chained, or visible to a later async or newly opened interactive session.
Any verdict or follow-up bead in the chain may be used instead of the PR number.

## Monitor and retrieve results

```bash
gc bd show vllm-123                 # feature lifecycle, artifact, SHA, revision
gc dev-pack status vllm-456        # bug phase, round, status, implementer
gc bd show vllm-456                 # lifecycle and escalation evidence
gc mail inbox                      # verdict, final, and escalation notifications
gc dev-pack summary 53174          # stored review verdict
```

Extract and verify a final feature/bug handoff:

```bash
gc bd show vllm-123 --json | \
  jq -r '.[0].metadata["gc.lifecycle_json"] | fromjson | [.branch,.head_sha] | @tsv'
git -C rigs/vllm rev-parse <branch>    # must equal the recorded head_sha
```

The approved output is `change-lifecycle-final.v1`; the parent bead's
`gc.lifecycle_json` records the same branch, exact SHA, disposition, and revision.

## Recovery and escalation

| Outcome | Durable state | Operator action |
|---|---|---|
| Approved | parent closed at the exact reviewed artifact and SHA | inspect or extract locally; publish only by explicit human action |
| Request changes below cap | parent open; feedback and revision lineage recorded | normally none; the next bounded implementation/review iteration starts |
| Blocked | parent open; `gc.lifecycle_json.disposition=blocked` | fix the named local prerequisite, then authorize or rerun a bounded attempt |
| Routine convergence/revision exhaustion | parent open with `gc.lead_escalation_json`; `<rig>/lead` notified | lead re-scopes, changes bounded configuration, or authorizes another attempt |
| Human, cross-rig, resource, or city-policy decision | sanctioned `hold:mayor`; mayor notified | human or mayor resolves the named second-tier decision |

There is no `hold:lead`. Routine exhaustion does not apply `hold:mayor`, and
replaying the same completed escalation does not duplicate lead notification.
Approved-only closure and local-only guarantees remain active during recovery.

## Dynamic-check safety

Review can execute one narrowly scoped test only when the deterministic prescan
ceiling is `trusted`. A `limited` verdict may propose a command, but execution
requires an explicit human-approved `pr-review-dynamic` dispatch. Restricted and
blocked inputs run nothing. The gate rechecks posture, command shape, test path,
expected PR SHA, timeout, output cap, and worktree cleanliness; an agent cannot
widen it. Environment or network failures are reported as `could_not_verify`, not
as code failures.

Setup, trust-list, and prepared-test-environment details live in
[Bootstrapping a new rig](../docs/rig-bootstrap.md#enable-dev-pack-on-the-rig).
Architecture, worktree/reaper behavior, schemas, posture, and personas live in
[Dev-pack design](../docs/dev-pack-design.md).

## Copy-paste verification

Run this after changing workflow defaults, flags, formulas, docs, routing, or
operator contracts:

```bash
gc lint dev-pack
for test in dev-pack/tests/*.sh; do "$test"; done

gc --rig paude formula show change-lifecycle >/dev/null
gc --rig paude formula show change-lifecycle-solo >/dev/null
gc --rig vllm formula show change-lifecycle >/dev/null
gc --rig vllm formula show change-lifecycle-solo >/dev/null

gc dev-pack feature --help
gc dev-pack bug --help
gc dev-pack review --help
gc dev-pack ask --help
```

The known `gc.output_json` deprecation warnings from current v2 formulas are
unrelated to operator-contract changes. All commands and checks remain local;
none of this verification publishes or mutates a remote.

## Maintainer references

- [Current architecture and durable contracts](../docs/dev-pack-design.md)
- [Rig bootstrap and pack attachment](../docs/rig-bootstrap.md)
- [Day-2 city storage, backup, and recovery](../docs/day2-operations.md)
