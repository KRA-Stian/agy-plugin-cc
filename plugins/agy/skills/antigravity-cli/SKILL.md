---
name: antigravity-cli
description: How to drive Google's Antigravity CLI (agy) through the agy plugin's agy-run wrapper - asking agy questions, delegating tasks to agy agents, spinning up several agy agents in parallel, picking models and thinking levels, follow-ups and job control. Use before calling agy-run yourself or when orchestrating more than one agy agent.
user-invocable: false
---

# Driving agy with `agy-run`

`agy-run` (on the Bash PATH while this plugin is enabled; otherwise
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh`) wraps the Antigravity CLI.
Every call is a job: agy runs detached in the current directory (its
workspace), and the wrapper prints agy's reply on stdout and a
`[agy] job=… model="…" conversation=… time=… tokens=…` line on stderr.

## Which entry point

| Need | Use |
|---|---|
| quick question / second opinion | `agy-run ask …` or `/agy:ask` |
| hand off a task, get a report | `agy:runner` subagent (`subagent_type: "agy:runner"`) or `/agy:delegate` |
| several tasks at once | `agy-run start …` per task, then `agy-run wait <id> <id> …` |
| web research | `agy-run research …` or `/agy:research` |
| review a diff / branch | `agy-run review [--base main] …` or `/agy:review` |
| image | `agy-run image [--output path] …` or `/agy:image` |

Pass free text through a quoted heredoc so nothing is shell-expanded:

```bash
agy-run task --model opus-high --cd "$PWD" --stdin <<'AGY_EOF'
Refactor src/db/queries.py to use parameterised queries. Keep the public API.
AGY_EOF
```

`--stdin` takes the text from stdin; `--args-stdin` also parses leading
options from it (what the slash commands use). Options go before the text.
Use Bash `timeout: 600000` for foreground calls.

## Models and thinking levels

| Alias | Model | Levels (bare alias = default) |
|---|---|---|
| `flash` | Gemini 3.8 Flash | `flash-low`, `flash-medium`, `flash-high` (flash = High) |
| `argon` | Gemini 4 Argon | `argon-low`, `argon-medium`, `argon-high` (argon = Medium) |
| `opus` | Claude Opus 5.5 | `opus-low`, `opus-medium`, `opus-high` (opus = Medium) |
| `sonnet` | Claude Sonnet 5.5 | `sonnet-low`, `sonnet-medium`, `sonnet-high` (sonnet = Medium) |
| `gpt-oss` | GPT-OSS 120B | Medium only |

`--effort low|medium|high` (alias `--thinking`) sets the level of a bare
alias: `--model opus --effort high` = `--model opus-high`. Display names
("Claude Opus 5.5 (High)") and ids (`claude-opus-5-5-high`) also work, and
unknown names go to agy unchanged. No `--model` means the user's agy
default. Rough guide: flash for fast, cheap work; sonnet for everyday
coding; opus or argon (high) for hard reasoning, tricky bugs and research;
gpt-oss for an independent perspective. Gemini, Claude/GPT and Argon draw
on separate quotas (`agy-run usage`); honour a model the user names.

## Spinning up several agy agents

```bash
agy-run start --model sonnet --cd /path/a --stdin <<'AGY_EOF'
…task A…
AGY_EOF
agy-run start --model flash --cd /path/b --stdin <<'AGY_EOF'
…task B…
AGY_EOF
agy-run wait <idA> <idB>          # Bash timeout 600000; exit 75 = still running, call again
```

`start` prints the job id at once. `wait` with several ids prints one
`===== agy job … =====` block per job. You can also run `wait` with
`run_in_background: true` and carry on until it completes, or launch
several `agy:runner` subagents in one message. Agents that edit files at the
same time must not share a working tree: give each its own `git worktree`
and point `--cd` at it.

## What a headless agy can do

agy reads and edits files in its workspace (`--cd`, plus `--add-dir` dirs)
and can search the web, but it cannot answer questions or get permission
prompts approved, so shell commands are denied. `task` therefore tells agy
to use file tools only and to end with the commands that verify its work;
run those yourself. If a run still stops on a denied permission, the
wrapper resumes the conversation once to recover the report. `--raw` drops
the note (only useful if the user allowed commands in agy's own settings).
Never pass `--dangerously-skip-permissions` or `--mode auto`; the wrapper
refuses them.

## Follow-ups and jobs

- `--resume <conversation>` continues an earlier agy conversation.
- `agy-run status [job]`, `result [job]`, `wait [job…|all] [--timeout S]`,
  `cancel <job|last|all>`; `last` means the newest job.
- Exit codes: 0 ok · 1 agy error · 3 no reply · 4 no image · 64 usage error ·
  75 still running · 127 agy missing · 130 cancelled.
- Everything agy reads goes to the model provider through Antigravity;
  don't hand it secrets.
