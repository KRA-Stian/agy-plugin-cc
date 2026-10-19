---
description: Show the output of a finished agy job (default: the most recent one).
argument-hint: "[job-id|last]"
disable-model-invocation: true
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Run with the Bash tool, copying the command exactly:

```bash
agy-run result --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

(If `agy-run` is not found, use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh`.)

Reply with agy's output verbatim, then the `[agy] job=… model=…
conversation=…` line. Exit 75 means the job is still running: say so and
offer to wait for it (`agy-run wait <job-id>`, Bash `timeout: 600000`).
Other non-zero exits: show the error output.
