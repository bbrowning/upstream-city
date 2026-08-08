# Knowledge router — changed path → domain file

The reviewer reads this **at review time**. Take the changed-file list from the
pre-scan (`facts.changed_files`, or `git diff --name-only <base>...<head>`), match
each path against the rules below, and load ONLY the matching `<domain>.md` (plus
`general.md`, always). Load only what the PR touches — bounded context, one flywheel
per domain, so no unrelated list ever accumulates.

**This is the reviewer's source of truth for the domain→path mapping** (the seed miner
`//tools/vllm/mine-review-comments.sh` encodes the same path patterns independently for
discovery/filtering — keep the two in sync when you add or rename a domain). The pack's
pre-scan (`pr-prescan.sh`) is deliberately project-agnostic and does NOT know these
domains — it only reports the changed files + generic security classes. To teach the
reviewer a new domain, add a row here + a `<domain>.md` beside it. (No `gc reload`
needed for content — the reviewer reads these files fresh each run; edits from
`learn`/seed are live on the next review.)

Knowledge files live in `$GC_PR_KNOWLEDGE` (absolute path injected via the rig
`[[rigs.patches]]` env; do NOT rely on `{{.ConfigDir}}` — it renders empty in prompts).

| Load domain file     | when a changed path contains | Notes / priority |
|----------------------|------------------------------|------------------|
| `parsers.md`         | `/tool_parsers/`, `/reasoning/`, `/parser/`, `/tool_use/` | Tool-call + reasoning + shared Parser Engine (unified 2026-08-07). High-signal; a real finding here is usually `major`/`blocker`. |
| `openai_frontend.md` | `/entrypoints/openai/`       | Schema/protocol fidelity; treat spec drift as `major`. A change under `entrypoints/openai/parser/` also matches `parsers.md` (both load). |
| `general.md`         | **always**                   | Cross-cutting invariants; layer domain files on top. |

A changed path matching no domain row contributes only `general.md` (review from
first principles). If the human then corrects you, that lesson's durable home is
`gc pr-review-pack learn --area <domain>` (create the domain — a new row + file — if
it's genuinely new).
