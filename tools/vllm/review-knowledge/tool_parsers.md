# tool_parsers — tool-call parser review invariants
<!-- id-prefix: TOOL -->

Domain: `vllm/tool_parsers/**` (and `tests/tool_parsers/**`, `tests/tool_use/**`).
CODEOWNERS: @aarnphm @chaunceyjiang @sfeng33 @bbrowning. Loaded when the pre-scan
reports the `tool_parsers` class. Bounded flywheel — keep entries terse; append
harvested/seeded rules under "Learned / seeded".

Provenance: `(starter)` hand-authored baseline; `(PR #N, @author)` mined from a
maintainer comment; `(learned PR #N)` folded back from a corrected review.

## Invariants

- [INV-TOOL-001] Streaming and non-streaming paths must yield **identical** final
  tool calls — same names, argument strings, count, and order. — why: the SSE delta
  path silently truncating/reordering arguments is the classic parser regression.
  (starter)
- [INV-TOOL-002] Malformed or interrupted model output must degrade gracefully —
  no exception escapes the parser; fall back to treating the text as content. — why:
  models emit incomplete/invalid JSON mid-stream. (starter)
- [INV-TOOL-003] `arguments` must be emitted as a JSON **string** (per the OpenAI
  schema), never a dict/object. — why: OpenAI-compatible clients parse the string
  themselves; a dict breaks them. (starter)
- [INV-TOOL-004] A tool call's `id` must be stable across all of its streaming
  deltas, and `index` values monotonic and contiguous. — why: clients key on
  id/index to reassemble calls from deltas. (starter)
- [INV-TOOL-005] A new parser must register with `ToolParserManager` (the
  registration decorator) and be selectable via `--tool-call-parser <name>`. — why:
  an unregistered parser is dead code. (starter)
- [INV-TOOL-006] Tests must include a **partial-JSON streamed chunk sequence**, not
  only a full-message parse. — why: streaming boundaries are where parsers break.
  (starter)
- [INV-TOOL-007] Shared logic belongs in `abstract_tool_parser.py` / `utils.py`;
  a new per-model parser should not copy-paste accumulation logic. — why:
  divergent copies drift and rot. (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area tool_parsers --invariant "..." --from-pr N  appends here -->
