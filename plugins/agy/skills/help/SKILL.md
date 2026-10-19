---
description: Show every /agy:* command, the wrapper options, model aliases and thinking levels.
disable-model-invocation: true
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Run `agy-run help` with the Bash tool (if `agy-run` is not found, run
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh help`). The wrapper is the
source of truth, so copy its complete output into your reply inside a code
block without paraphrasing, reordering or trimming it; it must be readable in
the chat, not only in the collapsed tool result.
