---
description: Delegate a task (coding, debugging, refactoring, analysis) to a Google Antigravity (agy) agent and bring back its report. Runs through the agy:runner subagent; --background starts a detached agy job instead. Accepts --model (flash, argon, opus, sonnet, gpt-oss, with -low/-medium/-high), --effort, --cd <dir>, --resume <conversation> and --raw.
argument-hint: "[--background] [--model <alias>] [--effort low|medium|high] [--cd <dir>] [--resume <conversation>] <task>"
allowed-tools:
  - Agent
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Delegate this request to agy:

```text
$ARGUMENTS
```

If it is empty, ask the user what agy should do and stop.

## With `--background` among the leading options

Start a detached agy job yourself with one Bash call (no subagent). Copy the
command exactly; the quoted heredoc passes the text through unchanged and
the wrapper parses the options:

```bash
agy-run task --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

It returns at once with a job id. Tell the user the id and that
`/agy:status`, `/agy:result <job>` and `/agy:cancel <job>` manage it.

## Otherwise

Launch the `agy:runner` subagent (Agent tool, `subagent_type: "agy:runner"`,
description "agy task") with exactly this prompt:

```text
subcommand: task
arguments:
$ARGUMENTS
```

When it finishes, give the user agy's report verbatim, followed by the
`[agy] job=… model=… conversation=…` line. Do not redo or second-guess agy's
work unless the user asks. agy runs headless: it edits files but cannot run
shell commands, so its report ends with the commands that verify the work.
Offer to run them (or run them if the user asked for verified results).
Follow-ups go to the same agy conversation with
`/agy:delegate --resume <conversation> …`.

## Notes

- If `agy-run` is not found, use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh`
  in its place. Exit 127 or a sign-in error: suggest `/agy:setup`.
- `--raw` sends the task without the headless note. Only useful when the
  user has allowed the needed commands in agy's own permission settings.
- Never add `--dangerously-skip-permissions` or `--mode auto`; the wrapper
  refuses them.
