#!/usr/bin/env bash
# run-scoped-check.sh — the deterministic EXEC GATE for Phase-2 dynamic checks.
#
# This is the ONE place code from a PR is allowed to execute, and the gate is
# deterministic (no LLM): it re-derives the injection-proof ceiling with
# pr-prescan.sh and refuses to run anything the ceiling does not permit, checks
# the command is in a safe prepared-env form, resolves a typed prepared runtime,
# runs the command with a timeout + output cap, and reports a structured result.
# A prompt-injected reviewer/runner CANNOT widen what runs — it can only pick the
# command; this script re-checks the floor every time.
#
#   run-scoped-check.sh --head <ref|N> --base <ref> --min-ceiling <limited|trusted> \
#       [--timeout SECS] [--output-cap BYTES] [--expect-head-sha SHA] \
#       [--allow-path-prefix PREFIX] [--prescan PATH]
#       [--internal-artifact <file|bead>] -- python -m pytest <nodeid> ...
#       [--internal-artifact <file|bead>] -- go test ./path/to/package
#
# Runs in the caller's own worktree, which MUST be checked out at the PR head (the
# reviewer/runner fetches + `git checkout --detach` first). This gate VERIFIES that
# rather than trusting it — GATE 2 skips if an in-scope target file is absent (the
# tell-tale of a tree still at base) and GATE 4 skips on a head-sha mismatch — so a
# check accidentally aimed at the base tree is skipped, never mis-reported as a fail.
# It resolves the runtime from $GC_PR_TEST_VENV (legacy Python) or the project-owned
# $GC_PREPARE_TEST_ENV hook. The hook may print a legacy executable path or a typed
# prepared-runtime.v1 JSON object. This script remains project-agnostic.
#
# NETWORK: the run is NOT network-isolated — egress is governed externally (the
# paude-proxy). Tests may attempt network; the caller (agent) classifies a
# proxy-blocked failure as `could_not_verify`, not a real test failure.
#
# OUTPUT: one `scoped-check.v1` JSON object to stdout. Exit 0 for every NORMAL
# outcome INCLUDING a skip/decline (that is a valid, reportable result); exit
# non-zero ONLY for this script's own usage/internal breakage so a caller can
# tell "the check ran and was refused/failed" from "the gate itself broke".
#
#   outcome: pass | fail | timeout | could_not_verify | skipped
#     skipped            -> a deterministic gate refused (see reason_if_skipped);
#                           NOT a failure of the PR — close gc.outcome=pass
#     could_not_verify   -> no runnable env / import missing (honest "didn't run")
#     pass|fail|timeout  -> the command ran; `fail` is a PRELIMINARY rc!=0 — the
#                           caller makes the final call (e.g. network-block ->
#                           could_not_verify) using rc, output_tail, network_hint
set -euo pipefail
set -f   # no globbing of untrusted tokens

HERE="$(cd "$(dirname "$0")" && pwd)"

HEAD="" ; BASE="origin/main" ; MIN_CEILING="" ; TIMEOUT=600 ; CAP=65536
EXPECT_SHA="" ; ALLOW_PREFIX="tests/" ; PRESCAN="$HERE/pr-prescan.sh"
INTERNAL_ARTIFACT="" ; AUTHORITY="external"
RESOLVE_LOCAL="$HERE/resolve-local-change.sh"
RUNTIME_TYPE=""
declare -a CMD=()

die() { printf '%s\n' "run-scoped-check: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --head)             HEAD="${2:?}"; shift 2 ;;
        --head=*)           HEAD="${1#*=}"; shift ;;
        --base)             BASE="${2:?}"; shift 2 ;;
        --base=*)           BASE="${1#*=}"; shift ;;
        --min-ceiling)      MIN_CEILING="${2:?}"; shift 2 ;;
        --min-ceiling=*)    MIN_CEILING="${1#*=}"; shift ;;
        --timeout)          TIMEOUT="${2:?}"; shift 2 ;;
        --timeout=*)        TIMEOUT="${1#*=}"; shift ;;
        --output-cap)       CAP="${2:?}"; shift 2 ;;
        --output-cap=*)     CAP="${1#*=}"; shift ;;
        --expect-head-sha)  EXPECT_SHA="${2:?}"; shift 2 ;;
        --expect-head-sha=*) EXPECT_SHA="${1#*=}"; shift ;;
        --allow-path-prefix) ALLOW_PREFIX="${2:?}"; shift 2 ;;
        --allow-path-prefix=*) ALLOW_PREFIX="${1#*=}"; shift ;;
        --prescan)          PRESCAN="${2:?}"; shift 2 ;;
        --prescan=*)        PRESCAN="${1#*=}"; shift ;;
        --internal-artifact) INTERNAL_ARTIFACT="${2:?}"; shift 2 ;;
        --internal-artifact=*) INTERNAL_ARTIFACT="${1#*=}"; shift ;;
        --)                 shift; CMD=("$@"); break ;;
        -*)                 die "unknown option '$1'" ;;
        *)                  die "unexpected argument '$1' (did you forget '--' before the command?)" ;;
    esac
