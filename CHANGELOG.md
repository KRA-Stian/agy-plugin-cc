# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-19

A recreation of
[simplybychris/antigravity-plugin-cc](https://github.com/simplybychris/antigravity-plugin-cc)
0.4.1 for agy 1.4.

### Added
- The current agy lineup, each with Low / Medium / High thinking levels
  (upstream PR #5): `flash-*` (Gemini 3.8 Flash, `flash` = High),
  `argon-*` (Gemini 4 Argon), `opus-*` (Claude Opus 5.5) and `sonnet-*`
  (Claude Sonnet 5.5), where the bare alias means Medium, plus `gpt-oss`
  (GPT-OSS 120B, Medium).
- `--effort` / `--thinking` to pick the level for a bare alias. Display
  names and model ids are accepted. Unknown names pass through to agy.
- Stale aliases fall back to the newest model of the same family listed by
  `agy models` (upstream issue #4).
- Jobs: every call runs detached under `~/.local/state/agy-plugin/jobs`.
  `--background`, `start`, `status`, `result`, `wait` (one or several jobs),
  `cancel` and `prune`, with `/agy:status`, `/agy:result` and `/agy:cancel`.
- Parallel fan-out of several agy agents (`start` + `wait <id> <id>`), and
  the `antigravity-cli` skill, which teaches Claude how to orchestrate them.
- `--resume <conversation>` for follow-ups in the same agy conversation.
- `--cd`, `--add-dir`, `--sandbox`, `--mode plan|accept-edits`, `--agent`,
  `--timeout`, `--json-schema` and `--project` pass-through options.
- `/agy:review --base <branch>` reviews a whole branch. Untracked files are
  included. Large diffs and prompts go through a file instead of argv.
- `/agy:image` finds the image in the conversation's artifacts and copies it
  with `--output`.
- `/agy:models` (aliases plus the live `agy models` list) and `/agy:usage`
  (quota).
- `bin/agy-run` puts the wrapper on Claude Code's PATH.
- Offline (79 tests), live-agy and Claude Code end-to-end test suites, plus
  CI on Linux and on macOS with bash 3.2.

### Changed
- Slash commands are skills (`skills/<name>/SKILL.md`). They pass the raw
  arguments through a quoted heredoc (`--args-stdin`), so the wrapper parses
  options and nothing is shell-expanded.
- `--model` uses agy's native per-process flag (upstream PR #6). There is
  no more `settings.json` patching or global lock, and parallel calls run
  concurrently.
- The `agy:runner` subagent runs on haiku and keeps waiting while a job is
  still running.

### Fixed
- agy hung on an open stdin. agy now always gets `/dev/null` (upstream
  issue #3).
- Headless agy auto-denies shell commands and then stops without a reply.
  Delegated tasks now ask agy to use file tools and report the commands to
  verify, and a run cut short by a denied permission is resumed once to
  recover the report.

### Removed
- Gemini 3.5 Flash, Gemini 3.1 Pro and Claude 4.6 (Thinking) aliases.
  `pro` now explains that Gemini 4 Argon replaced it.
