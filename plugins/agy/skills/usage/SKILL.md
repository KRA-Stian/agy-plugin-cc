---
description: Show your remaining Antigravity (agy) quota per model group and when it resets.
disable-model-invocation: true
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Run `agy-run usage` with the Bash tool (if `agy-run` is not found, run
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh usage`). Copy its output into
your reply inside a code block, unchanged. Reset times are UTC.
