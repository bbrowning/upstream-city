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
`--model` emitted) and claude falls back to its own default. It is a data gap,
**not** a capability limit: claude runs whatever `--model <id>` we pass.

`options_schema_merge = "by_key"` **appends** our `options_schema.choices` to
the builtin enum (works on v1.4.0), making each id a first-class, selectable,
**validated** model. Add one `choices` block per id you want to use; keep
`dev-pack/assets/valid-options.txt` in sync for the offline validator.

Currently added: `claude-opus-5` (Opus 5, pinned id). `"sonnet"` is the
builtin slug (= claude-sonnet-5) and needs no entry.

## `[providers.codex]` — primary workflow provider

The `codex` CLI is installed and ChatGPT-OAuth authenticated
(`CODEX_HOME`/`~/.codex`), so **no** `OPENAI_API_KEY`/`OPENAI_BASE_URL` is
needed. `builtin:codex` ships the model enum (gpt-5.6-sol, gpt-5.6-terra,
gpt-5.6-luna, gpt-5.5, gpt-5.3-codex, o3, o4-mini) and effort choices
(low|medium|high|xhigh — **no** `max`; its instructions file is `AGENTS.md`).
Fixed orchestration, semantic A/solo roles, and every efficient role use Codex.
Claude is reserved for semantic frontier B bug/review leaves as a backup-capacity
provider. Routing remains identity-based and provider-neutral.

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

## Execution binding layout

Each attached rig has the same 32 intentional patches: seven fixed
orchestration/support roles plus 25 semantic execution leaves. There are no
generic compatibility leaves and no concrete model-expert agents. Direct formulas
use the same semantic frontier defaults as pack commands.

The supported semantic profiles are exactly:

| profile | feature / solo / lane A | lane B | effort |
|---|---|---|---|
| `frontier-xhigh` | codex `gpt-5.6-sol` | claude `claude-opus-5` | xhigh |
| `frontier-high` | codex `gpt-5.6-sol` | claude `claude-opus-5` | high |
| `frontier-medium` | codex `gpt-5.6-sol` | claude `claude-opus-5` | medium |
| `efficient-xhigh` | codex `gpt-5.6-luna` | codex `gpt-5.6-luna` | xhigh |
| `efficient-medium` | codex `gpt-5.6-luna` | codex `gpt-5.6-luna` | medium |

Feature and solo review use the lane-A binding. Bug and quorum review retain
distinct A/B identities even where the efficient profiles intentionally use the
same concrete model. No fifth or economy profile is defined; another public tier
requires a real model binding and operational use case.

Explicit target flags can select any installed semantic/custom target. The pack
does not maintain a second namespace of concrete model-pinned reviewers.

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
| `pr-review-synthesizer` | **codex** gpt-5.6-sol / medium | TEST-VENV + trusted-authors | Quorum synthesis and lifecycle decisions; never a review leaf default. |
| `pr-arbiter` | **codex** gpt-5.6-sol / xhigh | personas + trusted-authors (no test-venv) | Settle-round arbiter (read-only, never executes changed code). |
| `pr-runner` | **codex** gpt-5.6-luna / high | TEST-VENV + trusted-authors | Human-approved dynamic-check lane. |
| `pr-follow-up` | **codex** gpt-5.6-sol / high | personas only | `gc dev-pack ask` read-only follow-up (no execution latitude in v1). |
| `pr-chat` | **codex** gpt-5.6-sol / high | TEST-VENV (no trusted-authors) | `gc dev-pack ask <PR>` with no question: live attached per-PR chat; MAY run tests on request. |
| `bug-coordinator` | **codex** gpt-5.6-sol / high | none | Fixed convergence coordinator; preserves semantic targets across re-slings. |

The 25 semantic leaves use the exact profile matrix above. vLLM bug/review
leaves receive TEST-VENV/persona/trust environment as appropriate; Paude receives
its own persona paths. Model/provider/effort are otherwise identical across rigs.

### Why `effort = xhigh` on the reviewer / reviewer profiles

Data-driven, not a preference: opus/high demonstrably **missed** the inkling
`THINK_END` regression in PR 47562 across two runs (beads f41i, 8pr1), while
opus/xhigh caught it as a **blocker** both times (wcq4 x2). **Effort — not
model — was the decisive factor.** See the per-lane breakdown in
`.gc/runtime/arena/decisions.jsonl` and follow-up bead wo-au65.6.

### Semantic review lanes

The `pr-reviewer-{a,b}-frontier-{xhigh,high,medium}` and
`pr-reviewer-{a,b}-efficient-{xhigh,medium}` agents are distinct
single-slot semantic roles that share the synthesizer's review method. Their exact
provider/model/effort comes from each rig patch, not formula metadata. Direct formulas
default to frontier-high A/B, and `--execution` selects another complete role set.
`--lanes` is reserved for deliberate installed semantic/custom target overrides.

Quorum notify contract: these lanes must **not** mail the human — a quorum
notifies exactly ONCE from the SYNTHESIS step (`pr-review-synthesizer`). `emit-verdict.sh`
enforces this by skipping notify for any bead stamped `gc.review_quorum_lane`
(which lane beads are), so no notify env is needed, and a profile used SOLO
(N=1, not quorum-stamped) still notifies once.

The default solo lane is semantic A frontier-high. The default quorum is semantic
A/B frontier-high. Claude appears only in frontier B; efficient A/B both use Codex
Luna while retaining distinct identities and worktrees.

### `pr-arbiter` (settle round)

The default arbiter for `gc dev-pack settle` (the verify-mandated tie-breaker
for a diverged review quorum). `--arbiter <target>` can point at an installed
semantic/custom reviewer when a separate view is useful. gpt-5.6-sol/xhigh is used
because settling the crux is a deep
static trace (the manual PR 51937 arbiter run crossed ~8 files with exact line
numbers), and the arbiter is verify-mandated (correctness = the evidence chain,
not model identity), so the strongest reasoning model is the priority over
independence. No `GC_PREPARE_TEST_ENV` — the arbiter is read-only; a runtime
check is surfaced as `needs_dynamic` for the human's `pr-review-dynamic` lane.

### Semantic hard-bug lanes

Bug A/B use the same four semantic profiles and exact matrix as review A/B. A is
the primary Codex role. Frontier B uses Claude Opus 5 as backup capacity; efficient
B uses Codex Luna. Every leaf has an explicit patch and its own worktree. Generic
`bug-worker-a` / `bug-worker-b` launch identities do not exist.

## `[[named_session]] lead`

One lead per rig, from a single template. `scope = "rig"` + no `dir` fans this
out to `paude/lead` and `vllm/lead`. `mode = "on_demand"` reserves the identity
and materializes on dispatch; set `mode = "always"` for always-awake.
