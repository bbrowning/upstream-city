# parsers — tool-call & reasoning parser review invariants
<!-- id-prefix: PARSE -->

Unified domain for the parser subsystem: `vllm/tool_parsers/**`, `vllm/reasoning/**`,
`vllm/parser/**` (the shared **Parser Engine**), and `vllm/entrypoints/openai/parser/**`
(serving-side), plus tests (`tests/tool_parsers/**`, `tests/reasoning/**`,
`tests/parser/**`, `tests/tool_use/**`, `tests/entrypoints/tool_parsers/**`). Loaded when
the pre-scan reports any parser path (see `_manifest.md`).

**Why unified:** tool-call and reasoning parsers INTERACT (combined reasoning+tool flows
are a known break — see INV-REAS-004, INV-TOOL-012/013) and both now build on the shared
Parser Engine (`vllm/parser/engine/`), so engine invariants belong to neither alone.

CODEOWNERS (`/vllm/{tool_parsers,reasoning,parser}` + tests): @aarnphm @chaunceyjiang
@sfeng33 @bbrowning. (The serving-side `entrypoints/openai/parser` is owned by the
OpenAI-frontend set — @DarkLight1337 @russellb — and a change there also loads
`openai_frontend.md`.)

Provenance: `(starter)` hand-authored baseline; `(PR #N, @author)` mined from a
maintainer comment; `(learned PR #N)` folded back from a corrected review. **IDs are
stable citation handles:** tool-call invariants keep their `INV-TOOL-*` ids and reasoning
keep `INV-REAS-*` (never renumbered); invariants added after the 2026-08-07 unification
use `INV-PARSE-*`. Keep entries terse; append harvested/seeded rules under
"Learned / seeded".

## Invariants

### Tool-call parsers

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

### Reasoning parsers

- [INV-REAS-001] `reasoning_content` and `content` must be cleanly separated — no
  reasoning text leaks into the final message `content`, and no answer text leaks
  into `reasoning_content`. — why: leakage corrupts every downstream consumer.
  (starter)
- [INV-REAS-002] Think-tag open/close must be handled **across chunk boundaries**
  (a tag split between two streaming deltas). — why: naive per-chunk matching drops
  or duplicates tokens at the seam. (starter)
- [INV-REAS-003] Streaming and non-streaming must agree on the reasoning/content
  split for the same output. — why: parity regressions. (starter)
- [INV-REAS-004] When both reasoning and tool parsing are active, reasoning
  extraction must not swallow or corrupt tool-call segments. — why: combined
  reasoning+tool flows are a known break. (starter)
- [INV-REAS-005] A new reasoning parser must register and be selectable via
  `--reasoning-parser <name>`, and handle a model that emits no reasoning at all;
  this holds for engine-based parsers (`*_engine_reasoning_parser.py`) too. — why:
  unregistered = dead code; no-reasoning is a valid case. (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area parsers --invariant "..." --from-pr N  appends here -->
- [INV-TOOL-008] Don't gate Harmony tool-call capture on an exact channel name (e.g. `commentary`), and keep channel handling consistent across every extraction path — why: real outputs vary (`comment` vs `commentary`), so a strict per-path channel check silently drops valid tool calls. (PR #42454, @bbrowning)
- [INV-TOOL-009] Treat tool parameter schemas as always nested under `properties`; don't add fallback handling for "flat" schemas (a params dict used directly as the properties map) — why: flat schemas don't exist in valid tool defs, so the fallback is dead code that can mis-parse. (PR #43140, @sfeng33)
- [INV-TOOL-010] Every tool parser must implement a correct `extract_tool_calls_streaming`, not only the non-streaming path — why: a missing or broken streaming path yields no/aborted tool calls and makes clients (e.g. Claude Code) hit "Tool use interrupted." (PR #50093, @chaunceyjiang)
- [INV-TOOL-011] Handle both tool shapes — ChatCompletion tools (nested `tool.function.name`) and Responses tools (flat `FunctionTool.name`, plus `NamespaceTool`) — instead of assuming the nested shape — why: accessing `tool.function.name` on a flat Responses tool raises AttributeError and crashes the exact required/named path once `supports_required_and_named=False` routes it there. (PR #46486, @sfeng33)
- [INV-TOOL-012] Apply structural-tag/grammar constraints to the tool-calling phase but not the reasoning phase — why: constraining reasoning can trap the model in a generation loop, while leaving tool calling unconstrained lets it degrade over long multi-turn conversations. (PR #45003, @chaunceyjiang)
- [INV-TOOL-013] Keep structural-tag construction that depends on reasoning state in the parser layer, not the tool parser — why: the tool parser lacks the reasoning kwargs needed to build the complete (reasoning + tool) grammar. (PR #45003, @sfeng33)
- [INV-TOOL-014] Build a model's structural tag completely and natively; never post-hoc monkey-patch a generated tag — why: patch-based tag construction is fragile and hides the real grammar. (PR #45560, @chaunceyjiang)
- [INV-TOOL-015] Build new tool parsers on the new Parser Engine rather than as standalone `ToolParser` subclasses — why: standalone parsers miss shared streaming/structural-tag machinery and re-introduce bugs already solved there. (PR #50093, @chaunceyjiang)
- [INV-TOOL-016] Ground value coercion (e.g. the accepted boolean literals) in the model's official tool-calling guide instead of an invented alias set — why: over-accepting spellings the model never emits mis-coerces arguments. (PR #43006, @sfeng33)
- [INV-REAS-006] Represent absent reasoning as `None`, not the empty string `""` — why: consumers and tests that distinguish "no reasoning" from "empty reasoning" break when the parser conflates the two. (PR #45701, @bbrowning)
