# Bootstrapping a new rig

Scope: how to register a new upstream project as a gascity rig without
leaking beads/Dolt cruft into that project's tracked git state, and without
the trial-and-error dolt/database dance earlier rigs needed. Grounded against
gascity **v1.4.0** by a live reproduction (clone → bootstrap → teardown)
against a disposable rig, verified **2026-08-11**.

Storage/backup topics (how the Dolt store is backed up, restored, monitored)
live in `docs/day2-operations.md` — this doc is bootstrap-only.

---

## City root: asked, not hardcoded

The script resolves the city root via `gc rig list --json`'s `city_path`
field rather than hardcoding `/pvc/workspace` — this reuses gc's own
resolution (`--city` flag, `GC_CITY_PATH`, or walk-up-from-cwd), so the
script works from anywhere inside the city tree, not just its root, and
isn't tied to one machine's layout. Verified working when invoked from
`rigs/vllm` as well as from outside the city entirely (fails with a clear
error in the latter case, same as `git` outside a repo).

## The one command

```bash
assets/scripts/bootstrap-rig.sh <git-url> [prefix]
```

Example: `assets/scripts/bootstrap-rig.sh https://github.com/vllm-project/vllm.git vllm`

It clones the repo under `rigs/<prefix>`, initializes beads in stealth mode,
hardens the Dolt config against ever wiring a remote, adopts the rig into
gascity, and restores the rig's `.gitignore` to exactly what it was before —
verified to leave zero uncommitted changes in the adopted repo.

---

## Why it's structured this way

Earlier rigs (`vllm`, `paude`, `gascity`) were bootstrapped by hand and every
one of them needed a second round of manual recovery — `bd bootstrap`
refusing with "remote already has Dolt history", a `DROP DATABASE`, a
`bd init --reinit-local --discard-remote --destroy-token=...`, and an
`rm -rf .beads/embeddeddolt`. Reproducing it against a disposable rig pinned
down the actual causes:

- **gascity runs a single, shared Dolt sql-server for the whole city**, not
  one per rig — confirmed via `ps aux` (one `dolt sql-server` process) and
  every rig's `.beads/dolt-server.port` pointing at the same port. Each rig
  is just a differently-named database on that one server; the bulky data
  lives centrally under `.gc/runtime/packs/dolt/`, not inside any rig's
  working tree.
- **`bd init --server` on a brand-new rig fails immediately** — there's no
  running server yet at whatever host/port it guesses (`Dolt server
  unreachable at 127.0.0.1:0`) — and that failed attempt leaves `.beads/`
  half-built (an empty `.beads/dolt/`, sometimes a stray
  `.beads/embeddeddolt/` from a later embedded-mode fallback). *That*
  half-built state is what forced the whole recovery dance. Using the default
  **embedded** engine at init time (no `--server` flag) succeeds immediately
  and cleanly — `gc rig add --adopt` transparently rewires the rig into the
  shared server afterward regardless of which engine `bd init` used. This
  alone eliminated the recovery dance in reproduction.
- **`gc rig add --adopt` hard-requires `issue_prefix`/`issue-prefix` already
  present in `.beads/config.yaml`** — it refuses with `--adopt requires a
  valid issue_prefix` otherwise. `bd init -p <prefix>` reports the prefix but
  does not persist it to `config.yaml` by default, so the script still
  appends it explicitly. (This line in the old manual recipe was load-bearing,
  not redundant.)
- **`gc rig add --adopt` unconditionally writes into the rig's *tracked*
  `.gitignore`** — modifying one that exists, or creating one from scratch if
  none does. `.git/info/exclude` (written by `bd init --stealth`) already
  covers ignoring `.beads/`/`.dolt/`, so the script snapshots the rig's
  `.gitignore` before adoption and restores it byte-for-byte after —
  confirmed to leave a clean `git status`.
- **`gc rig add --adopt` unconditionally seeds `sync.remote` from the rig's
  own git origin URL** — confirmed by direct observation, not something
  anyone configures on purpose. This container can never push there; left
  unguarded, the periodic compactor/remote-patrol jobs retry-fail forever and
  the Dolt store bloats. This is exactly the incident fixed in commit
  `7b8d50b`. The script runs `bd config set dolt.local-only true` *before*
  `gc rig add`, so the periodic doctor patrol strips that remote within
  minutes instead of it sitting there live and unguarded.

## Enable dev-pack on the rig

After adopting the rig, attach the city-local pack through that rig's `includes`
entry. Preserve its existing prefix and default branch:

```toml
[[rigs]]
name = "example"
prefix = "example"
default_branch = "main"
includes = ["dev-pack"]
```

The bare include is relative to the city root and is read in place on reload.
Rig-scoped attachment is required: it gives managed agents the owning rig and
worktree context. Do not copy the hand-maintained list of agents or formulas into
operator docs; inspect the installed composition instead:

