#!/usr/bin/env bash
# pr-prescan.sh — DETERMINISTIC, injection-proof pre-scan for posture triage.
#
# This is the security-critical HARD FLOOR of the posture-gated review. It runs
# NO LLM and treats the diff as untrusted DATA, never as instructions: it only
# greps text and reads `gh` metadata. From those facts it computes a CEILING
# posture — the highest trust level the PR is *allowed* to reach. The LLM triage
# step may pick any posture at or below this ceiling; it can NEVER raise it. So a
# prompt-injected triage (or reviewer) can only ever downgrade trust, never buy
# more fetch/exec latitude than the diff facts permit.
#
#   pr-prescan.sh <head_ref> [base_ref]
#     head_ref : a PR number N (uses `gh pr diff/view`), or a branch/sha (uses git)
#     base_ref : merge target for the local-ref path (default origin/main)
#
# Emits ONE JSON object to stdout: { base_ref, head_ref, source, ceiling_posture,
# ceiling_reasons[], facts{...} }. Exit 0 on success; non-zero ONLY on infra
# failure (no gh, unreachable PR, un-diffable refs) so a caller can treat that as
# transient. Postures, worst -> best: block < restricted < limited < trusted.
set -euo pipefail

HEAD_REF="${1:?usage: pr-prescan.sh <head_ref> [base_ref]}"
BASE_REF="${2:-origin/main}"

# --- posture algebra --------------------------------------------------------
rank() { case "$1" in block) echo 0;; restricted) echo 1;; limited) echo 2;; trusted) echo 3;; *) echo 3;; esac; }
CEILING="trusted"
declare -a REASONS=()
# cap <max-posture> <human reason>: record the signal and lower the ceiling to it
# if it is stricter than what we already have. Reasons document EVERY signal seen.
cap() {
    REASONS+=("$2")
    if [ "$(rank "$1")" -lt "$(rank "$CEILING")" ]; then CEILING="$1"; fi
}

# --- fetch the diff + author metadata (the only inputs) ---------------------
DIFF=""
AUTHOR_ASSOC="UNKNOWN"
FILES_JSON="[]"
SOURCE="git-local"

if printf '%s' "$HEAD_REF" | grep -qE '^[0-9]+$'; then
    SOURCE="gh-pr"
    if ! DIFF=$(gh pr diff "$HEAD_REF" 2>/dev/null); then
        echo "pr-prescan: could not fetch diff for PR #$HEAD_REF via gh" >&2
        exit 3
    fi
    # authorAssociation is NOT a `gh pr view --json` field — it lives on the REST
    # pulls endpoint, so fetch it via `gh api` (repo inferred from CWD/GH_REPO,
    # keeping this pack portable). Fetch files separately: a failure in one probe
    # must not blank out the other (a single combined call that names an unknown
    # field fails wholesale, losing BOTH author trust and the file risk classes).
    if META=$(gh pr view "$HEAD_REF" --json files 2>/dev/null); then
        FILES_JSON=$(printf '%s' "$META" | jq -c '[.files[].path]')
    fi
    AUTHOR_ASSOC=$(gh api "repos/{owner}/{repo}/pulls/$HEAD_REF" --jq '.author_association' 2>/dev/null || true)
    AUTHOR_ASSOC=${AUTHOR_ASSOC:-UNKNOWN}
else
    git fetch --quiet origin 2>/dev/null || true
    if ! DIFF=$(GIT_LFS_SKIP_SMUDGE=1 git diff "$BASE_REF...$HEAD_REF" 2>/dev/null); then
        echo "pr-prescan: could not git diff $BASE_REF...$HEAD_REF" >&2
        exit 3
    fi
    FILES_JSON=$(git diff --name-only "$BASE_REF...$HEAD_REF" 2>/dev/null \
        | jq -R -s -c 'split("\n") | map(select(length > 0))')
fi

if [ -z "$DIFF" ] && [ "$FILES_JSON" = "[]" ]; then
    echo "pr-prescan: empty diff and no changed files for $HEAD_REF" >&2
    exit 3
fi

