# Answer key — feature/design lifecycle case

A strong design must treat the parser engine as shared across models rather than a
single-model hook, keep streaming work incremental, and define observable coverage for
at least one real model override plus streaming/non-streaming parity. It should load
`base.md` and `parser.md`; loading `openai-frontend.md` is context pollution because no
candidate path activates it. Grade the plan, test obligations, and `persona_traces`.
