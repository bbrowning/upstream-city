Open a reviewed PR in its materialized real worktree. With a question, a one-shot
agent mails a durable chained answer. Without a question, attach to a persistent
interactive coding-assistant session for that PR.

Usage:
  gc dev-pack ask <PR-number | rig#PR | bead-id> ["<question>"] [options]

Modes:
  Async (question present)       Interactive (no question; terminal required)
  gc dev-pack ask 51937 \
    "why this refactor?"          gc dev-pack ask 51937
  One-shot answer is mailed      One reattachable session per PR
  and chained durably            Detach with Ctrl-b d; rerun to reattach

Both modes materialize the actual PR into its durable PR worktree and load the
original review verdict plus all prior asynchronous Q&A. Interactive conversation
history lives only in the session: it emits, closes, and mails nothing. Use the
question-present form when an answer must be durable, mailed, and available to later
rounds.

Options:
  --rig NAME                owning rig (default: vllm; rig#PR also selects it)
  --base REF                diff baseline passed to materialize (default: origin/main)
  --force                   refresh a moved PR worktree, discarding local changes there
  --dry-run                 print materialization and follow-up/session actions
  -h, --help                show this help

Examples:
  gc dev-pack ask vllm#51937 "does this handle empty batches?"
  gc dev-pack ask vllm#51937