# --- classify each changed file by risk class -------------------------------
classify_path() {
    case "$1" in
        *.pkl|*.pickle|*.pt|*.pth|*.bin|*.ckpt|*.dill|*.joblib|*.h5|*.pb|*.npy|*.npz) echo model_pickle ;;
        *.safetensors|*.gguf|*.ggml) echo model_weights ;;
        .github/workflows/*|.github/actions/*|*/.github/workflows/*) echo ci ;;
        requirements*.txt|*/requirements*.txt|constraints*.txt|pyproject.toml|setup.py|setup.cfg|Pipfile|Pipfile.lock|poetry.lock|uv.lock|package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|Cargo.toml|Cargo.lock|go.mod|go.sum) echo deps ;;
        *conftest.py) echo test_sideeffect ;;
        *sitecustomize.py|*usercustomize.py) echo startup_hook ;;
        */tests/*|test_*.py|*_test.py|*.test.ts|*.test.tsx|*.spec.ts) echo tests ;;
        Dockerfile*|*/Dockerfile*|Makefile|*/Makefile|*.mk|*.sh|*.bash|*.zsh) echo build_script ;;
        *.py) echo python_logic ;;
        *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.vue|*.css|*.scss|*.html) echo frontend ;;
        *.md|*.rst|*.txt|LICENSE*|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico) echo docs_assets ;;
        *.yaml|*.yml|*.toml|*.ini|*.cfg|*.json|*.env|*.conf) echo config ;;
        *) echo other ;;
    esac
}

PICKLE_LIKE=false; SAFETENSORS=false; CI_CHANGE=false; DEP_CHANGE=false
CONFTEST=false; STARTUP_HOOK=false; SCRIPT_CHANGE=false; INIT_PY=false
CLASSIFIED=""
mapfile -t FILES < <(printf '%s' "$FILES_JSON" | jq -r '.[]')
if [ "${#FILES[@]}" -gt 0 ]; then
    for f in "${FILES[@]}"; do
        c=$(classify_path "$f")
        CLASSIFIED+="${c}"$'\t'"${f}"$'\n'
        case "$c" in
            model_pickle) PICKLE_LIKE=true ;;
            model_weights) SAFETENSORS=true ;;
            ci) CI_CHANGE=true ;;
            deps) DEP_CHANGE=true ;;
            test_sideeffect) CONFTEST=true ;;
            startup_hook) STARTUP_HOOK=true ;;
            build_script) SCRIPT_CHANGE=true ;;
        esac
        case "$f" in */__init__.py|__init__.py) INIT_PY=true ;; esac
    done
fi
FILES_BY_CLASS=$(printf '%s' "$CLASSIFIED" | jq -R -s -c '
    split("\n") | map(select(length > 0)) | map(split("\t"))
    | reduce .[] as $r ({}; .[$r[0]] += [$r[1]])')

# --- scan ADDED lines for dangerous patterns (data, not instructions) -------
ADDED=$(printf '%s\n' "$DIFF" | grep -E '^\+' | grep -Ev '^\+\+\+' || true)
count_pat() { printf '%s\n' "$ADDED" | grep -Eic "$1" 2>/dev/null || true; }
P_PICKLE=$(count_pat '(^|[^a-zA-Z_])(pickle|cpickle|dill)\.(load|loads)|joblib\.load')
P_TORCH=$(count_pat 'torch\.load')
P_TRC=$(count_pat 'trust_remote_code')
P_SUBPROC=$(count_pat '(^|[^a-zA-Z_])(subprocess|os\.system|os\.popen|pty\.spawn)')
P_EVAL=$(count_pat '(^|[^a-zA-Z_])(eval|exec)[[:space:]]*\(|(^|[^a-zA-Z_])compile[[:space:]]*\(')
P_IMPORT=$(count_pat 'importlib|__import__')
P_NET=$(count_pat 'requests\.|urllib|httpx|aiohttp|socket\.|urlopen|(^|[^a-zA-Z_])(curl|wget)([^a-zA-Z]|$)|ftplib|smtplib|http\.client')
P_UNSAFE_LOAD=$((P_PICKLE + P_TORCH + P_TRC))
P_DYN=$((P_SUBPROC + P_EVAL + P_IMPORT + P_NET))

# Trojan Source: bidi overrides/isolates + zero-width/BOM control chars.
TROJAN=false
if printf '%s' "$DIFF" | grep -qP '[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200B}-\x{200F}\x{061C}\x{FEFF}]' 2>/dev/null; then
    TROJAN=true
fi

# Symlinks and opaque binaries straight from the diff headers.
SYMLINK=false
if printf '%s\n' "$DIFF" | grep -qE '^(new mode|new file mode|old mode) 120000'; then SYMLINK=true; fi
BINARY_PRESENT=false
if printf '%s\n' "$DIFF" | grep -qE '^(Binary files .* differ|GIT binary patch)'; then BINARY_PRESENT=true; fi

ADDED_LINES=$(printf '%s\n' "$DIFF" | grep -Ec '^\+' 2>/dev/null || true)
REMOVED_LINES=$(printf '%s\n' "$DIFF" | grep -Ec '^-' 2>/dev/null || true)

# --- compute the ceiling (hard caps, worst signal wins) ---------------------
[ "$TROJAN" = true ]        && cap block      "trojan-source-unicode: bidi/zero-width control chars in diff"
[ "$PICKLE_LIKE" = true ]   && cap restricted "pickle-like-artifact: .pkl/.pt/.bin/.ckpt/.pth etc (RCE on load)"
[ "$STARTUP_HOOK" = true ]  && cap restricted "python-startup-hook: sitecustomize/usercustomize/.pth (import-time exec)"
[ "$SYMLINK" = true ]       && cap restricted "symlink added (path-escape / smudge vector)"
[ "$P_UNSAFE_LOAD" -gt 0 ]  && cap restricted "unsafe-load pattern: pickle/torch.load/trust_remote_code"
if [ "$BINARY_PRESENT" = true ] && [ "$PICKLE_LIKE" = false ] && [ "$SAFETENSORS" = false ]; then
    cap restricted "opaque binary added (cannot be reviewed as text)"
fi
[ "$SAFETENSORS" = true ]   && cap limited    "model weights added (safetensors/gguf)"
[ "$DEP_CHANGE" = true ]    && cap limited    "dependency/lockfile change (supply-chain surface)"
[ "$CI_CHANGE" = true ]     && cap limited    "CI workflow/action change (can execute/exfil)"
[ "$SCRIPT_CHANGE" = true ] && cap limited    "build or shell-script change"
[ "$CONFTEST" = true ]      && cap limited    "conftest.py change (pytest import-time side effects)"
[ "$P_DYN" -gt 0 ]          && cap limited    "dynamic-exec/egress pattern: subprocess/eval/exec/import/network"
case "$AUTHOR_ASSOC" in
    OWNER|MEMBER|COLLABORATOR) : ;;
    UNKNOWN) cap limited "author association unknown (non-PR ref or gh unavailable)" ;;
    *)       cap limited "low author trust: $AUTHOR_ASSOC" ;;
