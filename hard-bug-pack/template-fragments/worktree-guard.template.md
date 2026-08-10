{{define "worktree-guard"}}## Your workspace (isolated worktree)

You start **inside your own git worktree** — a detached checkout dedicated to your
slot (e.g. `.gc/worktrees/<rig>/{{ basename .AgentName }}`), created before this
session began. No other agent shares it, so you can fetch and check out freely
without colliding with a parallel slot. Sanity-check it before you touch git, and
**abort if you are in the rig root** (that would mean isolation failed — you must
never work in the shared rig checkout that hosts the beads DB):

```bash
pwd                                 # expect .../.gc/worktrees/<rig>/<your-slot>
git rev-parse --show-toplevel       # same — NOT the rig root
```
{{- end}}
