# Render upstream review feedback (read-only)

```text
gc dev-pack feedback <source|external-ref|rig/source> [--action approve|request-changes]
                     [--refresh|--no-network] [--json]
```

Selects the newest authoritative finished review linked to the human-facing source,
including a later settlement, and prints clean text ready to paste into GitHub. The
default action follows the automated verdict; `--action` makes disagreement explicit.
It is a deterministic author-facing derivative of the full stored review, not a
replacement for it; use the `summary <result-bead> --full` command shown by `work show`
for all internal evidence and review detail.
This command never updates beads or mail and never posts to GitHub. Its default path
reuses the ordinary 30-minute cache and refreshes only when stale; use `--refresh` for
a forced live read-only head check or `--no-network` to prohibit a refresh.