done

[ -n "$HEAD" ]        || die "usage: --head is required"
[ -n "$MIN_CEILING" ] || die "usage: --min-ceiling is required (limited|trusted)"
[ "${#CMD[@]}" -gt 0 ] || die "usage: a command is required after '--'"
case "$MIN_CEILING" in limited|trusted) ;; *) die "--min-ceiling must be limited|trusted" ;; esac
[ -x "$HERE/normalize-pr-target.sh" ] || die "target normalizer not found/executable: $HERE/normalize-pr-target.sh"
HEAD_NORM=$("$HERE/normalize-pr-target.sh" "$HEAD" --rig "${GC_RIG:-vllm}" --rig-explicit) || exit $?
HEAD=$(printf '%s' "$HEAD_NORM" | jq -r '.spec')

rank() { case "$1" in block) echo 0;; restricted) echo 1;; limited) echo 2;; trusted) echo 3;; *) echo 3;; esac; }

# Internal execution authority is never inferred from a ref or a self-consistent
# JSON object. Re-resolve the canonical artifact against its producer lifecycle
# bead and require this exact immutable range before considering execution.
if [ -n "$INTERNAL_ARTIFACT" ]; then
    [ -x "$RESOLVE_LOCAL" ] || die "local artifact resolver not found/executable: $RESOLVE_LOCAL"
    INTERNAL_JSON=$("$RESOLVE_LOCAL" --repo . --rig "${GC_RIG:-vllm}" \
        --artifact "$INTERNAL_ARTIFACT" --require-internal-producer) \
        || die "internal artifact provenance validation failed"
    INTERNAL_HEAD=$(printf '%s' "$INTERNAL_JSON" | jq -r '.head.sha')
    INTERNAL_BASE=$(printf '%s' "$INTERNAL_JSON" | jq -r '.base.sha')
    [ "$HEAD" = "$INTERNAL_HEAD" ] \
        || die "internal artifact head mismatch: gate=$HEAD artifact=$INTERNAL_HEAD"
    [ "$BASE" = "$INTERNAL_BASE" ] \
        || die "internal artifact base mismatch: gate=$BASE artifact=$INTERNAL_BASE"
    AUTHORITY="internal-producer"
fi

# emit <outcome> [k v k v ...] : print scoped-check.v1 and exit 0.
# Fixed fields default empty/false/0; extra k/v pairs override via a JSON merge.
emit() {
    local outcome="$1"; shift
    local extra="{}"
    while [ $# -gt 1 ]; do extra=$(printf '%s' "$extra" | jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}'); shift 2; done
    jq -n \
        --arg schema "scoped-check.v1" \
        --arg outcome "$outcome" \
        --arg command "${CMD[*]}" \
        --arg head "$HEAD" --arg base "$BASE" --arg min_ceiling "$MIN_CEILING" \
        --arg authority "$AUTHORITY" \
        --arg runtime_type "$RUNTIME_TYPE" \
        --argjson timeout_s "$TIMEOUT" \
        --argjson extra "$extra" \
        '{schema:$schema, outcome:$outcome, command:$command, head_ref:$head,
          base_ref:$base, min_ceiling:$min_ceiling, timeout_s:$timeout_s,
          ran:false, rc:null, ceiling:null, env_used:null, env_source:null,
          runtime_type:(if $runtime_type == "" then null else $runtime_type end),
          reason_if_skipped:"", duration_s:null, output_tail:"", head_sha:null,
          git_clean_before:null, git_clean_after:null, mutations_delta:[],
          network_hint:false, execution_authority:$authority,
          failure_class:"none", failure_reason:""} + $extra'
    exit 0
}

# --- GATE 1: command form (approved runtime grammars, no shell metachars) -----
# argv is executed directly (no shell), but metacharacters and arbitrary tools
# are still rejected defensively. The first token names a logical runtime only;
# it is replaced with the operator-prepared executable below.
case "${CMD[0]}" in
    python|python3) RUNTIME_TYPE="python" ;;
    go) RUNTIME_TYPE="go" ;;
    *) emit skipped reason_if_skipped "command-not-in-prepared-env-form: must start with 'python', 'python3', or 'go' (got '${CMD[0]}')" ;;
