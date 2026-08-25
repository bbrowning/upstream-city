# city.toml rationale

`city.toml` is kept **lean** — config values only, no inline comments and no
commented-out example blocks. This is deliberate: `gc rig remove`, `gc rig add`
(re-add path), and `gc agent add/remove` round-trip the whole file through a
struct TOML marshaller (`BurntSushi/toml`, no comment/AST support), so any
comment in `city.toml` is destroyed on the next such command. Keeping the file
comment-free means the native `gc` commands round-trip losslessly and we never
hand-edit to protect comments. The rationale that used to live inline lives
here instead. Update this file whenever you change the matching config.

Verify any edit resolves to the same merged config with:

    gc config show   # before and after; diff must be empty (or intended)

---

## `[providers.claude]` — custom model ids via `by_key`

gascity's builtin `claude` spec ships a **curated** model enum
(`internal/worker/builtin/profiles.go`). A requested model must match a choice
**value** exactly; on the launch path an unknown value is silently dropped (no
`--model` emitted) and claude falls back to its own default — that is why a bare
`claude-opus-4-6` once resolved as opus 4.8. It is a data gap, **not** a
capability limit: claude runs whatever `--model <id>` we pass.

`options_schema_merge = "by_key"` **appends** our `options_schema.choices` to
the builtin enum (works on v1.4.0), making each id a first-class, selectable,
**validated** model. Add one `choices` block per id you want to use; keep
`dev-pack/assets/valid-options.txt` in sync for the offline validator.

Currently added: `claude-opus-4-6` (Opus 4.6), `claude-opus-4-8` (Opus 4.8,
pinned id). `"sonnet"` is the builtin slug (= claude-sonnet-5) and needs no
entry.

## `[providers.codex]` — second vendor (OpenAI Codex)

The `codex` CLI is installed and ChatGPT-OAuth authenticated
(`CODEX_HOME`/`~/.codex`), so **no** `OPENAI_API_KEY`/`OPENAI_BASE_URL` is
needed. `builtin:codex` ships the model enum (gpt-5.6-sol, gpt-5.6-terra,
gpt-5.6-luna, gpt-5.5, gpt-5.3-codex, o3, o4-mini) and effort choices
(low|medium|high|xhigh — **no** `max`; its instructions file is `AGENTS.md`).
A review lane opts in by setting `provider = "codex"` + per-agent
`option_defaults`; the `--lanes` router is name-based / provider-agnostic, so no
`run.sh` change is needed.

## Rigs

- **paude** (prefix `paude`) and **vllm** (prefix `vllm`) are the only rigs.
- vllm carries `includes = ["dev-pack"]` — the in-city dev pack (PR review +
  two-opinion hard-bug + feature lanes).
