## Symptom
Sending a `/v1/chat/completions` request with **structured outputs** to an
**inkling-small** model returns a 500 Internal Server Error. The engine core
reports the grammar rejecting a token and terminates the request.

## Observed log
```
(APIServer pid=9419) INFO:     127.0.0.1:37932 - "POST /v1/chat/completions HTTP/1.1" 200 OK
(EngineCore pid=10458) ERROR 08-09 09:58:19 [scheduler.py:1841] Unexpected: grammar rejected tokens [200028] for request chatcmpl-8da6fc665494abe1-b5b27872. Terminating request.
(APIServer pid=9419) ERROR 08-09 09:58:19 [serving.py:175] Request chatcmpl-8da6fc665494abe1 failed with an internal error during generation
(APIServer pid=9419) INFO:     127.0.0.1:37932 - "POST /v1/chat/completions HTTP/1.1" 500 Internal Server Error
```

## Core questions to answer
1. What is grammar/vocab token **200028** for the inkling-small tokenizer
   (special token? control/EOS/channel marker? added/reserved token?).
2. Why is the structured-output grammar (xgrammar / guidance backend) **rejecting**
   it at `scheduler.py:1841` (`grammar.accept_tokens` returns False)?
3. Is the model emitting a special/control token that the grammar's token bitmask
   never allowed — e.g. a reasoning/channel marker, or a token outside the grammar's
   vocab view / above the compiled vocab_size — and how does that interact with
   `should_advance` / `trim_reasoning_for_advance` in the scheduler?

## Deliverable
Report-only: root-cause diagnosis + proposed solution(s). **Do NOT implement a fix.**

## Environment
vLLM main @ 41e7746b8 (V1 engine, structured outputs). Model: inkling-small
(HuggingFace repo: `thinkingmachines/Inkling-Small-NVFP4`).
