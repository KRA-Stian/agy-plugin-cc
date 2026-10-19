---
description: Generate an image with Google Antigravity's (agy) built-in image generator and return the saved file path; --output copies it into the project. Use when the user asks agy / Gemini to draw, design or generate an image, icon or mockup.
argument-hint: "[--name <slug>] [--output <path>] [--model <alias>] <description>"
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Generate the image with one Bash call (`timeout: 600000`), copying the
command exactly (the wrapper parses `--name`, `--output`, `--model`; the
rest is the description):

```bash
agy-run image --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

If there is no description, ask the user what to generate instead.

The wrapper finds the file agy saved (in agy's artifacts for that
conversation, `~/.gemini/antigravity-cli/brain/<conversation>/`) and prints
`Image saved: <path>` and, with `--output`, `Copied to: <path>`. Report those
paths and agy's one-line description. Exit 4 means agy answered but no image
file was found: show the output and suggest trying again. If `agy-run` is not
found, use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh`.
