{{define "persona-load"}}Use the **{{.}} lifecycle lens**. Domain facts stay single-sourced in `$GC_PERSONAS`; the lens changes when and how you apply them, never which copy you read.

Build a path list before loading anything beyond `base.md`:
{{- if eq . "diagnosis"}}
- use subsystems named by the symptom, log, trace, and failing path, including upstream callers; do not guess from the file you might eventually edit.
{{- else if eq . "design"}}
- use the paths/subsystems the proposed design is expected to affect. Do this before choosing the design or editing.
{{- else if eq . "implementation"}}
- use both planned paths and the current `git diff --name-only <base>...HEAD`; reload after the edit if the changed-path set expands.
{{- else if eq . "change-review"}}
- use the immutable artifact or PR's exact `git diff --name-only <base>...<head>` changed paths. Local changes and PRs deliberately share this lens.
{{- else if eq . "settle"}}
- use changed paths implicated by the disputed keystone, plus the surrounding subsystem paths needed to verify it.
{{- end}}

Select deterministically; do not read unrelated persona bodies merely because they exist:

```bash
persona_status=$(bash "$GC_CITY_PATH/dev-pack/assets/scripts/persona-preflight.sh") || {
  printf '%s\n' "persona preflight failed: ${GC_PERSONAS:-unset}" >&2
  # Required corpora are a configuration contract: stop and emit a hard failure
  # with failure_reason=persona-corpus-unavailable instead of silently degrading.
  exit 2
}
printf 'persona preflight: %s\n' "$persona_status"
persona_selection=$(bash "$GC_CITY_PATH/dev-pack/assets/scripts/select-personas.sh" \
  --corpus "$GC_PERSONAS" --lens {{.}} \
  --path <relevant-path> [--path <another-path> ...]) || {
  printf '%s\n' "persona selection failed without a clean read-only result" >&2
  exit 2
}
mapfile -t persona_files <<<"$persona_selection"
printf 'loading persona: %s\n' "${persona_files[@]}"
cat "${persona_files[@]}"
```

The selector always returns `base.md`, then only domain personas whose `**Activates on:**` prefixes match. Multiple domain personas may match; zero is valid. If the corpus is optional, preflight records the intentional first-principles fallback. If `GC_PERSONAS_REQUIRED=true`, absence is a hard, actionable configuration failure.
The wrapper runs `uv --no-project` with a city-owned cache under
`.gc/runtime`; it never consults or creates a target-worktree `.venv`, lockfile, or cache,
and fails if persona selection changes the worktree status baseline.

Apply domain facts through this lane's method:
{{- if eq . "diagnosis"}}
- use reflexes to locate and ground the mechanism; skip diff-only process advice.
{{- else if eq . "design"}}
- use reflexes to compare designs, identify cross-subsystem risks, and specify regression coverage before editing.
{{- else if eq . "implementation"}}
- use reflexes as edit constraints and test obligations; they do not replace the accepted design or diagnosis.
{{- else if eq . "change-review"}}
- use reflexes as the first skeptical checks against the exact changed paths, then perform the normal correctness review.
{{- else if eq . "settle"}}
- use reflexes as domain hypotheses while independently verifying the disputed keystone; never settle by persona authority or vote.
{{- end}}

In the lane's structured output append `persona_traces:[{lens:"{{.}}",loaded:[<filenames>],material_influences:[{persona,reflex,decision,evidence}]}]`. `material_influences` contains only reflexes that changed a design, edit, test, finding, or settlement; use `[]` when none did. This trace is operational provenance, not human-facing review prose.
{{- end}}