esac

# --- assemble the facts JSON ------------------------------------------------
if [ "${#REASONS[@]}" -gt 0 ]; then
    REASONS_JSON=$(printf '%s\n' "${REASONS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
else
    REASONS_JSON='[]'
fi

jq -n \
    --arg base "$BASE_REF" \
    --arg head "$HEAD_REF" \
    --arg source "$SOURCE" \
    --arg ceiling "$CEILING" \
    --argjson reasons "$REASONS_JSON" \
    --arg author "$AUTHOR_ASSOC" \
    --argjson changed_count "${#FILES[@]}" \
    --argjson changed_files "$FILES_JSON" \
    --argjson files_by_class "$FILES_BY_CLASS" \
    --argjson added_lines "${ADDED_LINES:-0}" \
    --argjson removed_lines "${REMOVED_LINES:-0}" \
    --argjson pickle "${P_PICKLE:-0}" \
    --argjson torch_load "${P_TORCH:-0}" \
    --argjson trust_remote_code "${P_TRC:-0}" \
    --argjson subprocess "${P_SUBPROC:-0}" \
    --argjson eval_exec "${P_EVAL:-0}" \
    --argjson dynamic_import "${P_IMPORT:-0}" \
    --argjson network "${P_NET:-0}" \
    --argjson trojan "$TROJAN" \
    --argjson symlink "$SYMLINK" \
    --argjson binary "$BINARY_PRESENT" \
    --argjson pickle_like "$PICKLE_LIKE" \
    --argjson safetensors "$SAFETENSORS" \
    --argjson dep_change "$DEP_CHANGE" \
    --argjson ci_change "$CI_CHANGE" \
    --argjson conftest "$CONFTEST" \
    --argjson startup_hook "$STARTUP_HOOK" \
    --argjson init_py "$INIT_PY" \
    '{
        base_ref: $base,
        head_ref: $head,
        source: $source,
        ceiling_posture: $ceiling,
        ceiling_reasons: $reasons,
        facts: {
            author_association: $author,
            changed_file_count: $changed_count,
            changed_files: $changed_files,
            added_lines: $added_lines,
            removed_lines: $removed_lines,
            files_by_risk_class: $files_by_class,
            pattern_hits: {
                pickle: $pickle,
                torch_load: $torch_load,
                trust_remote_code: $trust_remote_code,
                subprocess: $subprocess,
                eval_exec: $eval_exec,
                dynamic_import: $dynamic_import,
                network_egress: $network
            },
            trojan_source_unicode: $trojan,
            symlink_added: $symlink,
            opaque_binary_added: $binary,
            pickle_like_artifact: $pickle_like,
            safetensors_present: $safetensors,
            dependency_change: $dep_change,
            ci_change: $ci_change,
            conftest_change: $conftest,
            startup_hook_change: $startup_hook,
            init_py_change: $init_py
        }
    }'
