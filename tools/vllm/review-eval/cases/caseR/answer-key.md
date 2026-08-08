# Answer key — caseR (vllm#47606, gold)

Ground truth for grading caseR ONLY. In reality this pre-review head was **not**
accepted as-is: @bbrowning left substantive review comments on
`vllm/parser/abstract_parser.py` and the change was reworked before merge (the fix
approach was changed and real-model test coverage was added). Correct call is
`request_changes` (or at minimum a `major` finding), on grounds of a
multi-token-character correctness risk **plus** unrealistic test coverage.

## What the change does
`DelegatingParser.parse_delta` handles the reasoning→tool transition. This diff adds
a recovery path for the case where the **reasoning parser is engine-based**
(`engine_based_streaming = True`) but the **tool parser is NOT engine-based** (the
`else` branch). When the engine confirms reasoning end without emitting the trailing
text as content, it recovers that text with:

```python
if not current_text and current_token_ids:
    current_text = self.model_tokenizer.decode(current_token_ids)
delta_text = current_text
```

It adds one test, `test_parse_delta_engine_reasoning_tool_batched_boundary`, using a
locally-defined `_FakeEngineReasoningParser` fixture.

## Why it's wrong (the lesson)
1. **Not multi-token-character safe.** `current_token_ids` is the post-marker content
   slice (`extract_content_ids(delta_token_ids)`) for *this* delta. Decoding an
   arbitrary token-id slice on its own has no holdback for incomplete multi-token
   sequences: a character (emoji, many CJK, combining forms) whose bytes span a token
   boundary decodes to `U+FFFD`/mojibake or splits wrong. The sibling `if
   self._engine_based:` branch just above does it correctly — it flushes through
   `reasoning_parser.finish_streaming()` and uses `flush_delta.content` to get proper
   `current_text`. The fix should mirror that (flush via the reasoning parser), not
   re-`decode()` raw ids. (Bonus: decoding the accumulated window per delta is also
   not strictly incremental.)
2. **Test doesn't match real model output.** The only coverage is a fabricated
   `_FakeEngineReasoningParser`, not a real engine-based reasoning parser (e.g. qwen3)
   combined with a real non-engine tool parser (e.g. hermes). Mixed engine/non-engine
   reasoning+tool flows are a known break; a green test built on a hand-rolled fake can
   pass while the real path (multi-token chars, real transition timing) is still
   broken. Demand a real-model regression test for the qwen3-reasoning + hermes-tool
   combination.

## Grading the gold catch (per review)
- **catch** — flags the `decode(current_token_ids)` recovery as not multi-token-char
  safe / missing holdback (or that it should flush via the reasoning parser's
  `finish_streaming`/`flush_delta.content` like the engine branch), **and/or**
  identifies that the fabricated fixture doesn't exercise the real mixed
  engine/non-engine flow and demands real-model coverage. Bonus: names the
  qwen3+hermes combination or the parity with the `if self._engine_based` branch.
- **partial** — raises the combined reasoning+tool flow as risky, or notes the test is
  thin/fabricated, but does not tie it to the multi-token decode defect and does not
  demand real coverage; or flags only one of the two prongs weakly.
- **miss** — treats the fix as correct/local; leans on the passing fabricated test;
  `approve`/`approve_with_nits` without raising the decode safety or coverage-realism
  concern.
