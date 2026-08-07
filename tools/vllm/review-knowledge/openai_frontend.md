# openai_frontend — OpenAI-compatible serving review invariants
<!-- id-prefix: OAI -->

Domain: `vllm/entrypoints/openai/**` (chat/completions/responses, protocol, API server).
Loaded when the pre-scan reports the `openai_frontend` class. CODEOWNERS: @aarnphm
@chaunceyjiang @DarkLight1337 @russellb (finer: `chat_utils.py`/`llm.py` @DarkLight1337,
`entrypoints/*.py` @njhill).

Shape: `[ID] rule — why: failure it prevents (provenance)`; the rule states *what* to
check, not how. Provenance: `(starter)` · `(PR #N, @author)` mined · `(learned #N)`
folded back.

## Invariants

- [INV-OAI-001] Keep request/response schemas faithful to the OpenAI spec (names, types,
  required/optional); don't overload OpenAI models with non-OpenAI fields — factor shared
  code out. — why: protocol drift breaks OpenAI-compatible clients. (starter)
- [INV-OAI-002] `finish_reason` must be correct (`stop`/`length`/`tool_calls`/…) and
  consistent streaming vs non-streaming. — why: clients branch on it. (starter)
- [INV-OAI-003] SSE stream must be well-formed — each chunk a valid `data:` event,
  terminal `[DONE]`, `usage` where spec/flags require. — why: malformed SSE breaks
  streaming clients. (starter)
- [INV-OAI-004] Usage counts must be internally consistent (total = prompt + completion)
  and reflect the real generation. — why: clients meter cost/limits on them. (Presence →
  INV-OAI-003.) (starter)
- [INV-OAI-005] Changes to `serving_chat`/`serving_completion`/`responses`
  request/response fields must be backward compatible (additive). — why: public HTTP API
  stability. (starter)
- [INV-OAI-006] Map errors to the correct HTTP status and the OpenAI error-body shape. —
  why: clients handle failures by status + shape. (starter)
- [INV-OAI-007] New endpoints/handlers must respect existing auth/middleware and not
  bypass request validation. — why: auth/validation regressions are security bugs.
  (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area openai_frontend --invariant "..." --from-pr N  appends here -->
- [INV-OAI-008] Don't mix threading and asyncio in the OpenAI entrypoints; run background work as an asyncio task (e.g. under uvloop). — why: mixing the two models yields fragile shutdown/error handling. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-009] Raise `VLLMValidationError` (not bare `ValueError`) for request-field validation, and set `parameter` to the specific field via dotted path (e.g. `tool_choice.function.name`); omit it when the error spans fields. — why: gives clients a precise, machine-usable pointer. (PR #36254, @DarkLight1337)
- [INV-OAI-010] Don't wrap handlers in local try/except converting `ValueError`/`ValidationError` to responses; rely on the global `exception_handler`. — why: per-endpoint duplication. (PR #43016, @DarkLight1337)
- [INV-OAI-011] Don't run validation/serialization work (e.g. eager msgpack encode) in a path that also runs on success. — why: adds overhead to every request, not just failures. (PR #43016, @DarkLight1337)
- [INV-OAI-012] Keep OpenAI protocol schemas independent of other APIs (e.g. Cohere); factor shared logic into helpers accepting both. — why: prevents OpenAI changes from breaking the other API. (PR #47189, @DarkLight1337)
- [INV-OAI-013] Use `logger.warning_once`, not `logger.warning`, on the per-request path. — why: a plain warning spams logs every request. (PR #43606, @DarkLight1337)
- [INV-OAI-014] A test must drive the real serving code path, not a local helper that calls the internal function directly. — why: helper-only tests don't prove the production loop is wired to call it. (PR #42683, @AndreasKaratzas)
- [INV-OAI-015] Don't hardcode local filesystem paths in entrypoint tests; distrust mock-heavy tests that pass without the real serving path. — why: broken portability + false coverage. (PR #44226, @DarkLight1337)
- [INV-OAI-016] Give new request/response protocol fields explicit `Field(description=...)`. — why: undocumented public fields ship with no generated reference docs. (PR #45458, @DarkLight1337)
- [INV-OAI-017] Reuse existing CLI args/config (e.g. `--shutdown-timeout`) instead of parallel options for the same concept. — why: duplicate knobs drift apart and confuse operators. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-018] Follow uvicorn conventions: shared state on `app.state.*`; stop a server task via `server.should_exit = True; await server_task`, not by managing its lifecycle inside a request coroutine. — why: bespoke shutdown is bug-prone. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-019] Don't use an HTTP `/health` probe for process liveness; use a process-level check. — why: a hung server returns 500 while its process keeps running, so the probe misses it. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-020] Make `engine_client` optional (accept `None`) in tokenization/render serving paths so plugins can opt out CPU-only. — why: CPU-only/render deployments have no engine. (PR #47454, @noooop)
- [INV-OAI-021] When a validator/default is duplicated across parallel request classes (chat/engine/completion/speech_to_text), change every copy. — why: parallel schemas silently diverge. (PR #48252, @DarkLight1337)
- [INV-OAI-022] Add a clearly-named new parameter rather than overloading an existing one with misleading semantics (e.g. `return_prompt_text`/`return_inputs`). — why: overloaded params confuse the public API contract. (PR #42052, @DarkLight1337)
- [INV-OAI-023] Normalize sentinel values (e.g. `-1`) to preserve prior semantics when changing a parameter's handling. — why: silently changing sentinel behavior breaks backward compatibility. (PR #43402, @DarkLight1337)
