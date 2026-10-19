---
description: Show the agy model aliases and thinking levels this plugin understands, plus the models your agy account offers right now.
disable-model-invocation: true
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Run `agy-run models` with the Bash tool (if `agy-run` is not found, run
`bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh models`). Copy its complete
output into your reply inside a code block, unchanged, so it is readable in
the chat and not only in the collapsed tool result.
