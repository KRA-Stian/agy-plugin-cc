---
description: Have a Google Antigravity (agy) agent research a topic on the web and return a structured, sourced report (Summary, Key findings, Caveats, Sources). Runs through the agy:runner subagent; --background starts a detached agy job. Accepts --model (argon or opus suit deep research) and --effort.
argument-hint: "[--background] [--model <alias>] [--effort low|medium|high] <topic or question>"
allowed-tools:
  - Agent
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Research request:

```text
$ARGUMENTS
```

If it is empty, ask the user what to research and stop.

**With `--background`** among the leading options, start a detached job
with one Bash call, copying the command exactly:

```bash
agy-run research --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

Report the job id and that `/agy:result <job>` collects the report.

**Otherwise** launch the `agy:runner` subagent (Agent tool,
`subagent_type: "agy:runner"`, description "agy research") with exactly
this prompt:

```text
subcommand: research
arguments:
$ARGUMENTS
```

Return the report verbatim, followed by the `[agy] job=… model=…
conversation=…` line. The wrapper wraps the topic in a read-only research
brief (web search allowed, no file changes). If `agy-run` is not found, use
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh` instead.
