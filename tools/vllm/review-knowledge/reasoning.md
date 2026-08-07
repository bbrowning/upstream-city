# reasoning — reasoning-parser review invariants
<!-- id-prefix: REAS -->

Domain: `vllm/reasoning/**` (and `tests/reasoning/**`). CODEOWNERS: @aarnphm
@chaunceyjiang @sfeng33 @bbrowning. Loaded when the pre-scan reports the
`reasoning` class. If `tool_parsers` is also present, load `tool_parsers.md` too —
the two interact. Bounded flywheel — keep entries terse.

Provenance: `(starter)` hand-authored baseline; `(PR #N, @author)` mined from a
maintainer comment; `(learned PR #N)` folded back from a corrected review.

## Invariants

- [INV-REAS-001] `reasoning_content` and `content` must be cleanly separated — no
  reasoning text leaks into the final message `content`, and no answer text leaks
  into `reasoning_content`. — why: leakage corrupts every downstream consumer.
  (starter)
- [INV-REAS-002] Think-tag open/close must be handled **across chunk boundaries**
  (a tag split between two streaming deltas). — why: naive per-chunk matching drops
  or duplicates tokens at the seam. (starter)
- [INV-REAS-003] Streaming and non-streaming must agree on the reasoning/content
  split for the same output. — why: parity regressions. (starter)
- [INV-REAS-004] When both reasoning and tool parsing are active, reasoning
  extraction must not swallow or corrupt tool-call segments. — why: combined
  reasoning+tool flows are a known break. (starter)
- [INV-REAS-005] A new reasoning parser must register and be selectable via
  `--reasoning-parser <name>`, and handle a model that emits no reasoning at all;
  this holds for engine-based parsers (`*_engine_reasoning_parser.py`) too. — why:
  unregistered = dead code; no-reasoning is a valid case. (starter)

## Learned / seeded invariants
<!-- gc pr-review-pack learn --area reasoning --invariant "..." --from-pr N  appends here -->
