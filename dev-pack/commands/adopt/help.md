Continue an exact upstream PR head on a durable local branch, merge or rebase the
exact freshly fetched target-branch tip, add scoped fixes/tests, and run the bounded immutable
review/revise lifecycle. This command never pushes or creates/modifies a PR.

Usage:
  gc dev-pack adopt <PR-number | rig#PR | PR-linked-bead> [options]

Options:
  --rig NAME                 owning rig (default: vllm; inferred from a bead)
  --strategy merge|rebase    continuation method (default: merge)
  --task TEXT                scoped fixes/tests beyond conflict resolution
  --outcome OUTCOME          undecided (default), update-original,
                             request-author-apply, or supersede
  --quality                  N=2 bounded review/revise lifecycle (default)
  --fast, --solo             N=1 bounded lifecycle
  --execution PROFILE        semantic implementation/review capacity
  --max-review-iterations N  artifact revision cap (default: 3)
  --dry-run                  resolve local command shape without GitHub or mutation

The input PR and its human disposition bead remain distinct from the internal
adoption tracking bead. Approval closes only the internal bead. The final artifact
records original/target/result SHAs, authorship, tests, and the recommended human
publication outcome. Updating a contributor branch, asking the author to apply
commits, and opening a superseding PR are separate human checkpoints.
