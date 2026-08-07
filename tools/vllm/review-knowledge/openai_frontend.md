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
- [INV-OAI-004] Usage accounting (prompt/completion/total tokens) must be correct
  and present where the spec requires it. — why: clients meter cost/limits on it.
  (starter)
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
