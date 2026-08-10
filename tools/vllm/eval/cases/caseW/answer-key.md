# Answer key — caseW (vllm#48846)

Ground truth for grading caseW ONLY. This is a genuinely-correct small fix that the
maintainer approved with test nits — but the PR then **grew** to fix sibling model
converters, which is the higher-signal call a strong reviewer should surface at this
pre-review head. Correct verdict is at least `approve_with_nits`; a reviewer who
raises the cross-model gap (a `major`/`minor` finding) is doing the best work.

## What the change does
`_minimax_m2_arg_converter` previously did `params[name] = match.group("value").strip()`,
which deletes leading/trailing whitespace from string argument values (corrupting e.g.
indented code or newline-terminated content passed to an exact-match edit tool). The fix
removes `.strip()` in both the complete-match and partial-match loops, keeping the value
verbatim (matching the glm47 converter). It adds a `TestParameterWhitespace` suite.

## The high-signal call: cross-model blast radius (gold)
The **same defect class** lives in the sibling arg converters:
- `vllm/parser/qwen3.py` — `_qwen3_arg_converter` does `value.strip()` at two sites
  (verifiable: `git show <base>:vllm/parser/qwen3.py | grep -n 'value.strip()'`).
- `vllm/tool_parsers/minicpm5xml_tool_parser.py` — the XML value path (the real PR
  extended the fix here too).

Fixing only minimax_m2 leaves the identical whitespace-corruption bug in other models.
The real PR was expanded to fix qwen3 + minicpm5xml. A reviewer who enumerates the
sibling converters and flags that they strip the same way — same bug, different model —
made the catch. (This is the parser "cross-model blast radius" reflex.)

## The nits the maintainer actually wrote (secondary)
- Prefer the E2E `_feed -> _collect_tool_calls` pattern (exercises the parser
  end-to-end, more representative) over the direct `_minimax_m2_arg_converter(...)`
  unit tests.
- `test_converter_plain_value_unchanged` is redundant — its behavior is already
  exercised by other tests; remove it.
- Add a short standalone comment/docstring describing the desired behavior
  ("parameter values must preserve surrounding whitespace") so future readers/agents
  aren't confused.

## Grading the gold catch (per review)
- **catch** — identifies that sibling arg converters (name qwen3 and/or minicpm5xml)
  have the same `.strip()` whitespace-corruption defect and that this fix is
  model-local while the bug is cross-model (bonus: greps/quotes `_qwen3_arg_converter`).
- **partial** — asks "do other models have this bug?" or notes the fix is scoped to one
  model without confirming a specific sibling; or catches only the test-quality nits
  (redundant test / prefer E2E pattern / missing behavior comment) without the
  cross-model point.
- **miss** — approves the fix as complete with no cross-model question and no test nit;
  or invents a false problem with the (correct) `.strip()` removal.
