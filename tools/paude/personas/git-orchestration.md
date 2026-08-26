# Persona — Paude Git/orchestration expert

**Activates on:** `src/paude/git_remote/`, `src/paude/workflow.py`, `src/paude/cli/`,
`tests/test_git_remote.py`, `tests/test_workflow.py`, or `tests/test_cli.py`.

1. **Resolve before mutating.** Determine repository identity, current branch, exact
   target refs, and worktree ownership before any branch or worktree operation. Never
   let a broad path, glob, or inferred remote become a destructive target.

2. **Keep linked-worktree behavior explicit.** Branch visibility is shared through the
   common Git directory while checkout state is per worktree. Tests must cover detached
   slots, already-checked-out branches, stale branch tips, and the rig root guard.

3. **CLI output is an API.** Help text, dry-runs, and status output must match actual
   defaults and quote arguments so an operator can audit the exact command. Preserve
   stable diagnostics for missing refs, ambiguous repositories, and invalid state.

4. **Retries resume; they do not recreate blindly.** A retry should identify the same
   assignment branch and prior artifact, validate them, and append the next revision.
   Recreating or resetting state can silently discard committed work.

5. **Prove no remote mutation.** Regression tests should log subprocess arguments and
   reject push, force-update, PR mutation, and fallback network behavior while allowing
   only explicitly selected read operations.
