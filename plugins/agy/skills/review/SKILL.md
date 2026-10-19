---
description: Get a second-opinion code review from Google Antigravity (agy) of the current git diff (uncommitted and untracked changes), or of a whole branch with --base <branch>. Read-only. Accepts --model, --effort and free-text focus.
argument-hint: "[--base <branch>] [--model <alias>] [--effort low|medium|high] [--no-untracked] [focus]"
allowed-tools:
  - Bash(agy-run *)
  - Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh *)
---

Run the review with one Bash call (`timeout: 600000`) from the repository,
copying the command exactly (the quoted heredoc passes the text unchanged;
the wrapper parses `--base`, `--model`, `--effort` and treats the rest as
the review focus):

```bash
agy-run review --args-stdin <<'AGY_ARGS_EOF'
$ARGUMENTS
AGY_ARGS_EOF
```

The wrapper collects the diff itself (`git diff HEAD` plus untracked files,
or everything since the merge base with `--base`) and tells agy not to
modify anything.

- Return agy's review verbatim, then the `[agy] job=… model=…` line.
- `nothing to review`: tell the user to make or stage changes, or to pass
  `--base <branch>` to review a branch.
- Exit 75: still running; run `agy-run wait <job-id>` (`timeout: 600000`).
- If `agy-run` is not found, use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh`.

Do not fix the findings unless the user asks; you may say which ones you
agree with.
