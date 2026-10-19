# agy-plugin-cc

Use Google's [Antigravity CLI (`agy`)](https://antigravity.google/) from
Claude Code. Claude can ask agy questions, hand tasks to agy agents (one or
several in parallel), get second-opinion reviews, research topics and
generate images, on every model and thinking level agy offers.

This is a maintained recreation of
[simplybychris/antigravity-plugin-cc](https://github.com/simplybychris/antigravity-plugin-cc),
which stopped tracking agy's model lineup. It ships the current lineup from
upstream [PR #5](https://github.com/simplybychris/antigravity-plugin-cc/pull/5),
per-call models that never block each other
([PR #6](https://github.com/simplybychris/antigravity-plugin-cc/pull/6)),
and fixes for issues [#3](https://github.com/simplybychris/antigravity-plugin-cc/issues/3)
and [#4](https://github.com/simplybychris/antigravity-plugin-cc/issues/4).

## Install

You need Claude Code, [agy](https://antigravity.google/) (signed in), bash
and git on macOS, Linux or WSL. python3 or node is recommended.

In Claude Code:

```text
/plugin marketplace add KRA-Stian/agy-plugin-cc
/plugin install agy@agy-plugin-cc
/reload-plugins
/agy:setup
```

On Claude Code 2.1.275 or later the first two lines can be one:
`/plugin install agy --marketplace KRA-Stian/agy-plugin-cc`.

From a shell instead:

```bash
claude plugin marketplace add KRA-Stian/agy-plugin-cc
claude plugin install agy@agy-plugin-cc
```

The plugin installs for your user, so it is available in every project and
session. `/agy:setup` checks that agy is installed and signed in. If agy is
missing it offers to run the official installer
(`curl -fsSL https://antigravity.google/cli/install.sh | bash`). Then run
`agy` once in a terminal to sign in.

**Update:** `claude plugin marketplace update agy-plugin-cc`, then
`claude plugin update agy@agy-plugin-cc` and `/reload-plugins`.

**Optional:** to let Claude call agy without a permission prompt each
time, allow the wrapper in `~/.claude/settings.json`. This is needed for
background delegation in sessions that cannot show prompts.

```json
{ "permissions": { "allow": ["Bash(agy-run *)"] } }
```

`agy-run` only runs agy through this plugin's guard rails. It refuses
permission-bypass flags.

## Use

| Command | What it does |
|---|---|
| `/agy:ask [--model M] <question>` | One-shot question. agy's answer comes back verbatim. |
| `/agy:delegate [--model M] <task>` | Hands the task to an agy agent through the `agy:runner` subagent. `--background` starts a detached job instead. |
| `/agy:research [--model M] <topic>` | Web research, returned with sections and sources. |
| `/agy:review [--base main] [focus]` | Read-only review of your uncommitted changes, or of a whole branch with `--base`. |
| `/agy:image [--output path] <description>` | Generates an image with agy's built-in generator. |
| `/agy:status` · `/agy:result [job]` · `/agy:cancel <job>` | Manage jobs. |
| `/agy:models` · `/agy:usage` · `/agy:setup` · `/agy:help` | Model list, quota, health check, help. |

Common options: `--model`, `--effort low|medium|high`, `--resume <conversation>`
for follow-ups, `--cd <dir>` for the workspace, and `--background`.

You can also just ask:

- *"Have agy fix the failing test in parser.py with opus-high, then run the tests."*
- *"Spin up three agy agents in parallel on flash: one per module, each adding docstrings."*
- *"Get a second opinion from Gemini on this migration plan."*

### Models and thinking levels

| Alias | Model | Thinking levels |
|---|---|---|
| `flash` | Gemini 3.8 Flash | `flash-low`, `flash-medium`, `flash-high` (`flash` = High) |
| `argon` | Gemini 4 Argon | `argon-low`, `argon-medium`, `argon-high` (`argon` = Medium) |
| `opus` | Claude Opus 5.5 | `opus-low`, `opus-medium`, `opus-high` (`opus` = Medium) |
| `sonnet` | Claude Sonnet 5.5 | `sonnet-low`, `sonnet-medium`, `sonnet-high` (`sonnet` = Medium) |
| `gpt-oss` | GPT-OSS 120B | Medium only |

`--model opus --effort high` is the same as `--model opus-high`. Display names
(`"Claude Opus 5.5 (High)"`) and model ids (`claude-opus-5-5-high`) work too.
Any other name is passed to agy unchanged, so new models work before this
table is updated. If agy drops one of the models above, its alias falls back
to the newest model of the same family that `agy models` lists. Without
`--model`, agy uses your default model.

## How it works

- `agy-run` (`plugins/agy/scripts/agy-run.sh`, plain bash) runs every call
  as a job under `~/.local/state/agy-plugin/jobs`. agy runs detached with
  stdin closed and its native `--model` / `--effort` flags. Parallel calls
  never block each other, `settings.json` is never touched, and long tasks
  survive Claude's Bash timeouts.
- Headless agy reads and edits files in its workspace and can search the
  web, but it auto-denies shell commands because nobody can approve them.
  For delegated tasks the plugin tells agy to use file tools and to end with
  the commands that verify its work, which Claude can then run. If a run
  still stops on a denied command, the wrapper resumes the conversation once
  to recover agy's report.
- The plugin never passes `--dangerously-skip-permissions` or `--mode auto`.

## Development

```bash
python3 -m unittest discover -s tests                   # offline, fake agy (79 tests)
AGY_LIVE=1 python3 -m unittest tests/live_test_agy.py   # real agy: every model, task, review, image…
AGY_E2E=1 python3 -m unittest tests/e2e_test_claude.py  # Claude Code end to end
claude --plugin-dir plugins/agy                         # try local changes
```

## License

MIT. Based on [antigravity-plugin-cc](https://github.com/simplybychris/antigravity-plugin-cc)
by simplybychris (MIT). The model lineup follows upstream PR #5 and native
per-call models follow PR #6.
