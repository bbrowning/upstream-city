## Symptom
With `--tool-call-parser qwen3_xml` and **no reasoning parser configured**, the
`</think>` tag emitted by the model is consumed by the parser and never reaches the
client. With no reasoning parser there is also no `reasoning_content` field, so the
reasoning text is silently concatenated into `content` ahead of the answer, with the
only boundary marker removed. A chat client cannot tell deliberation from the final
answer. `finish_reason` is `stop` (this is not truncation).

The model's chat template opens `<think>\n` in the generation prompt, so every reply
begins inside a think block and closes it with `</think>` before answering — that
closing tag is the client's only signal, and it is exactly what goes missing.

## Environment
```
vLLM version : 0.26.0
Model        : Qwen/Qwen3.6-27B  (stock, apache-2.0; config model_type=qwen3_5)
GPU          : 8x A100-40GB
```
Server command (note: **no `--reasoning-parser`**):
```bash
vllm serve Qwen/Qwen3.6-27B --enable-auto-tool-choice --tool-call-parser qwen3_xml \
  --max-model-len 262144 --tensor-parallel-size 8 --enforce-eager
```

## Reproduction (abridged)
Send the same prompt two ways — `/v1/chat/completions` (template renders the prompt,
output passes the tool-call parser) vs `/v1/completions` (identical rendered prompt
string, no parser). Rendered generation prompt, byte-identical in both:
`'<|im_start|>user\nWhat is 17*23?<|im_end|>\n<|im_start|>assistant\n<think>\n'`

```
A chat/completions  ->  0/5 contained '</think>'   reasoning_content=None   (deliberation+answer merged in content)
B completions        ->  5/5 contained '</think>'
```
`finish_reason=stop` in all ten samples.

## Where it happens (reporter's pointer)
`qwen3_xml` resolves to the combined engine in `vllm/parser/qwen3.py`, which owns the
reasoning phase as well as tool calls: it starts in `ParserState.REASONING` (when
thinking) and its `THINK_END` transition emits `REASONING_END` without re-emitting the
literal tag; a second `(ParserState.CONTENT, "THINK_END")` transition drops a duplicate
`</think>` silently. `Qwen3Parser.__init__` derives `thinking` from
`chat_template_kwargs.get("enable_thinking", True)` only — nothing consults whether a
reasoning parser is actually attached.

## Core questions to answer
1. Trace the exact mechanism: with `--tool-call-parser qwen3_xml` and **no** reasoning
   parser, where and why is `</think>` dropped in the combined parser state machine
   (streaming and non-streaming)? Name the states/transitions and the code path that
   puts the engine there.
2. The report's premise is that the model **reliably emits `</think>`** because its chat
   template opens a `<think>` block every turn. Is that true for this checkpoint? This
   premise is **load-bearing**: the silent-merge symptom only occurs on *every* reply if
   the model actually closes a think block each turn.
3. Sketch a fix (do not implement).

## Deliverable
Report-only root-cause diagnosis + proposed solution(s). Do **not** implement a fix.
