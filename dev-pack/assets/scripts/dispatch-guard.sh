#!/usr/bin/env bash
# Shared trigger/provenance/output fence for every pooled dev-pack lane.

dev_pack_guard_die() {
    printf '%s\n' "dispatch-guard: $*" >&2
    return 2
}

dev_pack_guard_bead_json() {
    local bead=$1 raw exact
    raw=$("${GC_BIN:-gc}" bd show "$bead" --json) \
        || { dev_pack_guard_die "cannot read trigger bead $bead"; return; }
    exact=$(printf '%s' "$raw" | jq -er \
        --arg bead "$bead" '(if type == "array" then .[0] else . end) | select(.id == $bead) | .id') \
        || { dev_pack_guard_die "lookup did not resolve exact bead id $bead"; return; }
    [ "$exact" = "$bead" ] || { dev_pack_guard_die "lookup resolved $exact, expected $bead"; return; }
    printf '%s' "$raw"
}

# Validate an output target against the immutable launch-time trigger before any
# metadata/provenance write. Retry wrappers may validate a logical trigger in
# emit-review.py and then delegate to its uniquely-derived active attempt.
dev_pack_validate_output_target() {
    local target=$1 trigger=${GC_TRIGGER_BEAD_ID:-} source
    source=${DEV_PACK_VALIDATED_TRIGGER_BEAD_ID:-$target}

    if [ -z "$trigger" ]; then
        # Manual/operator invocations remain supported, but managed pool sessions
        # must never fall back to discovery or a caller-supplied bead id.
        [ "${GC_SESSION_ORIGIN:-}" != ephemeral ] \
            || { dev_pack_guard_die 'GC_TRIGGER_BEAD_ID is required in pooled sessions'; return; }
        "${GC_BIN:-gc}" bd show "$target" --json
        return
    else
        [ "$trigger" = "$source" ] \
            || { dev_pack_guard_die "trigger $trigger does not match validated source $source"; return; }
        if [ "$target" != "$source" ]; then
            [ "${DEV_PACK_VALIDATED_OUTPUT_BEAD_ID:-}" = "$target" ] \
                || { dev_pack_guard_die "output target $target was not derived from trigger $source"; return; }
        fi
        dev_pack_guard_bead_json "$source" >/dev/null || return
    fi

    dev_pack_guard_bead_json "$target"
}

dev_pack_acquire_output_lock() {
    local bead=$1 lock_root safe
    command -v flock >/dev/null 2>&1 \
        || { dev_pack_guard_die 'flock is required for serialized output writes'; return; }
    lock_root=${GC_CITY_RUNTIME_DIR:-${GC_CITY_PATH:-${GC_CITY:-.}}/.gc/runtime}
    lock_root=$lock_root/dev-pack/output-locks
    mkdir -p "$lock_root"
    safe=$(printf '%s' "$bead" | tr -c 'A-Za-z0-9._-' '_')
    exec {DEV_PACK_OUTPUT_LOCK_FD}>"$lock_root/$safe.lock"
    flock -x "$DEV_PACK_OUTPUT_LOCK_FD"
}

# Must run while the per-bead output lock is held. A pre-existing output is a
# competing/stale writer, never permission to overwrite a durable result.
dev_pack_assert_output_slot_empty() {
    local bead=$1 raw existing stamped_name stamped_dir current_dir
    raw=$(dev_pack_validate_output_target "$bead") || return
    existing=$(printf '%s' "$raw" | jq -er \
        '(if type == "array" then .[0] else . end).metadata["gc.output_json"] // empty') || true
    [ -z "$existing" ] \
        || { dev_pack_guard_die "refusing to overwrite existing gc.output_json on $bead"; return; }

    stamped_name=$(printf '%s' "$raw" | jq -r \
        '(if type == "array" then .[0] else . end).metadata["gc.session_name"] // empty')
    if [ -n "$stamped_name" ] && [ -n "${GC_SESSION_NAME:-}" ] && [ "$stamped_name" != "$GC_SESSION_NAME" ]; then
        dev_pack_guard_die "session provenance mismatch on $bead: $stamped_name != $GC_SESSION_NAME"
        return
    fi
    stamped_dir=$(printf '%s' "$raw" | jq -r \
        '(if type == "array" then .[0] else . end).metadata["gc.work_dir"] // empty')
    current_dir=$(pwd -P)
    if [ -n "$stamped_dir" ] && [ "$stamped_dir" != "$current_dir" ]; then
        dev_pack_guard_die "work-dir provenance mismatch on $bead: $stamped_dir != $current_dir"
        return
    fi
}
