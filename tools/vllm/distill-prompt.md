# Distillation spec — raw maintainer comments → candidate invariants

Input: `$GC_PR_KNOWLEDGE/_seed/candidates-raw.jsonl` — one JSON object per kept
maintainer inline review comment: `{domain, pr, url, author, assoc, path,
line, diff_hunk, body}`. Already filtered to CODEOWNER authors per domain (bots
dropped) by `mine-review-comments.sh`.

Task: for ONE domain at a time, distill the raw comments into **candidate
invariants** a human will review before they enter the live corpus. Write
`$GC_PR_KNOWLEDGE/_seed/<domain>.candidates.md`.

## Rules

1. **Keep only invariant-shaped, generalizable rules** — something that would apply
   to a *future* PR in this domain. A good invariant is a durable "always/never"
   about the domain's behavior, contract, or structure.
2. **Drop the noise**: chit-chat (`LGTM`, `thanks`, `done`), pure PR-specific
   requests (`rename this var`, `nit: typo`), questions, and anything that only made
   sense for that one diff. When unsure, drop it — a human is curating, and a short
   list of real rules beats a long list of maybes.
3. **Merge near-duplicates** across comments/PRs into one rule; list the strongest
   provenance.
4. **Phrase terse + imperative + grounded**: `<rule> — why: <the failure it
   prevents>`. Ground every rule in a real comment — do NOT invent invariants the
   comments don't support.
5. **Prefer** architectural/contract feedback and anything that reads like a blocking
   objection over stylistic remarks.
6. **Provenance**: end each bullet with `(PR #N, @author)` (the strongest source).

## Output format (one bullet per invariant; matches the live knowledge files)

```markdown
# <domain> — candidate invariants (review, prune, then accept)
#
# Accept the ones you trust:  gc pr-review-pack learn --from-candidates this-file.md
# (that assigns IDs and appends them to <domain>.md; delete any line you reject first)

- <terse rule> — why: <failure prevented>. (PR #N, @author)
- <terse rule> — why: <failure prevented>. (PR #N, @author)
```

Only `- ` bullet lines are accepted by `learn --from-candidates`; the header/comment
lines are ignored, so keep commentary on non-bullet lines.

## How to slice one domain from the raw file

```bash
jq -c 'select(.domain=="parsers")' "$GC_PR_KNOWLEDGE/_seed/candidates-raw.jsonl"
```
Read the `body` (the comment) with its `diff_hunk` (the code it was attached to) and
`path` for context; those three together tell you what the maintainer was asserting.
