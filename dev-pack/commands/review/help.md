Review a PR or immutable local change without mutating it. Quality is the default: two
independent reviewer profiles followed by strict synthesis. Results arrive as durable
verdict evidence plus readable mail; the human retains the merge checkpoint.

Usage:
  gc dev-pack review <PR-number | rig#PR | local-ref | artifact-bead> [options]
  gc dev-pack review --artifact <local-change.json> --rig <rig> [options]

Workflow presets:
  --quality                 N=2 independent quorum (default)
  --fast, --solo            explicit lower-cost N=1 review

Options:
  --rig NAME                owning rig (default: vllm; rig#PR also selects it)
  --base REF                diff baseline (default: origin/main)
  --artifact X              local-change.v1 file or implementation-output bead
  --n N                     reviewer opinions: 1 or 2 (default: 2)
  --lanes A[,B]             reviewer profiles; count defines and must match N
  --dry-run                 validate and print the formula, targets, and checkpoint

Examples:
  gc dev-pack review 53174 --rig vllm
  gc dev-pack review vllm#53174 --fast
  gc dev-pack review --artifact /path/to/local-change.json --rig vllm
  gc dev-pack review 53174 --rig vllm --lanes sonnet-xhigh,gpt56luna-xhigh --dry-run
