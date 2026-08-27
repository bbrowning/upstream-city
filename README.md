City configuration for a local-only software factory on top of
https://github.com/gastownhall/gascity.

Start with the rig lead in plain language:

- **“Implement this feature.”** The lead uses an isolated implementation branch,
  two independent reviews, strict synthesis, evidence-based settlement, and at most
  three review/revise iterations. The result is a local branch plus exact SHA; nothing
  is pushed or merged automatically.
- **“Fix this bug.”** The lead starts two independent diagnoses, bounded convergence,
  isolated implementation, then the same N=2 review/revise lifecycle. A routine cap is
  routed to the rig lead with evidence, not directly held for the mayor.
- **“Review PR N.”** The lead starts two independent read-only reviewers plus strict
  synthesis. A readable verdict arrives in mail; the human keeps the merge decision.

The explicit operator equivalents are `gc dev-pack feature <bead>`, `gc dev-pack bug
<bead>`, and `gc dev-pack review <PR> --rig <rig>`. Quality is the default. `--fast`
or `--solo` is an explicit N=1 opt-down; bug `--report-only` stops after diagnosis.
See [dev-pack/README.md](dev-pack/README.md) for lifecycle monitoring, recovery,
escalation, exact defaults, and copy-paste verification.

## Packs

- **[dev-pack](dev-pack/README.md)** — worktree-isolated quality-first workflows for
  every attached rig: **review** a PR (`gc dev-pack review <PR>`), **fix a hard bug**
  (`gc dev-pack bug <bead>`), and **implement a feature** (`gc dev-pack feature
  <bead>`). `gc dev-pack materialize <PR>` checks a change
  out into a durable, human-owned worktree to inspect or run yourself. See its
  README for [the flow at a glance](dev-pack/README.md#the-flow-at-a-glance-the-aha).
