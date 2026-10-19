---
description: List the agy jobs this plugin started (running and finished), or show one job's details.
argument-hint: "[job-id|last] [--all]"
disable-model-invocation: true
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Run with the Bash tool, copying the command exactly:

```bash
agy-run status --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

(If `agy-run` is not found, use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh`.)

Show the output verbatim inside a code block. Point out running jobs and
that `/agy:result <job>` shows a finished job's output and
`/agy:cancel <job>` stops a running one.
