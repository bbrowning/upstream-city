# parsers — tool-call & reasoning parser review invariants
<!-- id-prefix: PARSE -->

Unified parser-subsystem domain: `vllm/tool_parsers/**`, `vllm/reasoning/**`,
`vllm/parser/**` (shared **Parser Engine**), `vllm/entrypoints/openai/parser/**`
(serving-side), + their tests. Loaded when the pre-scan reports any parser path (see
`_manifest.md`; a change under `entrypoints/openai/parser/` also loads `openai_frontend.md`).

**Why unified:** tool-call and reasoning parsers INTERACT (combined flows are a known
break — INV-REAS-004, INV-TOOL-012/013) and both build on the shared Parser Engine.
CODEOWNERS (`/vllm/{tool_parsers,reasoning,parser}` + tests): @aarnphm @chaunceyjiang
@sfeng33 @bbrowning.

Shape: `[ID] rule — why: failure it prevents (provenance)`; the rule states *what* to
check, not how. **IDs are stable citation handles** — `INV-TOOL-*`/`INV-REAS-*` kept
verbatim (never renumbered); new ones are `INV-PARSE-*`. Provenance: `(starter)` ·
`(vllm#N, @author)` mined · `(learned vllm#N)` folded back.

## Invariants

### Tool-call parsers

- [INV-TOOL-001] Streaming and non-streaming paths must yield **identical** final tool
  calls — same names, argument strings, count, order. — why: the SSE delta path
  truncating/reordering args is the classic parser regression. (starter)
- [INV-TOOL-002] Malformed/interrupted output must degrade gracefully — no exception
  escapes the parser; fall back to treating text as content. — why: models emit
  incomplete JSON mid-stream. (starter)
- [INV-TOOL-003] Emit `arguments` as a JSON **string** (OpenAI schema), never a dict.
  — why: OpenAI-compatible clients parse the string themselves; a dict breaks them.
  (starter)
- [INV-TOOL-004] A tool call's `id` must be stable across its streaming deltas, `index`
  monotonic and contiguous. — why: clients key on id/index to reassemble calls.
  (starter)
- [INV-TOOL-005] A new parser must register with `ToolParserManager` and be selectable
  via `--tool-call-parser <name>` (engine-based `*_engine_tool_parser.py` too). — why:
  an unregistered parser is dead code. (starter)
- [INV-TOOL-006] Tests must include a partial-JSON streamed chunk sequence, not only a
  full-message parse. — why: streaming boundaries are where parsers break. (starter)
- [INV-TOOL-007] Put shared logic in `abstract_tool_parser.py`/`utils.py` or the Parser
  Engine; build new parsers on the engine (`*_engine_tool_parser.py`), not standalone
  `ToolParser` subclasses re-implementing streaming/structural-tag machinery. — why:
  divergent copies drift and rot. (starter)

### Reasoning parsers

- [INV-REAS-001] `reasoning_content` and `content` must stay cleanly separated — neither
  leaks into the other. — why: leakage corrupts every downstream consumer. (starter)
- [INV-REAS-002] Handle think-tag open/close **across chunk boundaries** (a tag split
  between deltas). — why: per-chunk matching drops/duplicates tokens at the seam.
  (starter)
- [INV-REAS-003] Streaming and non-streaming must agree on the reasoning/content split.
  — why: parity regressions. (starter)
- [INV-REAS-004] With reasoning and tool parsing both active, reasoning extraction must
  not swallow/corrupt tool-call segments. — why: combined reasoning+tool flows are a
  known break. (starter)
- [INV-REAS-005] A new reasoning parser must register, be selectable via
  `--reasoning-parser <name>`, and handle a model emitting no reasoning (engine-based
  `*_engine_reasoning_parser.py` too). — why: unregistered = dead code; no-reasoning is
  valid. (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area parsers --invariant "..." --from-pr N  appends here -->
- [INV-TOOL-008] Don't gate Harmony tool-call capture on an exact channel name (e.g. `commentary`); keep channel handling consistent across extraction paths. — why: real outputs vary (`comment` vs `commentary`), so a strict per-path check drops valid calls. (vllm#42454, @bbrowning)
- [INV-TOOL-009] Treat tool parameter schemas as always nested under `properties`; don't add "flat"-schema fallbacks. — why: flat schemas don't exist in valid tool defs, so the fallback is dead code that can mis-parse. (vllm#43140, @sfeng33)
- [INV-TOOL-010] Every tool parser must implement a correct `extract_tool_calls_streaming`, not only the non-streaming path. — why: a broken streaming path yields no/aborted calls → clients hit "Tool use interrupted." (vllm#50093, @chaunceyjiang)
- [INV-TOOL-011] Handle both tool shapes — ChatCompletion (nested `tool.function.name`) and Responses (flat `FunctionTool.name`, plus `NamespaceTool`). — why: assuming nested raises AttributeError and crashes the required/named path when `supports_required_and_named=False` routes a flat tool there. (vllm#46486, @sfeng33)
- [INV-TOOL-012] Constrain the tool-calling phase with structural-tag/grammar, not the reasoning phase. — why: constraining reasoning can trap the model in a loop; unconstrained tool calling degrades over long conversations. (vllm#45003, @chaunceyjiang)
- [INV-TOOL-013] Keep reasoning-state-dependent structural-tag construction in the parser layer, not the tool parser. — why: the tool parser lacks the reasoning kwargs to build the full grammar. (vllm#45003, @sfeng33)
- [INV-TOOL-014] Build a model's structural tag natively and completely; never post-hoc monkey-patch a generated tag. — why: patch-based construction is fragile and hides the real grammar. (vllm#45560, @chaunceyjiang)
- [INV-TOOL-015] Build new tool parsers on the Parser Engine, not standalone `ToolParser` subclasses. — why: standalone parsers miss shared streaming/structural-tag machinery and re-introduce solved bugs. (vllm#50093, @chaunceyjiang)
- [INV-TOOL-016] Ground value coercion (e.g. accepted boolean literals) in the model's official tool-calling guide, not an invented alias set. — why: over-accepting spellings the model never emits mis-coerces arguments. (vllm#43006, @sfeng33)
- [INV-REAS-006] Represent absent reasoning as `None`, not `""`. — why: consumers/tests that distinguish "no reasoning" from "empty" break when conflated. (vllm#45701, @bbrowning)
