{{define "persona-load"}}Always read `$GC_PERSONAS/base.md` (cross-cutting reflexes; always applies). Then, for each other persona in `$GC_PERSONAS/`, read its `**Activates on:**` header and load it only if a path prefix it lists matches {{if eq . "review"}}one of the changed paths (from the pre-scan's `facts.changed_files`, or `git diff --name-only <base>...<head>`){{else}}a subsystem this bug lives in — read from the symptom / log / trace (e.g. `vllm/v1/structured_output/`, `vllm/parser/`, `vllm/entrypoints/openai/`), not just the one file you might end up editing{{end}}. More than one persona can match — load them all; load none the {{if eq . "review"}}change doesn't touch{{else}}trace doesn't reach{{end}}.

```bash
cat "$GC_PERSONAS/base.md"          # always applies
# then each persona whose "Activates on:" prefixes match a {{if eq . "review"}}changed path{{else}}subsystem in the trace{{end}}:
cat "$GC_PERSONAS/<persona>.md"
```

{{if eq . "review"}}Review through that lens: the persona reflexes come first — they encode what actually bites in this area.{{else}}These personas are **shared with the PR reviewer and written in review voice**: take the domain reflexes and gotchas (what's true about this area, what silently breaks), and skip the review-*process* items that presuppose a diff (public-API back-compat, test-coverage-of-a-change, competing in-flight PRs) — they don't apply to a diagnosis.{{end}} (`$GC_PERSONAS` is injected for this rig; if it is unset, note that in your {{if eq . "review"}}verdict{{else}}output{{end}} and reason from `base` reflexes + first principles.)
{{- end}}
