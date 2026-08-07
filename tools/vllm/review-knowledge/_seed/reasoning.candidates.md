# reasoning — candidate invariants (review, prune, then accept)
#
# Accept the ones you trust:  gc pr-review-pack learn --from-candidates this-file.md
# (that assigns IDs and appends them to reasoning.md; delete any line you reject first)
#
# Sparse domain: only 2 mined comments in this window. One yielded a real contract;
# the other (PR #45852, a `prepare_streaming_for_prompt` -> `adjust_initial_state_from_prompt`
# method rename) was dropped as a PR-specific naming nit, not a generalizable invariant.

- Represent absent reasoning as `None`, not the empty string `""` — why: consumers and tests that distinguish "no reasoning" from "empty reasoning" break when the parser conflates the two. (PR #45701, @bbrowning)
