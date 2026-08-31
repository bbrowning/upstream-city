# Persona — Paude base (cross-cutting, always loaded)

**Activates on:** every Paude lifecycle lane, layered under matched domain personas.

1. **Local orchestration state must tell the truth.** Status, artifact, branch, and
   revision fields are a state-machine contract. A successful-looking CLI line is not
   enough: verify the durable bead metadata and exact Git SHA agree.

2. **Remote reads and writes are different capabilities.** A narrow fetch explicitly
   authorized by policy may refresh one selected base. Pushes, PR mutations, implicit
   fallback fetches, and broad ref updates remain forbidden. Tests should distinguish
   these cases rather than mocking every Git operation as equivalent.

3. **Subprocess failures need stable semantics.** Paude wraps Git and orchestration
   commands. Preserve exit status, actionable stderr, and argument boundaries; never
   hide a failed child behind an empty or stale result.

4. **Immutable handoffs need lineage.** Every revised local change must retain its
   requested base ref, resolved base/head SHAs, previous artifact, and producing
   feedback. Reject stale branches and cross-repository artifacts before review.

5. **Tests must exercise the real command boundary.** Prefer temporary repositories
   and stateful CLI fakes that prove command arguments and persisted results. Static
   string checks alone do not establish workflow behavior.

6. **Rendered CLI text is terminal-dependent.** GitHub CI enables ANSI styling while
   city lanes may inherit `NO_COLOR`. Strip ANSI before asserting help/output strings
   (reuse the repository helper), and run new rendered-output tests once with color
   forced and `NO_COLOR` unset.
