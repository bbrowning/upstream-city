{{define "trigger-claim"}}## Trigger-bound startup (must be first)

Before `gc prime`, mail, ready-list inspection, or any bead mutation, validate and
claim the one launch-time assignment chosen by the controller:

```bash
export DEV_PACK_STEP_BEAD="$(bash "$GC_CITY_PATH/dev-pack/assets/scripts/claim-trigger.sh")"
```

The helper resolves `GC_TRIGGER_BEAD_ID` exactly, verifies this agent is the route,
then claims only that id while replacing `gc.session_name` and `gc.work_dir` in the
same mutation, and verifies ownership/provenance afterward. If it fails, stop without
claiming or writing another bead. Use
`$DEV_PACK_STEP_BEAD` everywhere the prompt says “your step bead”; never discover or
claim a substitute from `gc bd ready`, fuzzy search, or another session's context.
{{- end}}
