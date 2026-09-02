#!/usr/bin/env bash
# Pack doctor check: keep agent-visible script paths valid from isolated worktrees.
#
# Prompt templates do not expose {{.ConfigDir}}. Using that placeholder in a
# standing prompt renders an empty value and produces the broken /assets/scripts
# path. Managed sessions do always receive GC_CITY_PATH, and this local pack is
# installed at <city>/dev-pack, so prompts and formula descriptions share that
# one runtime contract.

set -euo pipefail

pack_dir="${GC_PACK_DIR:?GC_PACK_DIR is required}"
city_dir="${GC_CITY_PATH:?GC_CITY_PATH is required}"
expected_pack_dir="$city_dir/dev-pack"

if [[ "$(readlink -f "$pack_dir")" != "$(readlink -f "$expected_pack_dir")" ]]; then
    echo "dev-pack script-root contract is not satisfied"
    echo "loaded pack: $pack_dir"
    echo "managed-session path: $expected_pack_dir"
    exit 2
fi

findings_file=$(mktemp)
trap 'rm -f "$findings_file"' EXIT
if grep -RInF '{{.ConfigDir}}/assets/scripts' \
    "$pack_dir/agents" "$pack_dir/formulas" >"$findings_file"; then
    echo "unsupported ConfigDir script references found"
    cat "$findings_file"
    exit 2
fi

required_scripts=(
    pr-prescan.sh
    posture-latitude.sh
    run-scoped-check.sh
    run-dynamic-verification.sh
    emit-review.py
)

for script in "${required_scripts[@]}"; do
    path="$expected_pack_dir/assets/scripts/$script"
    if [[ ! -x "$path" ]]; then
        echo "required workflow script is not executable"
        echo "$path"
        exit 2
    fi
    if ! grep -RFl --include='*.toml' --include='*.template.md' \
        "\$GC_CITY_PATH/dev-pack/assets/scripts/$script" \
        "$pack_dir/agents" "$pack_dir/formulas" >/dev/null; then
        echo "canonical script reference missing"
        echo "$script"
        exit 2
    fi
done

echo "workflow script paths resolve from isolated worktrees"
