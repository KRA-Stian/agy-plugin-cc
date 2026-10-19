# agy (Claude Code plugin)

This directory is the plugin itself. See the [repository README](../../README.md)
for installation and usage.

- `skills/<command>/SKILL.md`: the `/agy:*` slash commands (`ask`,
  `delegate`, `research`, `review`, `image`, `setup`, `status`, `result`,
  `cancel`, `models`, `usage`, `help`), plus `antigravity-cli`, a
  model-only reference that tells Claude how to drive agy and fan out
  several agents.
- `agents/runner.md`: the `agy:runner` subagent, which forwards one request
  to agy and returns its report.
- `scripts/agy-run.sh`: the wrapper. It handles model and thinking-level
  aliases, detached jobs, recovery from denied permissions, review diffs
  and image lookup. Run `agy-run help` for the details.
- `bin/agy-run`: puts the wrapper on Claude Code's Bash PATH.
