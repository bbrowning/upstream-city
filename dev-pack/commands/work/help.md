# Human attention desk (read-only)

```text
gc dev-pack work [options]
gc dev-pack work show <bead|external-ref> [options]

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

The groups are derived only from canonical status, dependency/hold labels, active
children, durable `gc.output_json` / `gc.lifecycle_json`, and current local branch
state. A finished automation result on an open human bead is NEEDS YOU; only closure
of the human bead is RECENTLY FINISHED. Every ledger invocation uses bd's
`--readonly` enforcement and the command never reads or acknowledges mail.

`show` returns the source bead plus durable output/lifecycle and workflow evidence;
its `authoritative_output` points to `gc dev-pack summary`, `status`, or `gc bd show`
as appropriate. `--watch` is explicitly deferred from this offline MVP until Gas
City exposes an event-driven, read-only multi-store refresh contract. Rerun the
command to refresh; polling is intentionally not embedded here.
