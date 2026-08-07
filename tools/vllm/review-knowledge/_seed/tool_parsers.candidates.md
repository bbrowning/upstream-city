# tool_parsers — candidate invariants (review, prune, then accept)
#
# Accept the ones you trust:  gc pr-review-pack learn --from-candidates this-file.md
# (that assigns IDs and appends them to tool_parsers.md; delete any line you reject first)
#
# CURATED 2026-08-07 (Claude, rubric pass): 10 mined -> 9 accept, 1 reject.
# Reject bar for mined candidates is deliberately high (each has a real maintainer PR
# behind it); only process/doc rules and non-generalizable nits are dropped.

- Don't gate Harmony tool-call capture on an exact channel name (e.g. `commentary`), and keep channel handling consistent across every extraction path — why: real outputs vary (`comment` vs `commentary`), so a strict per-path channel check silently drops valid tool calls. (PR #42454, @bbrowning)
- Treat tool parameter schemas as always nested under `properties`; don't add fallback handling for "flat" schemas (a params dict used directly as the properties map) — why: flat schemas don't exist in valid tool defs, so the fallback is dead code that can mis-parse. (PR #43140, @sfeng33)
- Every tool parser must implement a correct `extract_tool_calls_streaming`, not only the non-streaming path — why: a missing or broken streaming path yields no/aborted tool calls and makes clients (e.g. Claude Code) hit "Tool use interrupted." (PR #50093, @chaunceyjiang)
- Handle both tool shapes — ChatCompletion tools (nested `tool.function.name`) and Responses tools (flat `FunctionTool.name`, plus `NamespaceTool`) — instead of assuming the nested shape — why: accessing `tool.function.name` on a flat Responses tool raises AttributeError and crashes the exact required/named path once `supports_required_and_named=False` routes it there. (PR #46486, @sfeng33)
- Apply structural-tag/grammar constraints to the tool-calling phase but not the reasoning phase — why: constraining reasoning can trap the model in a generation loop, while leaving tool calling unconstrained lets it degrade over long multi-turn conversations. (PR #45003, @chaunceyjiang)
- Keep structural-tag construction that depends on reasoning state in the parser layer, not the tool parser — why: the tool parser lacks the reasoning kwargs needed to build the complete (reasoning + tool) grammar. (PR #45003, @sfeng33)
- Build a model's structural tag completely and natively; never post-hoc monkey-patch a generated tag — why: patch-based tag construction is fragile and hides the real grammar. (PR #45560, @chaunceyjiang)
- Build new tool parsers on the new Parser Engine rather than as standalone `ToolParser` subclasses — why: standalone parsers miss shared streaming/structural-tag machinery and re-introduce bugs already solved there. (PR #50093, @chaunceyjiang)
- Ground value coercion (e.g. the accepted boolean literals) in the model's official tool-calling guide instead of an invented alias set — why: over-accepting spellings the model never emits mis-coerces arguments. (PR #43006, @sfeng33)

# REJECTED 2026-08-07:
# - Update `docs/features/tool_calling.md` whenever you change tool-calling behavior (PR #45600, @chaunceyjiang)
#   reason: process/doc rule, not a code invariant. A reviewer flags missing docs from
#   first principles; this is not durable domain knowledge. (matches flywheel follow-up #5)
