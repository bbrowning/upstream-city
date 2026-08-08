# STATUS: ACCEPTED 2026-08-07 -> openai_frontend.md as INV-OAI-008..023 (16 invariants). Re-running learn on this file is a safe no-op.
# openai_frontend — candidate invariants (review, prune, then accept)
#
# Accept the ones you trust:  gc pr-review-pack learn --from-candidates this-file.md
# (that assigns IDs and appends them to openai_frontend.md; delete any line you reject first)
#
# CURATED 2026-08-07 (Claude, rubric pass): 18 mined -> 16 accept (2 reworded), 2 reject.
# Reworded lines had a durable code invariant tangled with a process/rendering nit; the
# nit was stripped and the checkable core kept. Rejects are generic/style or doc-render
# minutiae the model already applies.

# [accepted] Don't mix threading and asyncio in the OpenAI server entrypoints; run background work as an asyncio task (e.g. under uvloop, as api_server does) instead of a background thread — why: mixing the two models is an antipattern that yields fragile shutdown and error handling. (vllm#40841, @robertgshaw2-redhat)
# [accepted] Raise `VLLMValidationError` (not bare `ValueError`) for request-field validation, and set `parameter` to the most specific offending field using dotted paths (e.g. `tool_choice.function.name`); omit `parameter` when the error spans multiple fields — why: gives clients a precise, machine-usable pointer to the bad field. (vllm#36254, @DarkLight1337)
# [accepted] Don't wrap request handlers in local try/except that convert `ValueError`/`ValidationError` into an error response; rely on the global `exception_handler`, which calls `create_error_response` and returns the correct HTTP code — why: repeating this try-except per endpoint duplicated logic and made the code harder to read. (vllm#43016, @DarkLight1337)
# [accepted] Don't run validation or serialization work (e.g. an eager msgpack encode) in a cleanup wrapper or path that also executes on successful requests — why: it adds overhead to every request, not just failing ones. (vllm#43016, @DarkLight1337)
# [accepted] Keep the OpenAI protocol schemas independent of other APIs (e.g. Cohere); factor shared logic into common helpers that accept both protocols rather than expanding OpenAI request/response classes to cover another API — why: prevents OpenAI API changes from unexpectedly breaking the other API. (vllm#47189, @DarkLight1337)
# [accepted] Use `logger.warning_once` (not `logger.warning`) for warnings on the per-request serving path — why: a plain warning spams the logs on every request. (vllm#43606, @DarkLight1337)
# [accepted] A test must drive the real serving/production code path, not a local helper that manually calls the internal function under test — why: a helper-only test doesn't prove the production loop is actually wired to call that function. (vllm#42683, @AndreasKaratzas)
# [accepted] Don't hardcode local filesystem paths in entrypoint tests, and be wary of mock-heavy entrypoint tests that pass without exercising the real serving path — why: hardcoded paths break portability and mock-only tests give false coverage. (vllm#44226, @DarkLight1337)
# [accepted] Give new request/response protocol fields explicit `Field(description=...)` docstrings — why: undocumented public API fields ship with no generated reference docs. (vllm#45458, @DarkLight1337)
# [accepted] Reuse existing CLI arguments/config (e.g. `--shutdown-timeout`) instead of inventing parallel options for the same concept — why: duplicate knobs drift apart and confuse operators. (vllm#40841, @robertgshaw2-redhat)
# [accepted] Follow uvicorn conventions in server code: store shared state/objects on `app.state.*`, and stop a server task with `server.should_exit = True; await server_task` (setting the stop event from a done_callback) rather than managing another task's lifecycle inside a request coroutine — why: bespoke shutdown handling is bug-prone and forces needless null-checks. (vllm#40841, @robertgshaw2-redhat)
# [accepted] Don't rely on an HTTP `/health` probe to determine process liveness; use a process-level check — why: a hung server can return 500 while its process keeps running, so the probe misses hung-but-alive processes. (vllm#40841, @robertgshaw2-redhat)
# [accepted] Make `engine_client` optional (accept `None`) in tokenization/render serving paths so endpoint plugins can opt out under CPU-only deployment — why: CPU-only/render deployments have no engine and shouldn't be forced to attach one. (vllm#47454, @noooop)
# [accepted] When a validator or default is duplicated across parallel request-protocol classes (chat vs engine vs completion vs speech_to_text), apply the change to every copy — why: parallel request schemas silently diverge otherwise. (vllm#48252, @DarkLight1337)
# [accepted] Introduce a clearly-named new parameter rather than overloading an existing one with misleading semantics (e.g. `return_prompt_text`/`return_inputs` instead of repurposing an existing flag) — why: overloaded params confuse the public API contract. (vllm#42052, @DarkLight1337)
# [accepted] Normalize sentinel parameter values (e.g. `-1`) to preserve prior semantics when changing a parameter's handling — why: silently changing sentinel behavior breaks backward compatibility. (vllm#43402, @DarkLight1337)

# REJECTED / RESHAPED 2026-08-07:
# - Return an extensible dict keyed by name (e.g. modality) rather than hardcoding per-name fields (vllm#45458, @DarkLight1337)
#   reason: KEPT? No -> design-pattern preference, risks opinionated "use a dict" review noise;
#   not a defect the reviewer can assert. Borderline; dropped to keep the corpus high-signal.
# - Don't leave hardcoded numeric literals inline; extract them to named constants (vllm#40841, @robertgshaw2-redhat)
#   reason: generic code-style rule, not vLLM-specific; a strong reviewer already flags magic
#   numbers. Fails the counterfactual test (no marginal behavior change).
# - RESHAPED (nit stripped, core kept above): vllm#44226 originally also said "manually curate
#   AI-generated tests" (process rule); vllm#45458 originally also said "use single backticks"
#   (MkDocs render minutia). Both nits dropped; the checkable code invariants were kept.
