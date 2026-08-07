#!/usr/bin/env bash
# learn — append a curated invariant to the per-domain review-knowledge flywheel.
#
#   gc pr-review-pack learn --area <domain> --invariant "<rule>" [--from-pr N] [--author @h]
#   gc pr-review-pack learn --from-candidates <file> [--area <domain>]
#
# WHY THIS EXISTS: the reviewer loads only the knowledge/<domain>.md a PR touches
# (see $GC_PR_KNOWLEDGE/_manifest.md). This is the LLM-free appender that grows those
# per-domain files — one flywheel per domain, so no single list accumulates across
# unrelated areas. Two modes:
#
#   --invariant  : fold one lesson back (e.g. after the human corrects a verdict).
#                  Stamped `(learned vllm#N[ by @author])`. The `vllm#` prefix keeps
#                  provenance de-linked: GitHub won't autolink it to THIS repo (a bare
#                  `#N` would mislink), yet it stays greppable/reconstructable.
#   --from-candidates <file> : batch-accept curated seed candidates (the human has
#                  already pruned the file to the ones they trust). Every `- ` bullet
#                  in the file is appended, re-numbered into the target domain, with
#                  its own provenance preserved.
#
# Appended entries land under each file's "## Learned / seeded invariants" section
# with a fresh, monotonic [INV-<PREFIX>-NNN] id. Knowledge files are read fresh by
# the reviewer each run, so appends are LIVE on the next review — no `gc reload`.
#
# Knowledge dir resolution: --knowledge-dir, else $GC_PR_KNOWLEDGE. (The env is set
# for the reviewer agent via [[rigs.patches]]; when running this from a human shell,
# export GC_PR_KNOWLEDGE or pass --knowledge-dir. The pack itself stays project-
# agnostic — the corpus is project-specific and lives outside the pack.)
set -euo pipefail

AREA=""; INVARIANT=""; FROM_PR=""; AUTHOR=""; CANDIDATES=""
KDIR="${GC_PR_KNOWLEDGE:-}"

usage() {
    printf '%s\n' \
        "usage:" \
        "  gc pr-review-pack learn --area <domain> --invariant \"<rule>\" [--from-pr N] [--author @h]" \
        "  gc pr-review-pack learn --from-candidates <file> [--area <domain>]" \
        "" \
        "Options:" \
        "  --area <domain>          target domain (a <domain>.md must exist in \$GC_PR_KNOWLEDGE; see its _manifest.md)" \
        "  --invariant \"<rule>\"     the one-line invariant to append" \
        "  --from-pr <N>            provenance: the PR the lesson came from" \
        "  --author <@handle>       provenance: the maintainer it came from" \
        "  --from-candidates <f>    batch-accept a curated candidates file (area inferred from <area>.candidates.md)" \
        "  --knowledge-dir <dir>    override \$GC_PR_KNOWLEDGE" \
        "  -h, --help               show this help"
}
die() { printf 'learn: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --area)              AREA="${2:?--area needs a value}"; shift 2 ;;
        --area=*)            AREA="${1#*=}"; shift ;;
        --invariant)         INVARIANT="${2:?--invariant needs a value}"; shift 2 ;;
        --invariant=*)       INVARIANT="${1#*=}"; shift ;;
        --from-pr)           FROM_PR="${2:?--from-pr needs a value}"; shift 2 ;;
        --from-pr=*)         FROM_PR="${1#*=}"; shift ;;
        --author)            AUTHOR="${2:?--author needs a value}"; shift 2 ;;
        --author=*)          AUTHOR="${1#*=}"; shift ;;
        --from-candidates)   CANDIDATES="${2:?--from-candidates needs a value}"; shift 2 ;;
        --from-candidates=*) CANDIDATES="${1#*=}"; shift ;;
        --knowledge-dir)     KDIR="${2:?--knowledge-dir needs a value}"; shift 2 ;;
        --knowledge-dir=*)   KDIR="${1#*=}"; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   die "unknown argument '$1' (see --help)" ;;
    esac
done

[ -n "$KDIR" ] || { usage >&2; die "knowledge dir unknown: export \$GC_PR_KNOWLEDGE or pass --knowledge-dir"; }
[ -d "$KDIR" ] || die "knowledge dir not found: $KDIR"

# Prefix for auto-assigned [INV-<PFX>-NNN] ids. Read a project-declared
# `id-prefix: <PFX>` from the domain file (keeps project domain names OUT of this
# generic pack); fall back to a prefix derived from the area name.
area_prefix() {  # <area>
    local p=""
    [ -f "$KDIR/$1.md" ] && p=$(sed -nE 's/.*id-prefix:[[:space:]]*([A-Za-z0-9]+).*/\1/p' "$KDIR/$1.md" | head -1)
    if [ -n "$p" ]; then printf '%s' "$p" | tr '[:lower:]' '[:upper:]'
    else printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z' | cut -c1-6; fi
}

next_id() {  # <file> <prefix> -> zero-padded next number
    local f="$1" pfx="$2" max
    max=$(sed -nE "s/.*\[INV-${pfx}-0*([0-9]+)\].*/\1/p" "$f" 2>/dev/null | sort -n | tail -1 || true)
    printf '%03d' "$(( 10#${max:-0} + 1 ))"
}

append_bullet() {  # <area> <text-without-leading-dash>
    local area="$1" text="$2" f pfx id
    f="$KDIR/$area.md"
    [ -f "$f" ] || die "no knowledge file for area '$area' ($f). Known areas: $(cd "$KDIR" && ls *.md 2>/dev/null | grep -v '^_' | sed 's/\.md$//' | paste -sd, -)"
    pfx=$(area_prefix "$area")
    id=$(next_id "$f" "$pfx")
    grep -qF '## Learned / seeded invariants' "$f" || printf '\n## Learned / seeded invariants\n' >> "$f"
    printf -- '- [INV-%s-%s] %s\n' "$pfx" "$id" "$text" >> "$f"
    printf 'learn: appended INV-%s-%s to %s\n' "$pfx" "$id" "$f" >&2
}

# --- batch accept from a curated candidates file ----------------------------
if [ -n "$CANDIDATES" ]; then
    [ -f "$CANDIDATES" ] || die "candidates file not found: $CANDIDATES"
    if [ -z "$AREA" ]; then
        base=$(basename "$CANDIDATES"); base="${base%.md}"; AREA="${base%.candidates}"
    fi
    n=0
    while IFS= read -r line; do
        case "$line" in
            "- "*) text="${line#- }" ;;
            "* "*) text="${line#\* }" ;;
            *)     continue ;;
        esac
        # drop any pre-existing [INV-...] id so it re-numbers into the target file;
        # keep the rest (rule + its own provenance) verbatim.
        text=$(printf '%s' "$text" | sed -E 's/^\[INV-[A-Z]+-[0-9]+\][[:space:]]*//')
        [ -n "$text" ] || continue
        append_bullet "$AREA" "$text"
        n=$((n + 1))
    done < "$CANDIDATES"
    printf 'learn: accepted %d invariant(s) from %s into %s.md\n' "$n" "$CANDIDATES" "$AREA" >&2
    exit 0
fi

# --- single-invariant harvest ------------------------------------------------
[ -n "$AREA" ]      || { usage >&2; die "missing --area"; }
[ -n "$INVARIANT" ] || { usage >&2; die "missing --invariant (or use --from-candidates)"; }

prov="learned"
[ -n "$FROM_PR" ] && prov="$prov vllm#${FROM_PR#\#}"
[ -n "$AUTHOR" ]  && prov="$prov by $AUTHOR"
append_bullet "$AREA" "$INVARIANT ($prov)"
