Diagnose and fix a hard bug through independent opinions, bounded convergence, isolated
local implementation, and the shared review/revise/settle lifecycle. Quality is the
default: diagnosis N=2, convergence enabled, review N=2, max 3 rounds per phase and 3
artifact revisions. Diagnosis fan-out (--n) and implementation review fan-out
(--review-n) are independent.

`--execution` changes only the semantic diagnosis/review leaves. Diagnosis fan-out,
report-only mode, convergence, and revision bounds stay independent. Explicit lane and
review targets override the selected role set; `--dry-run` prints every resolved target.

Usage:
  gc dev-pack bug <bead> [options]

Workflow presets:
  --quality                 N=2 full bounded workflow (default)
  --fast, --solo            diagnosis N=1 + implementation review N=1, full bounded workflow
  --report-only             N=2 diagnosis only; no convergence or implementation

Options:
  --rig NAME                rig (default: infer from bead prefix)
  --n N                     diagnosis opinions: 1 or 2 (default: 2)
  --execution PROFILE       frontier-high (default), frontier-xhigh,
                            frontier-medium, efficient-xhigh, or efficient-medium
  --loop                    explicitly enable full convergence
  --max-rounds N            convergence cap per phase (default: 3)
  --base-ref REF            diagnosis/implementation baseline (default: origin/main)
  --lane-a-target T         override lane A target
  --lane-b-target T         override lane B target (N=2 only)
  --branch-prefix P         prefix the eventual local fix branch
  --review-n N              implementation review fan-out: 1 or 2 (default: 2)
  --review-lanes A[,B]      reviewer profiles; count must match --review-n
  --max-review-iterations N artifact revision cap (default: 3)
  --dry-run                 print the formula, both fan-outs, bounds, and safety policy

Examples:
  gc dev-pack bug vllm-123
  gc dev-pack bug vllm-123 --fast
  gc dev-pack bug vllm-123 --report-only
  gc dev-pack bug vllm-123 --n 2 --execution efficient-medium --dry-run
