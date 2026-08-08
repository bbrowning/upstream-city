# Answer key — caseX (gold standard)

This is the ground truth for grading caseX ONLY. The change under review was, in reality,
NOT accepted as-is: it was substantially reworked before merge (the `abstract_parser.py`
edit was reverted; the engine logic was rewritten to preserve MiniMax multi-terminal
wrappers; ~330 lines of cross-model regression tests were added). So the correct call is
`request_changes` on grounds of cross-model risk + insufficient coverage.

## What the change actually does
1. `vllm/parser/engine/streaming_parser_engine.py` — modifies the **shared** streaming
   engine's *skip-mode* block-end handling: adds `_tool_end_terminals` (a frozenset built
   from **all** transitions carrying `EventType.TOOL_CALL_END`) plus a single boolean
   `_tool_call_passthrough_open`, changing when a block-end terminal is consumed vs
   forwarded while `skip_tool_parsing` is active.
2. `vllm/parser/abstract_parser.py` — modifies the **shared** `DelegatingParser`: for any
   `engine_based_streaming` tool parser, overrides `content = tool_call_info.content`.
3. `tests/parser/engine/test_inkling.py` — adds tests for **inkling only**.

## Why it's dangerous (the lesson)
Both (1) and (2) are **shared code paths used by every engine-backed model** — not
inkling-local. `_tool_end_terminals` spans all models' terminals, and a single boolean
passthrough flag cannot represent models with multiple/nested wrapper terminals (e.g.
**MiniMax multi-terminal wrappers**; also Qwen-, DeepSeek-, GLM-, Nemotron-style
grammars). The `content = tool_call_info.content` override changes content emission for
**all** engine-based tool parsers. Yet the PR ships regression coverage for **inkling
only**. NOTE: at this commit the *existing* other-model tests still PASS (the catching
tests did not exist yet) — so this cannot be caught by running existing tests going red;
it must be caught by **reasoning about shared-engine blast radius + demanding coverage**.

## Grading the gold catch (per review)
- **catch** — identifies that the change is to SHARED engine / shared DelegatingParser with
  cross-model impact, AND demands cross-model regression coverage / testing other
  engine-backed models before merge (bonus: names minimax/qwen/deepseek/glm/nemotron, or
  actually inspects/runs their tests; questions the `abstract_parser.py` content override;
  notes the single-boolean flag can't handle multi-terminal wrappers).
- **partial** — notes it touches shared engine OR that tests are inkling-only, but does not
  connect the two into a cross-model regression concern / does not demand broader coverage.
- **miss** — treats it as an inkling-local change; leans on the passing inkling test; no
  cross-model concern (e.g. `approve`/`approve_with_nits` without raising blast radius).
