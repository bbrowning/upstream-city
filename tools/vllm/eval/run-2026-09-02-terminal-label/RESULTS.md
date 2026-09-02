# Persona A/B — shared terminal labels

Case: `caseTerminalLabelReuse`
Review target: `07242faa...8457a37a`
Workflow: `gc dev-pack review --solo --execution frontier-medium`

The target is the feature diff after newer `main` introduced Inkling, immediately
before the commit that corrected the label-based bypass.

## Result

- Baseline without the candidate: **approve, zero findings** (`vllm-naix2`, review
  attempt `vllm-1hdj4`) — **miss**.
- After adding the terminal-label gotcha: **request changes, one major finding**
  (`vllm-z8qii`, review attempt `vllm-4w4tn`) — **catch**.

The after arm identified that Inkling maps a general block closer to `THINK_END`, then
traced how the new early return skips the `TOOL_ARGS -> CONTENT` transition and
`TOOL_CALL_END`. It proposed a transition- or config-aware rule and dedicated Inkling
coverage. This matches the subsequent corrective commit `b3258f1b73`.

No extra findings were emitted by the after arm. The candidate therefore moved the
same frontier-medium, single-lane workflow from miss to a grounded catch without added
review noise.

An earlier exploratory target (`5b35c31b88`) was rejected because Inkling did not yet
exist in that snapshot; those runs are not counted in this result.
