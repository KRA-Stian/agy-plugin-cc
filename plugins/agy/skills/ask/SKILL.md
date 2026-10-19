---
description: Ask Google's Antigravity CLI (agy) a one-shot question and return its answer verbatim. Use when the user wants agy's / Gemini's / another model's answer or a second opinion, e.g. "ask agy …", "what does Gemini think about …". Accepts --model (flash, argon, opus, sonnet, gpt-oss, each with -low/-medium/-high) and --effort.
argument-hint: "[--model <alias>] [--effort low|medium|high] [--resume <conversation>] <question>"
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Send the question below to agy with one Bash call (`timeout: 600000`). The
heredoc is quoted, so the text reaches the wrapper unchanged; the wrapper
parses any leading options (`--model`, `--effort`, `--resume`, …) itself.
Copy the command exactly:

```bash
agy-run ask --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

- If the shell reports `agy-run: command not found`, run the same command
  with `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh` in place of `agy-run`.
- If the text itself contains a line that is exactly `AGY_ARGS_EOF`, use
  another delimiter.
- If there is no question, ask the user what to ask agy instead of running
  anything.

Then reply with agy's answer (stdout) verbatim: no summary, no commentary
before it. After it, add the `[agy] job=… model=… conversation=…` line from
stderr so the user can see which model answered and can follow up with
`/agy:ask --resume <conversation> …`.

If the command fails, show its error output. Exit 127 or a sign-in error
means agy is missing or signed out: suggest `/agy:setup`. Exit 64 is a
usage error (for example an unknown option or conflicting `--effort`):
show the message. Exit 75 means the answer is still being generated: run
`agy-run wait <job-id>` (`timeout: 600000`) with the job id it printed.
