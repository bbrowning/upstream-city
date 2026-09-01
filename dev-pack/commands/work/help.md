# Human attention desk (read-only)

```text
gc dev-pack work [options]
gc dev-pack work show <bead|external-ref> [options]
gc dev-pack work audit [options]

Options:
  --rig NAME             restrict to one rig; repeatable (use hq for city root)
  --citywide             aggregate HQ and all initialized rigs
  --actor IDENTITY       human owner/assignee identity; repeatable or comma-separated
  --group GROUP          needs-you, in-flight, waiting, stale-unclear, recently-finished
  --limit N              rows per group (default 5)
  --all                  do not bound groups
  --finished-within 14d  recent-finish window
  --json                 stable machine-readable output
  --verbose              include deeper workflow evidence
  --refresh              force bounded live read-only GitHub reconciliation
  --no-network           use local evidence/cache without any network call
```

With no scope flag, invocation inside a rig shows that rig. Invocation at the city
root aggregates HQ and configured initialized rigs. `--rig` and `--citywide` are
mutually exclusive.

Selection is explicit: a top-level bead/convoy is human-facing when its owner or
assignee matches `--actor`, `GC_ATTENTION_ACTORS`, `BEADS_ACTOR`, or the city Git
identity; or when it has `human-facing`, `attention`, `attention=true`, or
`maintainer`. `attention=false` and `human-facing=false` opt out. Internal workflow,
retry, message, gate, order, and agent beads are evidence rather than rows. A marked
internal may be inspected with `--verbose`.

The groups combine canonical bead/workflow/local evidence with freshness-labeled,
read-only GitHub PR observation. Exact current and reviewed heads are compared. A
new author head, an externally closed/merged PR with an open source bead, or legacy
review evidence missing its exact reviewed SHA is NEEDS YOU. Only closure of the
human bead is RECENTLY FINISHED. Every ledger invocation uses bd's `--readonly`
enforcement; GitHub calls are read-only and mail is never acknowledged or changed.
The ordinary list/show path never reads or acknowledges mail; only explicit `audit`
scans message beads under the same read-only ledger enforcement.

`show` returns the source bead plus durable output/lifecycle and workflow evidence;
each row has an exact `work show` pointer and any applicable `summary`/`status`
pointer. For a current exact-head PR verdict, it leads with the GitHub action, PR
URL, reviewed SHA, feedback-render command, and separate post-submission reconcile
command. It also prints `gc dev-pack summary <result-bead> --full` for the complete
stored review. `gc dev-pack feedback <rig/source>` is the cleaned, GitHub-ready,
read-only derivative rather than a replacement for that full review;
`gc dev-pack reconcile <rig/source>` mutates only the source bead after a forced live
GitHub refresh proves that exact action on that exact head. Normal operation reuses a fresh disposable cache and refreshes stale
entries. `--refresh` forces live observation; `--no-network` reports cached
freshness or unavailability honestly. By default observations stay fresh for 30
minutes (`DEV_PACK_WORK_CACHE_TTL` overrides this in seconds), and the cache is
capped at 128 entries.

An explicit `gc dev-pack plan <rig/source> --wait-for ... --then ...` is projected
ahead of automated verdict guidance. It remembers only a human-authored next-step
outcome, pinned to a live exact head; interactive `ask` sessions remain ephemeral and
are never harvested. `work show` displays the plan condition, current CI/head state,
context note, and exact clear/replace commands.

`audit` is the read-only shadow gate: it correlates routine-review refs from the
human mailbox and durable (including normally hidden) outputs to exactly one
human-facing source and its attention row. It reports nonzero status while any
omission or duplicate remains and never marks mail read.

Continuous `--watch` remains explicitly deferred; bounded refresh is operator-
initiated or may be performed by an optional rate-limited cache-prewarm order.
