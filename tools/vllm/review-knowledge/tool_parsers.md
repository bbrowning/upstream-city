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
  registration decorator) and be selectable via `--tool-call-parser <name>` — this
  holds for engine-based parsers (`*_engine_tool_parser.py`) too. — why: an
  unregistered parser is dead code. (starter)
- [INV-TOOL-006] Tests must include a **partial-JSON streamed chunk sequence**, not
  only a full-message parse. — why: streaming boundaries are where parsers break.
  (starter)
- [INV-TOOL-007] Shared logic belongs in `abstract_tool_parser.py` / `utils.py`,
  or the newer Parser Engine (`vllm/parser/engine/`); prefer building a new parser
  on the engine (`*_engine_tool_parser.py`) over a standalone `ToolParser` subclass
  that re-implements streaming/structural-tag machinery. — why: divergent copies
  drift and rot. (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area tool_parsers --invariant "..." --from-pr N  appends here -->
- [INV-TOOL-008] Don't gate Harmony tool-call capture on an exact channel name (e.g. `commentary`), and keep channel handling consistent across every extraction path — why: real outputs vary (`comment` vs `commentary`), so a strict per-path channel check silently drops valid tool calls. (PR #42454, @bbrowning)
- [INV-TOOL-009] Treat tool parameter schemas as always nested under `properties`; don't add fallback handling for "flat" schemas (a params dict used directly as the properties map) — why: flat schemas don't exist in valid tool defs, so the fallback is dead code that can mis-parse. (PR #43140, @sfeng33)
- [INV-TOOL-010] Every tool parser must implement a correct `extract_tool_calls_streaming`, not only the non-streaming path — why: a missing or broken streaming path yields no/aborted tool calls and makes clients (e.g. Claude Code) hit "Tool use interrupted." (PR #50093, @chaunceyjiang)
- [INV-TOOL-011] Handle both tool shapes — ChatCompletion tools (nested `tool.function.name`) and Responses tools (flat `FunctionTool.name`, plus `NamespaceTool`) — instead of assuming the nested shape — why: accessing `tool.function.name` on a flat Responses tool raises AttributeError and crashes the exact required/named path once `supports_required_and_named=False` routes it there. (PR #46486, @sfeng33)
- [INV-TOOL-012] Apply structural-tag/grammar constraints to the tool-calling phase but not the reasoning phase — why: constraining reasoning can trap the model in a generation loop, while leaving tool calling unconstrained lets it degrade over long multi-turn conversations. (PR #45003, @chaunceyjiang)
- [INV-TOOL-013] Keep structural-tag construction that depends on reasoning state in the parser layer, not the tool parser — why: the tool parser lacks the reasoning kwargs needed to build the complete (reasoning + tool) grammar. (PR #45003, @sfeng33)
- [INV-TOOL-014] Build a model's structural tag completely and natively; never post-hoc monkey-patch a generated tag — why: patch-based tag construction is fragile and hides the real grammar. (PR #45560, @chaunceyjiang)
- [INV-TOOL-015] Build new tool parsers on the new Parser Engine rather than as standalone `ToolParser` subclasses — why: standalone parsers miss shared streaming/structural-tag machinery and re-introduce bugs already solved there. (PR #50093, @chaunceyjiang)
- [INV-TOOL-016] Ground value coercion (e.g. the accepted boolean literals) in the model's official tool-calling guide instead of an invented alias set — why: over-accepting spellings the model never emits mis-coerces arguments. (PR #43006, @sfeng33)
