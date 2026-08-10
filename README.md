City configuration for my personal software factory experiments on top of https://github.com/gastownhall/gascity

## Packs

- **[dev-pack](dev-pack/README.md)** — one engineering-workflow pack, three
  worktree-isolated lanes for the `vllm` rig: **review** a PR
  (`gc dev-pack review <PR>` → posture-gated verdict pushed to your mail),
  **fix a hard bug** with two opinions until convergence
  (`gc dev-pack bug <bead>`), and **implement a feature**
  (`gc dev-pack feature <bead>`). `gc dev-pack materialize <PR>` checks a change
  out into a durable, human-owned worktree to inspect or run yourself. See its
  README for [the flow at a glance](dev-pack/README.md#the-flow-at-a-glance-the-aha).
