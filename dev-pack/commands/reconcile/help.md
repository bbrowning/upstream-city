# Verify and record an upstream review

```text
gc dev-pack reconcile <source|external-ref|rig/source> [--as approve|request-changes]
                      [--dry-run] [--json]
```

Always refreshes GitHub read-only, verifies the current head equals the exact reviewed
SHA, and requires GitHub to report the chosen review state. Only then does it update
the source bead: requested changes become `wait:author`; approval closes the source.
`--as` records an explicit human disagreement with the automated recommendation.
When an exact-head human plan is active, reconciliation requires its condition to be
satisfied and its planned upstream action to match; a satisfied plan is valid explicit
human evidence even when an older automated verdict reviewed a different head.
The command is idempotent and never posts to GitHub or reads/changes mail.