esac
for tok in "${CMD[@]}"; do
    case "$tok" in
        *[\;\|\&\$\`\(\)\<\>\*\?\~\!]* | *' '*)
            emit skipped reason_if_skipped "command-not-in-prepared-env-form: illegal token '$tok'" ;;
    esac
done

# Go is deliberately not an arbitrary tool front-end. Admit only `go test`, a
# small flag allowlist, and one or more repo-relative package paths. In
# particular, dangerous command-controlled hooks such as -exec/-toolexec and
# non-test subcommands never reach the prepared Go executable.
if [ "$RUNTIME_TYPE" = "go" ]; then
    [ "${CMD[1]-}" = "test" ] \
        || emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "command-not-in-prepared-env-form: Go commands must use 'go test'"
    GO_PACKAGE_COUNT=0
    for ((i=2; i<${#CMD[@]}; i++)); do
        tok="${CMD[$i]}"
        case "$tok" in
            -v|-short|-failfast|-count=1) ;;
            -*) emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "command-not-in-prepared-env-form: unsupported Go test flag '$tok'" ;;
            ./*) GO_PACKAGE_COUNT=$((GO_PACKAGE_COUNT + 1)) ;;
            *) emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "command-not-in-prepared-env-form: Go test targets must be repo-relative './...' packages (got '$tok')" ;;
        esac
    done
    [ "$GO_PACKAGE_COUNT" -gt 0 ] \
        || emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "command-not-in-prepared-env-form: Go test requires a repo-relative package target"
fi

# --- GATE 2: path scope + target presence -------------------------------------
# Python considers tokens that look like test targets (contain '/', '::', or end
# in .py). Go considers every admitted repo-relative package operand.
# Each in-scope target must (a) sit under the allowed prefix AND (b) actually exist
# in this worktree. (b) is a deterministic "the tree is at the PR head" check: a
# reviewer that never checked out the head (tree still at base) is missing the PR's
# NEW test file — skip honestly with "checkout the PR head" instead of letting pytest
# exit rc=4 (file not found) and mislabeling it a test `fail` in the classifier below.
if [ -n "$ALLOW_PREFIX" ]; then
    scope="${ALLOW_PREFIX#./}"
    scope="${scope%/}"
    case "$scope" in
        ""|.|/*|..|../*|*/../*|*/..) emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "invalid-path-scope: '$ALLOW_PREFIX' must name a repo-relative subdirectory" ;;
    esac
    found_target=0
    if [ "$RUNTIME_TYPE" = "go" ]; then
        for ((i=2; i<${#CMD[@]}; i++)); do
            tok="${CMD[$i]}"
            case "$tok" in -*) continue ;; esac
            target="${tok#./}"
            path="${target%/...}"
            case "$path" in ""|.|..|../*|*/../*|*/..) emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "out-of-scope: invalid Go package target '$tok'" ;; esac
            found_target=1
            case "$path" in
                "$scope"|"$scope"/*) ;;
                *) emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "out-of-scope: target '$tok' is not under '$ALLOW_PREFIX'" ;;
            esac
            [ -d "$path" ] || emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "target-absent — '$path' is not in this worktree; checkout the PR head first (fetch + git checkout --detach <head>)"
        done
    else
        for tok in "${CMD[@]}"; do
            case "$tok" in
                -*) continue ;;
                */*|*::*|*.py)
                    found_target=1
                    path="${tok%%::*}"
                    normalized="${path#./}"
                    case "$normalized" in
                        "$scope"|"$scope"/*) ;;
                        *) emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "out-of-scope: target '$tok' is not under '$ALLOW_PREFIX'" ;;
                    esac
                    [ -e "$path" ] || emit skipped runtime_type "$RUNTIME_TYPE" reason_if_skipped "target-absent — '$path' is not in this worktree; checkout the PR head first (fetch + git checkout --detach <head>)"
                    ;;
            esac
        done
    fi
    [ "$found_target" -eq 1 ] || emit skipped reason_if_skipped "out-of-scope: no test target under '$ALLOW_PREFIX' found in command"
fi

# --- GATE 3: re-derive the ceiling; refuse if it dropped below the floor ------
if ! SCAN=$("$PRESCAN" "$HEAD" "$BASE" 2>/dev/null); then
    emit skipped reason_if_skipped "prescan-failed (infra: gh/refs unreachable)" failure_class "transient" failure_reason "prescan-nonzero"
fi
CEILING=$(printf '%s' "$SCAN" | jq -r '.ceiling_posture // "block"')
if [ "$(rank "$CEILING")" -lt "$(rank "$MIN_CEILING")" ]; then
    emit skipped ceiling "$CEILING" reason_if_skipped "ceiling-below-required: fresh ceiling=$CEILING < required=$MIN_CEILING"
fi

# --- GATE 4: tree-is-at-head pin ---------------------------------------------
# Two complementary ways to confirm the tree we run in is the PR head, not base:
#   (a) --expect-head-sha: the caller resolved the head sha (the reviewer/runner
#       pass it) — authoritative; also guards a force-push between approval and run.
#   (b) self-resolve --head: only when no pin was passed. If --head names a ref/sha
#       we can resolve in this worktree, it must equal HEAD. A bare PR number that
#       resolves to no local ref is left to GATE 2's target-presence check.
CUR_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -n "$EXPECT_SHA" ]; then
    if [ "$CUR_SHA" != "$EXPECT_SHA" ]; then
        emit skipped ceiling "$CEILING" head_sha "$CUR_SHA" reason_if_skipped "head-moved: expected $EXPECT_SHA got $CUR_SHA (checkout the PR head)"
    fi
else
    HEAD_SHA=$(git rev-parse --verify --quiet "${HEAD}^{commit}" 2>/dev/null || echo "")
    if [ -n "$HEAD_SHA" ] && [ -n "$CUR_SHA" ] && [ "$CUR_SHA" != "$HEAD_SHA" ]; then
        emit skipped ceiling "$CEILING" head_sha "$CUR_SHA" reason_if_skipped "tree-not-at-head: HEAD=$CUR_SHA but --head '$HEAD' resolves to $HEAD_SHA — checkout the PR head first"
    fi
fi

# --- Resolve a typed prepared runtime (PROJECT-AGNOSTIC) ----------------------
# Legacy Python venvs remain supported. The operator-owned hook may emit either
# one executable path (legacy; type inferred from the admitted command) or:
#   {"schema":"prepared-runtime.v1","runtime":"python|go","executable":"/abs/path"}
# The hook is never PR-controlled and runs only when a check needs to execute.
RUNTIME_EXEC=""
ENV_SOURCE=""
PREPARED_OUTPUT=""
if [ "$RUNTIME_TYPE" = "python" ] && [ -n "${GC_PR_TEST_VENV:-}" ] && [ -x "${GC_PR_TEST_VENV}/bin/python" ]; then
    RUNTIME_EXEC="${GC_PR_TEST_VENV}/bin/python"; ENV_SOURCE="GC_PR_TEST_VENV"
elif [ "$RUNTIME_TYPE" = "python" ] && [ -x "./.venv/bin/python" ]; then
    RUNTIME_EXEC="$(pwd)/.venv/bin/python"; ENV_SOURCE="worktree-venv"
elif [ -n "${GC_PREPARE_TEST_ENV:-}" ] && [ -x "${GC_PREPARE_TEST_ENV}" ]; then
    if PREPARED_OUTPUT=$("${GC_PREPARE_TEST_ENV}" --src "$(pwd)" --venv "$(pwd)/.venv" 2>/dev/null); then
        if printf '%s' "$PREPARED_OUTPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
            if printf '%s' "$PREPARED_OUTPUT" | jq -e '
                .schema == "prepared-runtime.v1" and
                (.runtime == "python" or .runtime == "go") and
                (.executable | type == "string" and length > 0)
              ' >/dev/null 2>&1; then
                PREPARED_TYPE=$(printf '%s' "$PREPARED_OUTPUT" | jq -r '.runtime')
                RUNTIME_EXEC=$(printf '%s' "$PREPARED_OUTPUT" | jq -r '.executable')
                [ "$PREPARED_TYPE" = "$RUNTIME_TYPE" ] || RUNTIME_EXEC=""
            fi
        elif [ "$(printf '%s\n' "$PREPARED_OUTPUT" | wc -l)" -eq 1 ]; then
            RUNTIME_EXEC="$PREPARED_OUTPUT"
        fi
        [ -z "$RUNTIME_EXEC" ] || ENV_SOURCE="prepare-hook"
    fi
fi
case "$RUNTIME_EXEC" in /*) ;; *) RUNTIME_EXEC="" ;; esac
HEALTHY=false
if [ -n "$RUNTIME_EXEC" ] && [ -x "$RUNTIME_EXEC" ]; then
    case "$RUNTIME_TYPE" in
        python) "$RUNTIME_EXEC" -c 'import sys' >/dev/null 2>&1 && HEALTHY=true ;;
        go) "$RUNTIME_EXEC" version 2>/dev/null | grep -q '^go version go' && HEALTHY=true ;;
    esac
fi
if [ "$HEALTHY" != true ]; then
    emit could_not_verify ceiling "$CEILING" head_sha "$CUR_SHA" \
        runtime_type "$RUNTIME_TYPE" reason_if_skipped "no-runnable-env: configure GC_PREPARE_TEST_ENV to return a matching prepared-runtime.v1 object (legacy Python venv/path output is also supported)"
fi

# --- git-clean baseline ------------------------------------------------------
BEFORE=$(git status --porcelain=v1 2>/dev/null || true)

# --- Run (prepared executable substituted; network governed externally) -------
declare -a RUN=("$RUNTIME_EXEC" "${CMD[@]:1}")
START=$(date +%s 2>/dev/null || echo 0)
set +e
OUTPUT=$(timeout --signal=KILL "${TIMEOUT}s" "${RUN[@]}" 2>&1)
RC=$?
set -e
END=$(date +%s 2>/dev/null || echo 0)
DUR=$((END - START))
OUTPUT_TAIL=$(printf '%s' "$OUTPUT" | tail -c "$CAP")

# --- git-clean after ---------------------------------------------------------
AFTER=$(git status --porcelain=v1 2>/dev/null || true)
DELTA=$(comm -13 <(printf '%s\n' "$BEFORE" | sort) <(printf '%s\n' "$AFTER" | sort) | sed '/^$/d')
if [ -z "$BEFORE" ]; then CLEAN_BEFORE=true; else CLEAN_BEFORE=false; fi
if [ "$AFTER" = "$BEFORE" ]; then CLEAN_AFTER=true; else CLEAN_AFTER=false; fi
DELTA_JSON=$(printf '%s' "$DELTA" | jq -R -s -c 'split("\n") | map(select(length>0))')

# --- classify (PRELIMINARY — caller makes the final call) --------------------
NET_HINT=false
if printf '%s' "$OUTPUT_TAIL" | grep -qiE 'OSError|ConnectionError|Max retries|ProxyError|SSLError|Temporary failure in name resolution|Failed to establish|Could not reach|HTTPSConnectionPool|urlopen error|CERTIFICATE_VERIFY|dial tcp|no such host|TLS handshake timeout'; then
    NET_HINT=true
fi
case "$RC" in
    0)        OUTCOME="pass" ;;
    124|137)  OUTCOME="timeout" ;;
    *)        if printf '%s' "$OUTPUT_TAIL" | grep -qiE 'ModuleNotFoundError|ImportError'; then OUTCOME="could_not_verify"; else OUTCOME="fail"; fi ;;
esac

jq -n \
    --arg schema "scoped-check.v1" \
    --arg outcome "$OUTCOME" \
    --arg command "${CMD[*]}" \
    --arg head "$HEAD" --arg base "$BASE" --arg min_ceiling "$MIN_CEILING" \
    --arg ceiling "$CEILING" \
    --arg env_used "$RUNTIME_EXEC" --arg env_source "$ENV_SOURCE" \
    --arg runtime_type "$RUNTIME_TYPE" \
    --arg authority "$AUTHORITY" \
    --arg head_sha "$CUR_SHA" \
    --arg output_tail "$OUTPUT_TAIL" \
    --argjson ran true \
    --argjson rc "$RC" \
    --argjson timeout_s "$TIMEOUT" \
    --argjson duration_s "$DUR" \
    --argjson clean_before "$CLEAN_BEFORE" \
    --argjson clean_after "$CLEAN_AFTER" \
    --argjson delta "$DELTA_JSON" \
    --argjson net_hint "$NET_HINT" \
    '{schema:$schema, outcome:$outcome, command:$command, head_ref:$head,
      base_ref:$base, min_ceiling:$min_ceiling, ceiling:$ceiling, ran:$ran,
      rc:$rc, env_used:$env_used, env_source:$env_source,
      runtime_type:$runtime_type, reason_if_skipped:"",
      timeout_s:$timeout_s, duration_s:$duration_s, output_tail:$output_tail,
      head_sha:$head_sha, git_clean_before:$clean_before, git_clean_after:$clean_after,
      mutations_delta:$delta, network_hint:$net_hint, failure_class:"none",
      failure_reason:"", execution_authority:$authority}'
