---
description: Stop a running agy job started by this plugin (a job id, "last" or "all").
argument-hint: "<job-id|last|all>"
disable-model-invocation: true
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Job to cancel: `$ARGUMENTS`

If that is empty, run `agy-run status`, show the running jobs and ask the
user which one to cancel; do not guess. Otherwise run, copying the command
exactly:

```bash
agy-run cancel --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

(If `agy-run` is not found, use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh`.)

Report the result in one line. File edits agy already made stay in the
working tree.
