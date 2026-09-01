# Remember an exact-head human plan

```text
gc dev-pack plan <source|external-ref|rig/source> --wait-for CONDITION --then ACTION [--note TEXT]
gc dev-pack plan <source|external-ref|rig/source> --cancel

CONDITION  ci | author
ACTION     approve | request-changes | re-review | inspect
```

Valid combinations:

- `ci` → `approve`, `request-changes`, `re-review`, or `inspect`
- `author` → `re-review` or `inspect`

`ci` waits while checks are pending, wakes for the chosen action when checks pass,
and wakes for inspection when checks fail. `author` wakes when GitHub reports a new
head. Creation always refreshes GitHub read-only and pins its exact current SHA.
`--note` stores optional human context. `--cancel` cancels the active plan; it does
not record an upstream outcome, and retained exact-head evidence remains available
for reconciliation. If GitHub already shows the planned review or merge, cancellation
refuses and prints the exact `reconcile` command. Invalid values and combinations fail
with the valid choices.

This is an explicit source-bead mutation. It never reads or harvests an interactive
`ask` transcript, never touches mail, and never posts to or otherwise mutates GitHub.

Example:

```bash
gc dev-pack plan vllm/vllm-e5m8.2 --wait-for ci --then approve \
  --note "Coverage expansion is optional; comment posted on GitHub."
```
