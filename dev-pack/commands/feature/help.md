Implement a feature on an isolated local branch, emit an immutable artifact, then run
the bounded review → synthesis → settlement → revise/approve lifecycle. Quality is the
default: N=2 review, at most 3 artifact revisions, local-only, and closure only after
approval. The final handoff names the local branch and exact HEAD SHA.

`--execution` changes only the semantic implementation/review leaves. Review fan-out,
revision bounds, and approval stay independent. Explicit implementer/reviewer targets
override the selected role set; `--dry-run` prints every resolved target.

Usage:
  gc dev-pack feature <bead> [options]

Workflow presets:
  --quality                 N=2 bounded lifecycle (default)
  --fast, --solo            explicit lower-cost N=1 lifecycle

Options:
  --rig NAME                rig (default: infer from bead prefix)
  --execution PROFILE       frontier-xhigh (default), frontier-medium,
                            efficient-xhigh, or efficient-medium
  --implementer-target T    expert override for the implementation leaf
  --base REF                branch point (default: origin/main)
  --offline                 do not fetch the selected base; record freshness unverified
  --review-n N              lifecycle review fan-out: 1 or 2 (default: 2)
  --review-lanes A[,B]      reviewer profiles; count must match --review-n
  --max-review-iterations N artifact revision cap (default: 3)
  --revision N              artifact revision (default: 1)
  --previous-artifact ID    predecessor required when revision > 1
  --feedback-bead ID        review/settlement bead requiring revision > 1
  --verdict VERDICT         verdict requiring revision > 1
  --dry-run                 print the selected formula, bounds, targets, and safety policy

Examples:
  gc dev-pack feature vllm-123
  gc dev-pack feature vllm-123 --execution frontier-xhigh
  gc dev-pack feature vllm-123 --fast --execution efficient-medium
  gc dev-pack feature vllm-123 --review-n 2 --review-lanes vllm/expert-review-a,vllm/expert-review-b
  gc dev-pack feature vllm-123 --dry-run
