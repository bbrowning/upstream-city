# Answer key — caseTerminalLabelReuse

This case reviews the feature branch after it merged a newer `main`, which made the
Inkling grammar reachable alongside the new global reasoning-marker bypass, but before
the corrective commit `b3258f1b73`.

## Gold finding

`StreamingParserEngine._on_terminal` bypasses transitions whenever
`skip_reasoning_parsing` is set and the terminal label is `THINK_START` or `THINK_END`.
That assumes those labels identify reasoning-only delimiters.

Inkling disproves the assumption:

- it maps `<|end_message|>` to `THINK_END`;
- the same terminal has transitions from `CONTENT`, `REASONING`, `MESSAGE_HEADER`, and
  `TOOL_ARGS`;
- from `TOOL_ARGS`, its normal transition emits `TOOL_CALL_END` and returns to `CONTENT`.

When Inkling is configured as a tool parser without a reasoning parser, the serving
layer enables `skip_reasoning_parsing`. The new early return then emits the delimiter
according to the unchanged state rather than applying the Inkling transition. Ordinary
closers can leak into content, and a tool closer no longer ends the call or returns the
engine to `CONTENT`; subsequent content or tool blocks can be swallowed as arguments.

The correct review action is `request_changes`. The implementation need not use one
specific mechanism, but the bypass must be transition- or config-aware rather than
assuming the terminal label is a semantic guarantee. Coverage should include tool-only
Inkling content, tool-then-content, and consecutive tool blocks across streaming and
non-streaming paths.

## Grading

- **catch** — identifies Inkling's shared `THINK_END` use and the skipped state-specific
  transition, with a concrete leak or unterminated-tool failure.
- **partial** — questions whether the labels are reasoning-exclusive or asks for an
  audit of all transitions, but does not establish the Inkling failure.
- **miss** — approves the global label-based bypass, or notices shared labels but
  concludes they are safe without tracing their transitions.

## Ground truth

The subsequent commit `b3258f1b73` fixed this exact defect by deriving bypassable
markers from the transition table and added tool-only Inkling regressions. Do not expose
that commit to a blind review arm.
