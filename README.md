City configuration for my personal software factory experiments on top of https://github.com/gastownhall/gascity

## Packs

- **[pr-review-pack](pr-review-pack/README.md)** — parallel, worktree-isolated
  read-only PR reviewers + one feature-dev write lane for the `vllm` rig. Ask
  `vllm/lead` to review a PR; the verdict is pushed to your mail, and
  `gc pr-review-pack materialize <PR>` checks the change out into a durable,
  human-owned worktree when you want to inspect or run it yourself. See its
  README for [the flow at a glance](pr-review-pack/README.md#the-flow-at-a-glance-the-aha).