- **gascity is deliberately NOT a rig** (removed 2026-08-25, bead wo-5pn6). The
  source stays on disk at `/pvc/workspace/rigs/gascity` purely as a read-only
  reference corpus, pinned to tag v1.4.0 = the installed binary's exact build
  commit a7297c5 (bead wo-4i5d). Registering it only bought permanent
  census-owner-liveness doctor noise (9 dangling `ga-*` refs belonging to
  upstream gascity's own bead store) plus three unused agents.

## vllm rig patches (per-agent model / effort / env)

All `[[rigs.patches]]` attach to the vllm rig. Common env sets referenced below:

- **TEST-VENV env**: `UV_CACHE_DIR` (btrfs, for uv reflinks) +
  `GC_PREPARE_TEST_ENV` (`tools/vllm/vllm-testenv.sh`, the lazily-built CPU-only
  vLLM venv, ~seconds warm) + `GC_PERSONAS` (`tools/vllm/personas/`, the vLLM
  domain-knowledge corpus: reviewer/lane loads `base.md` + any persona whose
  `Activates on:` header matches a changed path).
- **GC_PR_TRUSTED_AUTHORS** (`tools/vllm/trusted-authors.txt`): git-tracked PR
  author trust allowlist read by `pr-prescan.sh`. A listed login is elevated to
  collaborator-grade so a PR can reach `trusted` (auto-run a scoped test) even
  when GitHub reports the author as a mere CONTRIBUTOR. Identity-only — every
  file/pattern risk cap still applies.

| agent | model / effort | env | notes |
|---|---|---|---|
| `pr-triage` | **codex** gpt-5.6-sol / medium | trusted-authors only | Deterministic pre-scan sets the hard ceiling; medium effort handles the remaining posture judgment. |
| `pr-reviewer` | opus / **xhigh** | TEST-VENV + trusted-authors | The verdict I act on, so it gets the deeper pass. `effort=xhigh` is data-driven — see the effort note below. |
| `pr-reviewer-opus46-xhigh` | claude-opus-4-6 / xhigh | TEST-VENV + trusted-authors | Review lane PROFILE (see below). |
| `pr-reviewer-opus48-xhigh` | claude-opus-4-8 / xhigh | TEST-VENV + trusted-authors | Review lane PROFILE. |
| `pr-reviewer-sonnet-xhigh` | sonnet / xhigh | TEST-VENV + trusted-authors | Review lane PROFILE. |
| `pr-reviewer-gpt56sol-medium` | **codex** gpt-5.6-sol / medium | TEST-VENV + trusted-authors | Second-vendor profile; opt-in. |
| `pr-reviewer-gpt56sol-xhigh` | **codex** gpt-5.6-sol / xhigh | TEST-VENV + trusted-authors | Apples-to-apples vs Claude xhigh (xhigh is codex's top effort). |
| `pr-reviewer-gpt56luna-xhigh` | **codex** gpt-5.6-luna / xhigh | TEST-VENV + trusted-authors | Third-vendor opinion; opt-in. |
| `pr-arbiter` | **codex** gpt-5.6-sol / xhigh | personas + trusted-authors (no test-venv) | Settle-round arbiter (read-only, never executes changed code). |
| `pr-runner` | **codex** gpt-5.6-luna / high | TEST-VENV + trusted-authors | Human-approved dynamic-check lane. |
| `pr-follow-up` | **codex** gpt-5.6-sol / high | personas only | `gc dev-pack ask` read-only follow-up (no execution latitude in v1). |
| `pr-chat` | **codex** gpt-5.6-sol / high | TEST-VENV (no trusted-authors) | `gc dev-pack ask <PR>` with no question: live attached per-PR chat; MAY run tests on request. |
| `bug-worker-a` | default (unset) | TEST-VENV (no trusted-authors) | Hard-bug lane A. |
| `bug-worker-b` | default (unset) | TEST-VENV (no trusted-authors) | Hard-bug lane B. |

### Why `effort = xhigh` on the reviewer / reviewer profiles

Data-driven, not a preference: opus/high demonstrably **missed** the inkling
`THINK_END` regression in PR 47562 across two runs (beads f41i, 8pr1), while
opus/xhigh caught it as a **blocker** both times (wcq4 x2). **Effort — not
model — was the decisive factor.** See the per-lane breakdown in
`tools/vllm/arena/decisions.jsonl` and follow-up bead wo-au65.6.

### Review lane PROFILES

The `pr-reviewer-*` profiles are distinct single-slot reviewer agents that share
`pr-reviewer`'s **method** and differ ONLY in a pinned model/effort. Model/effort
come from each profile's `option_defaults` (baked into the launch command — the
reliable path), **not** from a per-run `opt_model`, which gascity does not apply
at launch (bead wo-au65.7). So to compare models per run you pick two profiles by
name (`gc dev-pack review --lanes A,B`, default `--n 2`); to add a combo, add a
profile agent (`dev-pack/agents/pr-reviewer-<name>/`) + a patch, then `gc reload`.

Quorum notify contract: these lanes must **not** mail the human — a quorum
notifies exactly ONCE from the SYNTHESIS step (`pr-reviewer`). `emit-verdict.sh`
enforces this by skipping notify for any bead stamped `gc.review_quorum_lane`
(which lane beads are), so no notify env is needed, and a profile used SOLO
(N=1, not quorum-stamped) still notifies once.

The codex profiles (`gpt56sol-medium`, `gpt56sol-xhigh`, `gpt56luna-xhigh`) are
**opt-in only** — not default lanes. Reach them with `--lanes gpt56sol-medium`
(solo) or `--lanes opus48-xhigh,gpt56sol-medium` (cross-vendor quorum). They
carry the same env as the Claude reviewers so codex loads the persona corpus and
can run the prepared CPU check.

### `pr-arbiter` (settle round)

The default arbiter for `gc dev-pack settle` (the verify-mandated tie-breaker
for a diverged review quorum). `--arbiter <profile>` can point it at any reviewer
profile for a genuine 3rd-vendor opinion. gpt-5.6-sol/xhigh: settling the crux is a deep
static trace (the manual PR 51937 arbiter run crossed ~8 files with exact line
numbers), and the arbiter is verify-mandated (correctness = the evidence chain,
not model identity), so the strongest reasoning model is the priority over
independence. No `GC_PREPARE_TEST_ENV` — the arbiter is read-only; a runtime
check is surfaced as `needs_dynamic` for the human's `pr-review-dynamic` lane.

### Hard-bug lanes (`bug-worker-a` / `bug-worker-b`)

Same prepared CPU test-venv wiring as the reviewer, so a lane that needs to run
vLLM reuses the warm uv cache + the blessed CPU-only recipe instead of a full
torch install. Per-worker model is currently **unset** (lane defaults govern);
set `option_defaults = { model = "..." }` on the patch to pin one. Valid claude
slugs: opus|sonnet|haiku|fable-5|opus-4-7|sonnet-5|sonnet-4-6. NB: rig-patch
`option_defaults` are **not** validated at `gc reload` — a typo is caught at
launch (logged, falls back to default), not at reload.

**Second-vendor Lane B (disabled example):** Lane B is provider-agnostic and the
formula no longer pins its model, so a real second vendor is a one-liner — add a
`[[rigs.patches]]` for `bug-worker-b` with `provider = "codex"` +
`option_defaults = { model = "gpt-5.6-sol" }` (gpt-5-codex is not a valid builtin
choice). Formulas/prompts stay unchanged.

## `[[named_session]] lead`

One lead per rig, from a single template. `scope = "rig"` + no `dir` fans this
out to `paude/lead` and `vllm/lead`. `mode = "on_demand"` reserves the identity
and materializes on dispatch; set `mode = "always"` for always-awake.
