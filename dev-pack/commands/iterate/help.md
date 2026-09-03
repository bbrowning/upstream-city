# Iterate approved local work from human feedback

```text
gc dev-pack iterate <bead> ["feedback"]
gc dev-pack iterate <bead> --file <path|->
```

`iterate` continues an already approved, closed dev-pack feature or hard bug. It
infers the intent and rig, resolves the exact approved artifact, records the human
feedback on a separate durable bead, reopens the work at a legal lifecycle
checkpoint, and launches the next local implementation and bounded review pass.
The bead may be either the original work bead or a review-result bead that records
an explicit `gc.change_lifecycle` link back to it.

Feedback may be supplied as one quoted argument, with `--file` (`-` reads stdin),
or on stdin. With no input on a terminal, `$VISUAL`, `$EDITOR`, or `vi` opens.

Options:

- `--rig NAME`: override rig inference.
- `--file PATH`: read multiline feedback from a file; `-` reads stdin.
- `--max-review-iterations N`: artifacts allowed in this new human-requested pass
  (default: 3). Artifact revision numbers remain globally monotonic.
- `--dry-run`: validate and show the transition without creating or changing work.

The command refuses open/non-approved work, stale or ambiguous predecessor
artifacts, empty feedback, and concurrent iterations. It never fetches, rebases,
pushes, creates a PR, or otherwise mutates a remote.
