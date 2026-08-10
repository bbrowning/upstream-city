# Candidate real-world cases (parser area)

Merged/closed vLLM parser PRs where **@bbrowning** or **@yzong-rh** reviewed or left
substantive feedback (mined 2026-08-08, ~last 3 months). These are the pool for growing the
eval suite: each is a real change where a maintainer we trust had (or likely had) meaningful
input, so reconstructing the pre-review state and re-running gives an honest test of whether
a review setup surfaces what the maintainer surfaced.

**Before using one:** confirm the reviewer actually gave changes-requested / meaningful
feedback (not just an approve), then reconstruct blind per README "Adding a case" (original
pre-review head, hide PR#/comments/merge). `#51391/#51238/#51364` are already caseX/Y/Z.

## Priority set (bugfixes in parser core / cross-model; high reconstruction value)
- **#48852** dropped streaming arguments (Jamba, InternLM2) — streaming tool-arg loss.
- **#48846** preserve whitespace in parameter values (MiniMax M2, Qwen3, MiniCPM5 XML) — cross-model; BOTH reviewers.
- **#47606** flush engine reasoning parser at reasoning→tool streaming boundary — combined flow.
- **#48262** Gemma4: classify channel-less output consistently streaming vs non-streaming — parity.
- **#48748** special tokens (EOS/BOS) leaking into reasoning content — leakage (bbrowning commented).
- **#46529** thread token IDs through non-streaming paths of the parser engine — token-id vs text.
- **#46246 / #46225** strip structural/special tokens in non-streaming engine parsing — leakage.
- **#44348** unstreamed tool-call args dropped in Responses API streaming — streaming; BOTH reviewers.
- **#44993** advance grammar across reasoning boundary (structured output / spec decode) — BOTH reviewers.
- **#43984** handle non-finite numbers in `coerce_to_schema_type` — value coercion.
- **#44955** `parallel_tool_calls: null` treated as false instead of default true — semantics.
- **#46159** fix U+FFFD leak at reasoning→content transition in engine parsers — boundary.

## Also mined (engine build-out / refactors — lower priority, some are large)
#48947 (Mistral unified engine parser), #47379/#47062 (Harmony non-terminal raw tail),
#47185/#46437/#45464/#45171/#45048 (Harmony refactors), #45915/#45701/#45413/#45588
(Streaming Parser Engine + GLM/MinimaxM2/Qwen3/Gemma4 ports), #45867/#45852/#45763/#45708
(Gemma4/Qwen3 fixes), #45657/#45560 (Harmony constrained), #45553 (Gemma4 truncation),
#44448 (tool_call_parser metric), #44017 (move unstreamed flush to parser), #42664
(normalize reasoning_content→reasoning), #42454 (real-world gpt-oss Harmony), #40855/#40059
(Olmo3 / HF tokenizer concurrency), #46875/#46314/#46183 (closed/commented).

## Regenerate the mining
```
gh search prs --repo vllm-project/vllm --merged --reviewed-by bbrowning --limit 100 \
  --sort created --order desc --json number,title,closedAt \
  | jq -r '.[] | select(.title|test("(?i)parser|tool.?call|reasoning|tool_use|\\bparse\\b|harmony"))'
# repeat with --reviewed-by yzong-rh, and --state closed --commenter <x>
```
