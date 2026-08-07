# openai_frontend — OpenAI-compatible serving review invariants
<!-- id-prefix: OAI -->

Domain: `vllm/entrypoints/openai/**` (serving chat/completions/responses, protocol,
API server). CODEOWNERS: @aarnphm @chaunceyjiang @DarkLight1337 @russellb (plus
finer owners: `chat_utils.py`/`llm.py` @DarkLight1337, `entrypoints/*.py` @njhill).
Loaded when the pre-scan reports the `openai_frontend` class. Bounded flywheel —
keep entries terse.

Provenance: `(starter)` hand-authored baseline; `(PR #N, @author)` mined from a
maintainer comment; `(learned PR #N)` folded back from a corrected review.

## Invariants

- [INV-OAI-001] Request/response schemas must stay faithful to the OpenAI spec —
  field names, types, required/optional. Do **not** overload OpenAI protocol models
  to carry non-OpenAI-API fields; factor shared code out instead. — why: protocol
  drift breaks OpenAI-compatible clients. (starter)
- [INV-OAI-002] `finish_reason` must be correct (`stop`/`length`/`tool_calls`/…)
  and consistent between streaming and non-streaming. — why: clients branch on it.
  (starter)
- [INV-OAI-003] SSE streaming shape must be well-formed — each chunk a valid
  `data:` event, terminal `[DONE]`, `usage` emitted where the spec/flags require.
  — why: malformed SSE breaks streaming clients. (starter)
- [INV-OAI-004] Usage token counts (prompt/completion/total) must be internally
  consistent and reflect the actual generation (total = prompt + completion). — why:
  clients meter cost/limits on them. (Presence/where-required is covered by
  INV-OAI-003.) (starter)
- [INV-OAI-005] Changes to `serving_chat`/`serving_completion`/`responses` request
  and response fields must be backward compatible (additive). — why: public HTTP
  API stability. (starter)
- [INV-OAI-006] Errors must map to the correct HTTP status and the OpenAI error
  body shape. — why: clients handle failures by status + shape. (starter)
- [INV-OAI-007] New endpoints/handlers must respect existing auth/middleware and
  not bypass request validation. — why: auth/validation regressions are security
  bugs. (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area openai_frontend --invariant "..." --from-pr N  appends here -->
- [INV-OAI-008] Don't mix threading and asyncio in the OpenAI server entrypoints; run background work as an asyncio task (e.g. under uvloop, as api_server does) instead of a background thread — why: mixing the two models is an antipattern that yields fragile shutdown and error handling. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-009] Raise `VLLMValidationError` (not bare `ValueError`) for request-field validation, and set `parameter` to the most specific offending field using dotted paths (e.g. `tool_choice.function.name`); omit `parameter` when the error spans multiple fields — why: gives clients a precise, machine-usable pointer to the bad field. (PR #36254, @DarkLight1337)
- [INV-OAI-010] Don't wrap request handlers in local try/except that convert `ValueError`/`ValidationError` into an error response; rely on the global `exception_handler`, which calls `create_error_response` and returns the correct HTTP code — why: repeating this try-except per endpoint duplicated logic and made the code harder to read. (PR #43016, @DarkLight1337)
- [INV-OAI-011] Don't run validation or serialization work (e.g. an eager msgpack encode) in a cleanup wrapper or path that also executes on successful requests — why: it adds overhead to every request, not just failing ones. (PR #43016, @DarkLight1337)
- [INV-OAI-012] Keep the OpenAI protocol schemas independent of other APIs (e.g. Cohere); factor shared logic into common helpers that accept both protocols rather than expanding OpenAI request/response classes to cover another API — why: prevents OpenAI API changes from unexpectedly breaking the other API. (PR #47189, @DarkLight1337)
- [INV-OAI-013] Use `logger.warning_once` (not `logger.warning`) for warnings on the per-request serving path — why: a plain warning spams the logs on every request. (PR #43606, @DarkLight1337)
- [INV-OAI-014] A test must drive the real serving/production code path, not a local helper that manually calls the internal function under test — why: a helper-only test doesn't prove the production loop is actually wired to call that function. (PR #42683, @AndreasKaratzas)
- [INV-OAI-015] Don't hardcode local filesystem paths in entrypoint tests, and be wary of mock-heavy entrypoint tests that pass without exercising the real serving path — why: hardcoded paths break portability and mock-only tests give false coverage. (PR #44226, @DarkLight1337)
- [INV-OAI-016] Give new request/response protocol fields explicit `Field(description=...)` docstrings — why: undocumented public API fields ship with no generated reference docs. (PR #45458, @DarkLight1337)
- [INV-OAI-017] Reuse existing CLI arguments/config (e.g. `--shutdown-timeout`) instead of inventing parallel options for the same concept — why: duplicate knobs drift apart and confuse operators. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-018] Follow uvicorn conventions in server code: store shared state/objects on `app.state.*`, and stop a server task with `server.should_exit = True; await server_task` (setting the stop event from a done_callback) rather than managing another task's lifecycle inside a request coroutine — why: bespoke shutdown handling is bug-prone and forces needless null-checks. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-019] Don't rely on an HTTP `/health` probe to determine process liveness; use a process-level check — why: a hung server can return 500 while its process keeps running, so the probe misses hung-but-alive processes. (PR #40841, @robertgshaw2-redhat)
- [INV-OAI-020] Make `engine_client` optional (accept `None`) in tokenization/render serving paths so endpoint plugins can opt out under CPU-only deployment — why: CPU-only/render deployments have no engine and shouldn't be forced to attach one. (PR #47454, @noooop)
- [INV-OAI-021] When a validator or default is duplicated across parallel request-protocol classes (chat vs engine vs completion vs speech_to_text), apply the change to every copy — why: parallel request schemas silently diverge otherwise. (PR #48252, @DarkLight1337)
- [INV-OAI-022] Introduce a clearly-named new parameter rather than overloading an existing one with misleading semantics (e.g. `return_prompt_text`/`return_inputs` instead of repurposing an existing flag) — why: overloaded params confuse the public API contract. (PR #42052, @DarkLight1337)
- [INV-OAI-023] Normalize sentinel parameter values (e.g. `-1`) to preserve prior semantics when changing a parameter's handling — why: silently changing sentinel behavior breaks backward compatibility. (PR #43402, @DarkLight1337)