```bash
gc reload
gc lint dev-pack
gc doctor
gc --rig example agent list
gc --rig example formula list
gc dev-pack --help
```

Configure project-specific personas and review execution as rig patches, not as
generic pack content. Apply the relevant environment to every agent participating
in the corresponding lane; the live `city.toml` is the canonical complete map.
Typical values are:

```toml
[[rigs.patches]]
agent = "pr-reviewer-b-frontier-xhigh"
env = { GC_PERSONAS = "/city/tools/example/personas", GC_PR_TRUSTED_AUTHORS = "/city/tools/example/trusted-authors.txt", GC_PREPARE_TEST_ENV = "/city/tools/example/testenv.sh", UV_CACHE_DIR = "/city/.uv-cache" }
```

- `GC_PERSONAS` points to the rig-owned persona corpus. Set
  `GC_PERSONAS_REQUIRED=true` when missing project knowledge should fail closed.
- `GC_PR_TRUSTED_AUTHORS` is an optional tracked, one-login-per-line allowlist.
  It affects identity posture only; content-based restrictions still win.
- `GC_PREPARE_TEST_ENV` is an optional executable that lazily prepares a test
  environment and prints its Python interpreter. Without a runnable environment,
  dynamic checks return `could_not_verify` and the review still completes.
- `UV_CACHE_DIR` should be on the same filesystem as worktrees when the builder
  can benefit from reflinks. Test-environment builders remain project-owned; for
  example, vLLM uses `tools/vllm/vllm-testenv.sh` rather than pack code.
- `GC_PR_NOTIFY_TO` may override the default verdict-mail recipient or be empty
  when city orders provide notification. Stored verdict evidence is unaffected.

Because trusted posture permits narrowly bounded unattended test execution, keep
the author allowlist tracked and review its history. `dev-pack` still rechecks the
fresh posture, command shape, path, expected head SHA, timeout, and worktree state
at execution time. See [`docs/dev-pack-design.md`](dev-pack-design.md) for the
durable architecture and safety boundaries.

## Hard rule

Never run `bd dolt push`/`pull`/`remote add` in this container — see
`docs/day2-operations.md` and `rigs/gascity/AGENTS.md:523` for why. The one
thing not already documented there: `dolt.local-only: true` (set by the
bootstrap script, before adoption) is what makes the periodic doctor patrol
strip any remote automatically, rather than it sitting there live.

## Upstream fix candidates

This script's workarounds patch around real `gc rig add`/`bd init` rough
edges at the wrapper layer — worth fixing at the source if anyone picks up
`rigs/gascity` again, rather than assuming this wrapper is their permanent
home:

- `gc rig add --adopt` writes into the rig's tracked `.gitignore` at all,
  even when `.git/info/exclude` already covers the same patterns — it should
  prefer the untracked exclude file, or skip the write when redundant.
- `gc rig add --adopt` unconditionally seeds `sync.remote` from the rig's git
  origin — it should default to no remote (or take an explicit
  `--remote`/`--no-remote` flag) instead of inferring push intent from git
  origin. Pre-setting `dolt.local-only` here closes the window fast, but it's
  a timing mitigation, not a fix — there's still a brief gap between
  `gc rig add` running and the next doctor patrol cycle.
- `bd init -p <prefix>` reports the issue prefix but doesn't persist it to
  `config.yaml`, forcing the manual `printf` append in this script.

## Known gascity gotcha: `gc rig remove` rewrites `city.toml`

Not part of the bootstrap path itself (bootstrapping only ever calls
`gc rig add`), but worth knowing before you ever remove a rig: `gc rig
remove` fully re-serializes `city.toml` from its in-memory config struct —
canonicalizing inline tables into full `[section]` blocks and **dropping all
comments**. `gc rig add` alone (confirmed by reproduction) does a clean,
comment-preserving append and does not trigger this. If you ever need to
remove a rig from a `city.toml` with hand-written comments you care about,
`cp city.toml city.toml.bak` first so you can restore the comments by hand
afterward.

## Manual fallback

The script has a one-shot automatic recovery built in (`bd bootstrap
--dry-run` → `DROP DATABASE` → retry → the harsher `--reinit-local
--discard-remote` reinit as a last resort) for the rare case adoption still
fails. It only runs because the rig it's operating on was created moments
earlier in that same script invocation — there is no real data anywhere to
lose. **Never** reuse that destructive sequence against a rig that already
existed before the run (e.g. re-adopting a previously-removed rig with real
history) — handle that by hand, deliberately, checking what's actually in
its Dolt history first.

If you need to bootstrap a rig that already has a populated `.beads/`
directory (not a fresh clone), don't use this script — adopt it manually
with `gc rig add <path> --adopt --prefix <prefix>` and resolve any conflicts
by inspecting `bd bootstrap --dry-run`'s output first, rather than assuming
it's safe to drop anything.
