#!/usr/bin/env bash
# Clone an upstream repo and register it as a gascity rig, without polluting
# the upstream repo's tracked git state or leaving its Dolt store misconfigured.
#
# Usage: assets/scripts/bootstrap-rig.sh <git-url> [prefix]
#
# See docs/rig-bootstrap.md for why each step below exists — it's grounded in
# a live reproduction against a disposable rig, not guesswork.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (used to parse 'gc rig list --json')" >&2
  exit 1
fi

# Ask gascity where the city root is instead of hardcoding it — this respects
# gc's own resolution (--city flag, GC_CITY_PATH, or walk-up-from-cwd), so the
# script works from anywhere inside the city tree and isn't tied to one path.
CITY_ROOT="$(gc rig list --json 2>/dev/null | jq -r '.city_path // empty')" || true
if [ -z "$CITY_ROOT" ]; then
  echo "error: could not resolve city root via 'gc rig list --json' — run this from inside a gascity city" >&2
  exit 1
fi

REPO_URL="${1:?usage: bootstrap-rig.sh <git-url> [prefix]}"
PREFIX="${2:-$(basename "$REPO_URL" .git | tr '[:upper:]' '[:lower:]')}"
RIG_DIR="$CITY_ROOT/rigs/$PREFIX"

if [ -e "$RIG_DIR" ]; then
  echo "error: $RIG_DIR already exists" >&2
  exit 1
fi

in_rig()  { ( cd "$RIG_DIR" && "$@" ); }
in_city() { ( cd "$CITY_ROOT" && "$@" ); }

echo "==> Cloning $REPO_URL as rig '$PREFIX'"
git clone "$REPO_URL" "$RIG_DIR"

# Snapshot .gitignore's exact pre-adopt state. `gc rig add` unconditionally
# writes its own entries into the rig's TRACKED .gitignore — modifying one
# that exists, or creating one from scratch if none does. .git/info/exclude
# (written below by --stealth) already covers ignoring .beads/.dolt, so the
# tracked file is restored exactly afterward. (This and the sync.remote
# seeding below are gascity/bd rough edges this script works around — see
# docs/rig-bootstrap.md's "Upstream fix candidates" for the case to fix them
# at the source instead.)
gitignore_snapshot=""
if [ -f "$RIG_DIR/.gitignore" ]; then
  gitignore_snapshot="$(mktemp)"
  cp "$RIG_DIR/.gitignore" "$gitignore_snapshot"
fi

# Embedded engine, NOT --server: a brand-new rig has no dolt sql-server to
# connect to yet. `bd init --server` on a fresh rig fails immediately
# ("Dolt server unreachable at 127.0.0.1:0") and leaves .beads/ half-built —
# that half-built state is what used to force a whole DROP DATABASE /
# --reinit-local --discard-remote / rm -rf .beads/embeddeddolt recovery dance.
# `gc rig add --adopt` below transparently rewires the rig into the city's
# one shared dolt sql-server regardless of which engine bd init used, so
# --server at this step buys nothing and only adds a failure mode.
echo "==> bd init (embedded, stealth)"
in_rig bd init --non-interactive --stealth -p "$PREFIX"

# gc installs provider hooks into the rig during adoption when the city's
# workspace.install_agent_hooks includes that provider. These are local city
# integration files, not upstream project content, so keep them out of the
# tracked checkout just like beads' own stealth-mode files.
printf '\n# Gas City provider hooks (rig-local)\n.codex/\n' >> "$RIG_DIR/.git/info/exclude"

# gc rig add --adopt hard-requires issue_prefix/issue-prefix already present
# in .beads/config.yaml (fails: "--adopt requires a valid issue_prefix");
# bare `bd init -p` reports the prefix but does not persist it to config.yaml.
printf '\nissue-prefix: "%s"\n' "$PREFIX" >> "$RIG_DIR/.beads/config.yaml"

# Hard rail: `gc rig add --adopt` unconditionally seeds sync.remote from this
# rig's own git origin URL (confirmed by direct observation — not something
# anyone configures on purpose). This container can never push there; left
# unguarded, the periodic compactor/remote-patrol jobs retry-fail forever and
# the store bloats (this is exactly the incident fixed in commit 7b8d50b).
# Setting local-only BEFORE adoption means the doctor patrol strips that
# remote within minutes instead of leaving it live indefinitely.
in_rig bd config set dolt.local-only true

