---
description: Check that the Google Antigravity CLI (agy) is installed and signed in for this plugin, and offer to install it if it is missing.
disable-model-invocation: true
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
  - Bash(curl -fsSL https://antigravity.google/cli/install.sh | bash)
  - AskUserQuestion
---

Run `agy-run check` with the Bash tool (if `agy-run` is not found, run
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh check`). It prints JSON with
`installed`, `path`, `version`, `auth` (`ok` when `agy models` works),
`models_available`, `default_model`, `json_helper`, `warnings` and `error`.

- `installed: false`: use AskUserQuestion once with the options
  "Install agy now (Recommended)" and "Skip for now". To install, run the
  official installer, then run the check again:
  ```bash
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  ```
  If skipped, explain that the `/agy:*` commands need agy.
- `auth` is not `ok`: show `error`. To sign in, the user runs `agy` once in a
  terminal (in Claude Code: `! agy`) and completes the Google sign-in; a
  Google Cloud project can use Application Default Credentials with
  `AGY_ADC_AUTH` instead.
- `json_helper: none`: everything works, but conversation ids and token
  counts are read from agy's log instead of its JSON output; installing
  python3 or node restores them.
- Show every entry of `warnings`.
- All good: one short status line, e.g. "agy 1.4.2 ready at <path>:
  13 models, default <default_model>". Then mention `/agy:help`.