city_toml_before="$(mktemp)"
cp "$CITY_ROOT/city.toml" "$city_toml_before"

adopt_rig() {
  in_city gc rig add "rigs/$PREFIX" --adopt --prefix "$PREFIX"
}

# One-shot recovery ladder, safe to run destructively ONLY because this exact
# script invocation created rigs/$PREFIX and its database moments ago — there
# is no real data anywhere to lose. Never reuse these against a rig that
# already existed before this run (e.g. re-adopting a previously-removed
# rig) — do that by hand instead.
recover_drop_database() {
  in_rig bd bootstrap --dry-run || true
  in_rig bd sql "DROP DATABASE IF EXISTS $PREFIX" || true
  in_rig bd bootstrap --non-interactive || true
}

recover_reinit_local() {
  in_rig bd init --reinit-local --discard-remote --destroy-token="DESTROY-$PREFIX" \
    --non-interactive --server -p "$PREFIX" --database "$PREFIX" \
    --skip-hooks --skip-agents --stealth
}

echo "==> gc rig add --adopt"
if ! adopt_rig; then
  echo "==> adopt failed; running one-shot recovery (safe: this rig was just created)" >&2
  recover_drop_database
  if ! adopt_rig; then
    recover_reinit_local
    adopt_rig
  fi
fi

# Adoption currently writes the git origin into sync.remote even when
# dolt.local-only was already set. Clear the value immediately instead of
# leaving a window for remote patrol to clean up later. `bd config unset`
# does not reliably remove this nested key in bd 1.1.0, while an empty value
# is treated as unset.
in_rig bd config set sync.remote ""

# Register and seed the same local filesystem backup used by the city's
# recurring mol-dog-backup order. A newly adopted database is not discovered
# by that order until it has a DOLT_BACKUP entry of its own.
dolt_status="$(in_city gc dolt status)"
dolt_host="$(printf '%s\n' "$dolt_status" | sed -n 's/.*(managed, \([^:][^:]*\):[0-9][0-9]*).*/\1/p')"
dolt_port="$(printf '%s\n' "$dolt_status" | sed -n 's/.*(managed, [^:][^:]*:\([0-9][0-9]*\)).*/\1/p')"
dolt_database="$(jq -r '.dolt_database // empty' "$RIG_DIR/.beads/metadata.json")"
if [ -z "$dolt_host" ] || [ -z "$dolt_port" ] || [ -z "$dolt_database" ]; then
  echo "error: could not resolve Dolt endpoint/database for local backup" >&2
  exit 1
fi
backup_dir="$CITY_ROOT/.dolt-backup/$dolt_database"
backup_name="$dolt_database-backup"
DOLT_CLI_PASSWORD='' dolt --host "$dolt_host" --port "$dolt_port" \
  --user root --no-tls sql -q \
  "USE \`$dolt_database\`; CALL DOLT_BACKUP('add', '$backup_name', 'file://$backup_dir'); CALL DOLT_BACKUP('sync', '$backup_name');"

# Restore .gitignore to its exact pre-adopt state.
if [ -n "$gitignore_snapshot" ]; then
  cp "$gitignore_snapshot" "$RIG_DIR/.gitignore"
  rm -f "$gitignore_snapshot"
else
  rm -f "$RIG_DIR/.gitignore"
fi

# Vestigial: leftover from the embedded-engine init phase, superseded once
# adoption wires the rig into the shared server. Safe to remove.
rm -rf "$RIG_DIR/.beads/embeddeddolt"

status_out="$(in_rig git status --porcelain)"
if [ -n "$status_out" ]; then
  echo "WARNING: rigs/$PREFIX has unexpected uncommitted changes after bootstrap:" >&2
  echo "$status_out" >&2
  exit 1
fi

city_toml_diff="$(diff "$city_toml_before" "$CITY_ROOT/city.toml" || true)"
if [ -n "$city_toml_diff" ]; then
  echo "NOTE: gc rig add reformatted city.toml (it always does on any write —" >&2
  echo "comments and TOML formatting are not preserved). Diff:" >&2
  echo "$city_toml_diff" >&2
  echo "Review the diff above and restore any hand-written comments by hand." >&2
fi
rm -f "$city_toml_before"

echo "==> Rig '$PREFIX' bootstrapped cleanly at rigs/$PREFIX"
