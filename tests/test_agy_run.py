"""Offline tests for plugins/agy/scripts/agy-run.sh.

They run the wrapper against tests/fake-agy/agy, which records every call and
answers like agy 1.4. Nothing here talks to the real agy or uses any quota.

    python3 -m unittest discover -s tests -v
    AGY_TEST_BASH=/path/to/bash-3.2 python3 -m unittest discover -s tests
"""

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "plugins" / "agy" / "scripts" / "agy-run.sh"
SHIM = ROOT / "plugins" / "agy" / "bin" / "agy-run"
FAKE = ROOT / "tests" / "fake-agy" / "agy"
BASH = os.environ.get("AGY_TEST_BASH", "bash")

HEADLESS_MARK = "[Delegated from Claude Code: headless agy run]"


class Base(unittest.TestCase):
    def setUp(self):
        # resolve(): on macOS /var is a symlink to /private/var and bash reports the latter
        self.tmp = Path(tempfile.mkdtemp(prefix="agy-test-")).resolve()
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.calls = self.tmp / "calls"
        self.state = self.tmp / "state"
        self.agy_home = self.tmp / "agyhome"
        self.agy_home.mkdir()
        self.env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("AGY_", "FAKE_AGY_", "GIT_"))
        }
        self.env.update(
            {
                "AGY_BIN": str(FAKE),
                "AGY_PLUGIN_HOME": str(self.state),
                "AGY_HOME": str(self.agy_home),
                "AGY_POLL_INTERVAL": "0.1",
                "AGY_IMAGE_GRACE_SECONDS": "0",
                "FAKE_AGY_CALLS_DIR": str(self.calls),
                "FAKE_AGY_SCENARIO": "ok",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_AUTHOR_NAME": "Test",
                "GIT_AUTHOR_EMAIL": "test@example.com",
                "GIT_COMMITTER_NAME": "Test",
                "GIT_COMMITTER_EMAIL": "test@example.com",
            }
        )

    def tearDown(self):
        subprocess.run(
            [BASH, str(SCRIPT), "cancel", "all"],
            env=self.env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=60,
        )
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- helpers ---------------------------------------------------------

    def run_agy(self, *args, input=None, cwd=None, env=None, timeout=60, cmd=None):
        e = dict(self.env)
        e.update(env or {})
        return subprocess.run(
            cmd or [BASH, str(SCRIPT), *args],
            input=input,
            stdin=None if input is not None else subprocess.DEVNULL,
            capture_output=True,
            text=True,
            cwd=str(cwd or self.work),
            env=e,
            timeout=timeout,
        )

    def ncalls(self):
        return len(list(self.calls.iterdir())) if self.calls.exists() else 0

    def call(self, n=1):
        d = self.calls / str(n)
        args = [a.decode() for a in (d / "args").read_bytes().split(b"\0")[:-1]]
        return {
            "args": args,
            "cwd": (d / "cwd").read_text().strip(),
            "stdin": (d / "stdin").read_text().strip(),
            "prompt": (d / "prompt").read_text() if (d / "prompt").exists() else None,
        }

    @staticmethod
    def flag(args, name):
        """Value following `name` in an argv list (None when absent)."""
        return args[args.index(name) + 1] if name in args else None

    def job_dirs(self):
        jobs = self.state / "jobs"
        return sorted(jobs.iterdir()) if jobs.exists() else []

    def job_id(self, stdout):
        for word in stdout.split():
            if len(word) == 20 and word[8] == "-" and word[15] == "-":
                return word
        self.fail("no job id in: " + stdout)

    def git(self, *args, cwd=None):
        subprocess.run(
            ["git", *args], cwd=str(cwd or self.work), env=self.env, check=True, capture_output=True
        )


class ModelResolution(Base):
    def resolve(self, *args):
        p = self.run_agy("resolve-model", *args)
        self.assertEqual(p.returncode, 0, p.stderr)
        out = dict(line.split("=", 1) for line in p.stdout.strip().splitlines())
        return out["model"], out["effort"]

    def test_every_alias_in_the_lineup(self):
        expected = {
            "flash": "Gemini 3.8 Flash (High)",
            "flash-low": "Gemini 3.8 Flash (Low)",
            "flash-medium": "Gemini 3.8 Flash (Medium)",
            "flash-high": "Gemini 3.8 Flash (High)",
            "argon": "Gemini 4 Argon (Medium)",
            "argon-low": "Gemini 4 Argon (Low)",
            "argon-medium": "Gemini 4 Argon (Medium)",
            "argon-high": "Gemini 4 Argon (High)",
            "opus": "Claude Opus 5.5 (Medium)",
            "opus-low": "Claude Opus 5.5 (Low)",
            "opus-medium": "Claude Opus 5.5 (Medium)",
            "opus-high": "Claude Opus 5.5 (High)",
            "sonnet": "Claude Sonnet 5.5 (Medium)",
            "sonnet-low": "Claude Sonnet 5.5 (Low)",
            "sonnet-medium": "Claude Sonnet 5.5 (Medium)",
            "sonnet-high": "Claude Sonnet 5.5 (High)",
            "gpt-oss": "GPT-OSS 120B (Medium)",
        }
        for alias, canonical in expected.items():
            with self.subTest(alias=alias):
                self.assertEqual(self.resolve("--model", alias), (canonical, ""))

    def test_synonyms_case_and_model_ids(self):
        cases = {
            "FLASH": "Gemini 3.8 Flash (High)",
            "Flash-Med": "Gemini 3.8 Flash (Medium)",
            "claude-opus": "Claude Opus 5.5 (Medium)",
            "claude-sonnet": "Claude Sonnet 5.5 (Medium)",
            "gpt-oss-120b": "GPT-OSS 120B (Medium)",
            "claude-opus-5-5-high": "Claude Opus 5.5 (High)",
            "gemini-3.8-flash-low": "Gemini 3.8 Flash (Low)",
            "gemini-4-argon": "Gemini 4 Argon (Medium)",
            "gpt-oss-120b-medium": "GPT-OSS 120B (Medium)",
            "Claude Sonnet 5.5 (High)": "Claude Sonnet 5.5 (High)",
            "gemini 4 argon (low)": "Gemini 4 Argon (Low)",
        }
        for name, canonical in cases.items():
            with self.subTest(name=name):
                self.assertEqual(self.resolve("--model", name), (canonical, ""))

    def test_effort_picks_the_thinking_level(self):
        self.assertEqual(self.resolve("--model", "opus", "--effort", "high"), ("Claude Opus 5.5 (High)", ""))
        self.assertEqual(self.resolve("--model", "flash", "--thinking", "low"), ("Gemini 3.8 Flash (Low)", ""))
        self.assertEqual(self.resolve("--model=sonnet", "--effort=med"), ("Claude Sonnet 5.5 (Medium)", ""))
        self.assertEqual(self.resolve("-m", "argon", "-e", "HIGH"), ("Gemini 4 Argon (High)", ""))
        # matching explicit level and effort is fine
        self.assertEqual(self.resolve("--model", "opus-high", "--effort", "high"), ("Claude Opus 5.5 (High)", ""))

    def test_effort_without_model_goes_to_agy(self):
        self.assertEqual(self.resolve("--effort", "low"), ("", "low"))

    def test_levels_outside_the_table_use_base_id_and_effort(self):
        self.assertEqual(self.resolve("--model", "opus", "--effort", "max"), ("claude-opus-5-5", "max"))
        self.assertEqual(self.resolve("--model", "flash-xhigh"), ("gemini-3.8-flash", "xhigh"))

    def test_unknown_names_pass_through(self):
        self.assertEqual(self.resolve("--model", "gemini-5-ultra"), ("gemini-5-ultra", ""))
        self.assertEqual(self.resolve("--model", "Claude Opus 5.5 (Thinking)"), ("Claude Opus 5.5 (Thinking)", ""))
        self.assertEqual(self.resolve("--model", "new-model", "--effort", "high"), ("new-model", "high"))

    def test_conflicting_level_and_effort(self):
        p = self.run_agy("resolve-model", "--model", "opus-low", "--effort", "high")
        self.assertEqual(p.returncode, 64)
        self.assertIn("conflicts", p.stderr)

    def test_invalid_effort(self):
        p = self.run_agy("resolve-model", "--model", "opus", "--effort", "extreme")
        self.assertEqual(p.returncode, 64)
        self.assertIn("invalid thinking level", p.stderr)

    def test_retired_pro_alias_explains_itself(self):
        for name in ("pro", "pro-high", "PRO-LOW"):
            with self.subTest(name=name):
                p = self.run_agy("resolve-model", "--model", name)
                self.assertEqual(p.returncode, 64)
                self.assertIn("argon", p.stderr)
                self.assertIn("Gemini 3.8 Flash", p.stderr)  # alias table follows

    def test_empty_model_value(self):
        for args in (("--model",), ("--model=",), ("--model", "")):
            with self.subTest(args=args):
                p = self.run_agy("ask", *args)
                self.assertEqual(p.returncode, 64)
                self.assertEqual(self.ncalls(), 0)


class Ask(Base):
    def test_basic_call(self):
        p = self.run_agy("ask", "--model", "flash", "What", "is", "2+2?")
        self.assertEqual(p.returncode, 0, p.stderr)
        c = self.call(1)
        self.assertEqual(self.ncalls(), 1)
        self.assertEqual(c["prompt"], "What is 2+2?")
        self.assertEqual(self.flag(c["args"], "--model"), "Gemini 3.8 Flash (High)")
        self.assertEqual(self.flag(c["args"], "--output-format"), "json")
        self.assertIsNotNone(self.flag(c["args"], "--log-file"))
        self.assertNotIn("--effort", c["args"])
        self.assertEqual(c["cwd"], str(self.work))
        self.assertEqual(p.stdout, "FAKE-OK model=Gemini 3.8 Flash (High) effort=none conv=00000000-0000-4000-8000-000000000001\n")
        self.assertIn('model="Gemini 3.8 Flash (High)"', p.stderr)
        self.assertIn("conversation=00000000-0000-4000-8000-000000000001", p.stderr)
        self.assertIn("tokens=15", p.stderr)
        self.assertIn("time=0.5s", p.stderr)

    def test_agy_stdin_is_closed(self):
        p = self.run_agy("ask", "hello")
        self.assertEqual(p.returncode, 0, p.stderr)
        stdin = self.call(1)["stdin"]
        if stdin == "unknown":
            self.skipTest("no /proc on this platform")
        self.assertEqual(stdin, "/dev/null")

    def test_default_model_sends_no_model_flag(self):
        p = self.run_agy("ask", "hello")
        self.assertEqual(p.returncode, 0, p.stderr)
        args = self.call(1)["args"]
        self.assertNotIn("--model", args)
        self.assertIn('model="Fake Default (Medium)"', p.stderr)  # label read from agy's log

    def test_effort_only(self):
        p = self.run_agy("ask", "--effort", "low", "hello")
        self.assertEqual(p.returncode, 0, p.stderr)
        args = self.call(1)["args"]
        self.assertNotIn("--model", args)
        self.assertEqual(self.flag(args, "--effort"), "low")

    def test_stdin_text_is_passed_verbatim(self):
        text = "Line one with \"double\" and 'single' quotes, $HOME, `backticks`, \\backslash, émoji 🎉\n-- second line\n"
        p = self.run_agy("ask", "--stdin", input=text)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.call(1)["prompt"], text.rstrip("\n"))

    def test_words_and_stdin_combine(self):
        p = self.run_agy("ask", "Context:", "--stdin", input="body")
        # options end at the first word, so --stdin here is part of the text
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.call(1)["prompt"], "Context: --stdin")
        p = self.run_agy("ask", "--stdin", "Context:", input="body")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.call(2)["prompt"], "Context:\n\nbody")

    def test_text_starting_with_a_dash(self):
        p = self.run_agy("ask", "--", "--model is a flag I mean")
        self.assertEqual(p.returncode, 0, p.stderr)
        c = self.call(1)
        self.assertEqual(c["prompt"], "--model is a flag I mean")
        self.assertNotIn("--model", c["args"][2:])

    def test_resume_continues_a_conversation(self):
        p = self.run_agy("ask", "--resume", "abc-123", "follow", "up")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.flag(self.call(1)["args"], "--conversation"), "abc-123")
        self.assertIn("conversation=abc-123", p.stderr)

    def test_cd_sets_the_workspace(self):
        other = self.tmp / "other"
        other.mkdir()
        p = self.run_agy("ask", "--cd", str(other), "hello")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.call(1)["cwd"], str(other))
        p = self.run_agy("ask", "--cd", str(self.tmp / "missing"), "hello")
        self.assertEqual(p.returncode, 64)

    def test_agy_options_are_forwarded(self):
        extra = self.tmp / "extra"
        extra.mkdir()
        p = self.run_agy(
            "ask", "--sandbox", "--add-dir", "../extra", "--agent", "reviewer", "--mode", "plan",
            "--timeout", "20m", "--json-schema", '{"type":"object"}', "--project", "p1",
            "--agy-arg", "--disable-slash-commands", "question",
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        args = self.call(1)["args"]
        self.assertIn("--sandbox", args)
        self.assertEqual(self.flag(args, "--add-dir"), str(extra))
        self.assertEqual(self.flag(args, "--agent"), "reviewer")
        self.assertEqual(self.flag(args, "--mode"), "plan")
        self.assertEqual(self.flag(args, "--print-timeout"), "20m")
        self.assertEqual(self.flag(args, "--json-schema"), '{"type":"object"}')
        self.assertEqual(self.flag(args, "--project"), "p1")
        self.assertIn("--disable-slash-commands", args)

    def test_permission_bypass_is_refused(self):
        for args in (
            ("--dangerously-skip-permissions", "hi"),
            ("--agy-arg", "--dangerously-skip-permissions", "hi"),
            ("--agy-arg=--dangerously-skip-permissions", "hi"),
            ("--mode", "auto", "hi"),
            ("--agy-arg", "--mode=auto", "hi"),
        ):
            with self.subTest(args=args):
                p = self.run_agy("ask", *args)
                self.assertEqual(p.returncode, 64)
        self.assertEqual(self.ncalls(), 0)

    def test_wrapper_managed_flags_are_refused_as_agy_args(self):
        for flag in ("--model", "--output-format=text", "-p", "--conversation", "--continue", "--log-file"):
            with self.subTest(flag=flag):
                p = self.run_agy("ask", "--agy-arg", flag, "hi")
                self.assertEqual(p.returncode, 64)
                self.assertIn("managed by the wrapper", p.stderr)

    def test_usage_errors(self):
        self.assertEqual(self.run_agy("ask").returncode, 64)
        self.assertEqual(self.run_agy("ask", "--bogus", "hi").returncode, 64)
        self.assertEqual(self.run_agy("ask", "--name", "x", "hi").returncode, 64)  # image-only option
        self.assertEqual(self.run_agy("ask", "--base", "main", "hi").returncode, 64)  # review-only
        self.assertEqual(self.run_agy("ask", "--wait", "soon", "hi").returncode, 64)
        self.assertEqual(self.ncalls(), 0)

    def test_agy_missing(self):
        p = self.run_agy("ask", "hi", env={"AGY_BIN": str(self.tmp / "nope")})
        self.assertEqual(p.returncode, 127)
        self.assertIn("install.sh", p.stderr)

    def test_agy_error_is_reported(self):
        p = self.run_agy("ask", "hi", env={"FAKE_AGY_SCENARIO": "error"})
        self.assertEqual(p.returncode, 1)
        self.assertIn("something broke in the fake", p.stderr)

    def test_unknown_model_points_at_models(self):
        p = self.run_agy("ask", "--model", "gemini-9", "hi", env={"FAKE_AGY_UNKNOWN_MODEL": "gemini-9"})
        self.assertEqual(p.returncode, 1)
        self.assertIn("not recognized", p.stderr)
        self.assertIn("models", p.stderr)
        self.assertEqual(self.ncalls(), 1)  # passthrough names are not retried

    def test_stale_alias_falls_back_to_newest_family_model(self):
        env = {
            "FAKE_AGY_UNKNOWN_MODEL": "Gemini 3.8 Flash (High)",
            "FAKE_AGY_EXTRA_MODELS": "gemini-3.9-flash-high\tGemini 3.9 Flash (High)\n"
            "gemini-3.10-flash-high\tGemini 3.10 Flash (High)\n"
            "gemini-3.10-flash-low\tGemini 3.10 Flash (Low)",
        }
        p = self.run_agy("ask", "--model", "flash", "hi", env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.flag(self.call(1)["args"], "--model"), "Gemini 3.8 Flash (High)")
        self.assertEqual(self.flag(self.call(2)["args"], "--model"), "Gemini 3.10 Flash (High)")
        self.assertIn("no longer offered", p.stderr)
        self.assertIn("model=Gemini 3.10 Flash (High)", p.stdout)

    def test_large_prompt_goes_through_a_file(self):
        big = "x" * 5000
        p = self.run_agy("ask", "--stdin", input=big, env={"AGY_MAX_ARG_BYTES": "2000"})
        self.assertEqual(p.returncode, 0, p.stderr)
        c = self.call(1)
        input_dir = Path(self.flag(c["args"], "--add-dir"))
        self.assertTrue((input_dir / "request.md").read_text().startswith(big))
        self.assertIn(str(input_dir / "request.md"), c["prompt"])
        self.assertLess(len(c["prompt"]), 2000)

    def test_text_mode_without_a_json_helper(self):
        p = self.run_agy("ask", "--model", "opus", "hi", env={"AGY_PLUGIN_JSON": "none"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.flag(self.call(1)["args"], "--output-format"), "text")
        self.assertTrue(p.stdout.startswith("FAKE-OK model=Claude Opus 5.5 (Medium)"))
        self.assertIn("conversation=00000000-0000-4000-8000-000000000001", p.stderr)  # from the log

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_node_json_helper(self):
        p = self.run_agy("ask", "hi", env={"AGY_PLUGIN_JSON": "node"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.startswith("FAKE-OK"))
        self.assertIn("tokens=15", p.stderr)

    def test_non_json_output_is_kept_as_text(self):
        p = self.run_agy("ask", "hi", env={"FAKE_AGY_SCENARIO": "text-only"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.startswith("FAKE-OK"))

    def test_parallel_calls_do_not_serialize_or_touch_settings(self):
        settings = self.agy_home / "settings.json"
        settings.write_text('{\n  "model": "Gemini 4 Argon (High)"\n}\n')
        before = settings.read_bytes()
        env = dict(self.env, FAKE_AGY_SCENARIO="slow", FAKE_AGY_SLEEP="2")
        start = time.time()
        procs = [
            subprocess.Popen(
                [BASH, str(SCRIPT), "ask", "--model", m, "hi"],
                cwd=str(self.work), env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            for m in ("flash", "opus-high", "gpt-oss")
        ]
        outs = [p.communicate(timeout=60) for p in procs]
        elapsed = time.time() - start
        self.assertTrue(all(p.returncode == 0 for p in procs), outs)
        self.assertLess(elapsed, 5.5, "three 2s calls should overlap")
        self.assertEqual(settings.read_bytes(), before)
        self.assertFalse((self.agy_home / ".agy-plugin.lock").exists())
        models = sorted(self.flag(self.call(i)["args"], "--model") for i in (1, 2, 3))
        self.assertEqual(models, ["Claude Opus 5.5 (High)", "GPT-OSS 120B (Medium)", "Gemini 3.8 Flash (High)"])


class ArgsStdin(Base):
    """--args-stdin: what the slash commands send (raw $ARGUMENTS via a heredoc)."""

    def ask(self, raw, kind="ask"):
        p = self.run_agy(kind, "--args-stdin", input=raw)
        return p

    def test_options_then_multiline_text(self):
        p = self.ask("--model opus-high --effort high What is X?\nSecond line")
        self.assertEqual(p.returncode, 0, p.stderr)
        c = self.call(1)
        self.assertEqual(c["prompt"], "What is X?\nSecond line")
        self.assertEqual(self.flag(c["args"], "--model"), "Claude Opus 5.5 (High)")

    def test_quoted_values(self):
        for raw in (
            '--model "Claude Opus 5.5 (Low)" hi',
            "--model 'Claude Opus 5.5 (Low)' hi",
            "--model='Claude Opus 5.5 (Low)' hi",
            '--model="Claude Opus 5.5 (Low)" hi',
        ):
            with self.subTest(raw=raw):
                n = self.ncalls() + 1
                p = self.ask(raw)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(self.flag(self.call(n)["args"], "--model"), "Claude Opus 5.5 (Low)")
                self.assertEqual(self.call(n)["prompt"], "hi")

    def test_text_that_looks_like_options(self):
        cases = {
            "-1 is negative?": "-1 is negative?",
            "--name foo bar": "--name foo bar",  # image-only option is text for ask
            "-- --model is a flag": "--model is a flag",
            "  \n  --model flash   leading space": "leading space",
            'Explain "--model" in agy': 'Explain "--model" in agy',
        }
        for raw, prompt in cases.items():
            with self.subTest(raw=raw):
                n = self.ncalls() + 1
                p = self.ask(raw)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(self.call(n)["prompt"], prompt)

    def test_shell_metacharacters_stay_literal(self):
        raw = "--model flash $(touch pwned) `id` ; rm -rf / && echo $HOME"
        p = self.ask(raw)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.call(1)["prompt"], "$(touch pwned) `id` ; rm -rf / && echo $HOME")
        self.assertFalse((self.work / "pwned").exists())

    def test_refusals_and_errors(self):
        self.assertEqual(self.ask("--dangerously-skip-permissions do it").returncode, 64)
        self.assertEqual(self.ask("--mode auto do it").returncode, 64)
        self.assertEqual(self.ask("--model").returncode, 64)
        self.assertEqual(self.ask("").returncode, 64)
        self.assertEqual(self.ask("--model opus").returncode, 64)  # no text
        self.assertEqual(self.ncalls(), 0)

    def test_background_and_kind_specific_options(self):
        p = self.ask("--background --model sonnet do the thing", kind="task")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Started agy job", p.stdout)
        self.run_agy("wait", "last")
        self.assertTrue(self.call(1)["prompt"].endswith("Task:\ndo the thing"))
        (self.work / "x").mkdir()
        p = self.ask("--name hero --output x a lighthouse", kind="image")
        self.assertEqual(p.returncode, 4)  # the fake made no image in the default scenario
        self.assertIn('file name "hero"', self.call(2)["prompt"])

    def test_job_commands_split_words(self):
        job = self.job_id(self.run_agy("start", "x").stdout)
        self.run_agy("wait", job)
        p = self.run_agy("result", "--args-stdin", input=f"  {job}\n")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.startswith("FAKE-OK"))
        p = self.run_agy("status", "--args-stdin", input="")
        self.assertIn(job, p.stdout)
        p = self.run_agy("cancel", "--args-stdin", input="$(touch pwned)")
        self.assertEqual(p.returncode, 64)
        self.assertFalse((self.work / "pwned").exists())


class Task(Base):
    def test_headless_note_is_prepended(self):
        p = self.run_agy("task", "--model", "sonnet-high", "Fix the bug in calc.py")
        self.assertEqual(p.returncode, 0, p.stderr)
        prompt = self.call(1)["prompt"]
        self.assertTrue(prompt.startswith(HEADLESS_MARK))
        self.assertIn("Do not run shell or terminal commands", prompt)
        self.assertTrue(prompt.endswith("Task:\nFix the bug in calc.py"))

    def test_delegate_is_an_alias(self):
        p = self.run_agy("delegate", "do it")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.call(1)["prompt"].startswith(HEADLESS_MARK))

    def test_raw_sends_the_text_verbatim(self):
        p = self.run_agy("task", "--raw", "Fix the bug")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.call(1)["prompt"], "Fix the bug")

    def test_denied_run_is_recovered_from_the_same_conversation(self):
        p = self.run_agy("task", "--model", "flash-low", "Fix and test", env={"FAKE_AGY_SCENARIO": "deny"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ncalls(), 2)
        first, second = self.call(1), self.call(2)
        cid = "00000000-0000-4000-8000-000000000001"
        self.assertNotIn("--conversation", first["args"])
        self.assertEqual(self.flag(second["args"], "--conversation"), cid)
        self.assertEqual(self.flag(second["args"], "--model"), "Gemini 3.8 Flash (Low)")
        self.assertIn("auto-denied", second["prompt"])
        self.assertEqual(p.stdout, f"RECOVERED REPORT conv={cid}\n")
        self.assertIn("recovered", p.stderr)

    def test_unrecoverable_denial(self):
        p = self.run_agy("task", "Fix and test", env={"FAKE_AGY_SCENARIO": "deny-always"})
        self.assertEqual(p.returncode, 3)
        self.assertEqual(self.ncalls(), 2)
        self.assertIn("without a reply", p.stderr)
        self.assertIn("auto-denied", p.stderr)
        self.assertIn("git status", p.stderr)
        self.assertIn("--resume 00000000-0000-4000-8000-000000000001", p.stderr)

    def test_no_recover(self):
        p = self.run_agy("task", "--no-recover", "Fix and test", env={"FAKE_AGY_SCENARIO": "deny"})
        self.assertEqual(p.returncode, 3)
        self.assertEqual(self.ncalls(), 1)

    def test_empty_reply_without_a_denial(self):
        p = self.run_agy("ask", "hi", env={"FAKE_AGY_SCENARIO": "empty"})
        self.assertEqual(p.returncode, 3)
        self.assertEqual(self.ncalls(), 1)
        self.assertIn("without a reply", p.stderr)


class Research(Base):
    def test_research_prompt(self):
        p = self.run_agy("research", "--model", "argon-high", "state", "of", "WebGPU")
        self.assertEqual(p.returncode, 0, p.stderr)
        prompt = self.call(1)["prompt"]
        self.assertIn("do not modify any files", prompt)
        self.assertIn("Sources (with URLs)", prompt)
        self.assertTrue(prompt.endswith("Topic: state of WebGPU"))
        self.assertEqual(self.flag(self.call(1)["args"], "--model"), "Gemini 4 Argon (High)")


class Review(Base):
    def make_repo(self):
        self.git("init", "-q", "-b", "main")
        (self.work / "app.py").write_text("def add(a, b):\n    return a + b\n")
        self.git("add", "app.py")
        self.git("commit", "-q", "-m", "init")

    def test_reviews_uncommitted_and_untracked_changes(self):
        self.make_repo()
        (self.work / "app.py").write_text("def add(a, b):\n    return a - b\n")
        (self.work / "new_module.py").write_text("print('hello')\n")
        p = self.run_agy("review", "--model", "opus", "focus", "on", "math")
        self.assertEqual(p.returncode, 0, p.stderr)
        prompt = self.call(1)["prompt"]
        self.assertIn("uncommitted changes", prompt)
        self.assertIn("focus on math", prompt)
        self.assertIn("-    return a + b", prompt)
        self.assertIn("+    return a - b", prompt)
        self.assertIn("new_module.py", prompt)
        self.assertIn("do not modify any files", prompt)

    def test_no_untracked(self):
        self.make_repo()
        (self.work / "app.py").write_text("changed\n")
        (self.work / "new_module.py").write_text("print('hello')\n")
        p = self.run_agy("review", "--no-untracked")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("new_module.py", self.call(1)["prompt"])

    def test_base_reviews_the_branch(self):
        self.make_repo()
        self.git("checkout", "-q", "-b", "feature")
        (self.work / "feature.py").write_text("FEATURE = True\n")
        self.git("add", "feature.py")
        self.git("commit", "-q", "-m", "feature")
        p = self.run_agy("review", "--base", "main")
        self.assertEqual(p.returncode, 0, p.stderr)
        prompt = self.call(1)["prompt"]
        self.assertIn("since this branch left main", prompt)
        self.assertIn("+FEATURE = True", prompt)
        self.assertEqual(self.run_agy("review", "--base", "no-such-branch").returncode, 64)

    def test_nothing_to_review(self):
        self.make_repo()
        p = self.run_agy("review")
        self.assertEqual(p.returncode, 1)
        self.assertIn("nothing to review", p.stderr)
        self.assertEqual(self.ncalls(), 0)

    def test_not_a_repository(self):
        p = self.run_agy("review")
        self.assertEqual(p.returncode, 1)
        self.assertIn("git repository", p.stderr)

    def test_large_diff_goes_through_a_file(self):
        self.make_repo()
        (self.work / "app.py").write_text("".join(f"line {i}\n" for i in range(800)))
        p = self.run_agy("review", env={"AGY_MAX_ARG_BYTES": "3000"})
        self.assertEqual(p.returncode, 0, p.stderr)
        c = self.call(1)
        diff_file = Path(self.flag(c["args"], "--add-dir")) / "review.diff"
        self.assertIn("+line 799", diff_file.read_text())
        self.assertIn(str(diff_file), c["prompt"])
        self.assertNotIn("+line 799", c["prompt"])


class Image(Base):
    def test_image_is_found_and_copied(self):
        out = self.work / "assets" / "hero.png"
        p = self.run_agy(
            "image", "--name", "hero", "--output", "assets/hero.png", "a", "red", "circle",
            env={"FAKE_AGY_SCENARIO": "image", "FAKE_AGY_IMAGE_NAME": "hero"},
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        prompt = self.call(1)["prompt"]
        self.assertIn("Description: a red circle", prompt)
        self.assertIn('file name "hero"', prompt)
        saved = self.agy_home / "brain" / "00000000-0000-4000-8000-000000000001" / "hero_1792413076486.png"
        self.assertIn(f"Image saved: {saved}", p.stdout)
        self.assertIn(f"Copied to: {out}", p.stdout)
        self.assertEqual(out.read_bytes(), saved.read_bytes())

    def test_output_directory(self):
        (self.work / "imgs").mkdir()
        p = self.run_agy("image", "--output", "imgs", "a cat", env={"FAKE_AGY_SCENARIO": "image"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue((self.work / "imgs" / "image_1792413076486.png").exists())

    def test_missing_image(self):
        p = self.run_agy("image", "a cat", env={"FAKE_AGY_SCENARIO": "image-missing"})
        self.assertEqual(p.returncode, 4)
        self.assertIn("no generated image was found", p.stderr)


class Jobs(Base):
    def test_background_job_lifecycle(self):
        env = {"FAKE_AGY_SCENARIO": "slow", "FAKE_AGY_SLEEP": "1"}
        t0 = time.time()
        p = self.run_agy("start", "--model", "sonnet", "long", "task", env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertLess(time.time() - t0, 3, "start must return right away")
        job = self.job_id(p.stdout)
        self.assertIn(f"wait {job}", p.stdout)
        status = self.run_agy("status", "--json")
        self.assertEqual(json.loads(status.stdout)[0]["id"], job)
        w = self.run_agy("wait", job, "--timeout", "30")
        self.assertEqual(w.returncode, 0, w.stderr)
        self.assertIn("FAKE-OK model=Claude Sonnet 5.5 (Medium)", w.stdout)
        r = self.run_agy("result", job)
        self.assertEqual((r.returncode, r.stdout), (0, w.stdout))
        info = json.loads(self.run_agy("status", job, "--json").stdout)
        self.assertEqual((info["state"], info["exit"], info["kind"]), ("done", "0", "task"))
        self.assertEqual(info["model_label"], "Claude Sonnet 5.5 (Medium)")
        text = self.run_agy("status").stdout
        self.assertIn(job, text)
        self.assertIn("long task", text)

    def test_wait_for_several_jobs(self):
        env = {"FAKE_AGY_SCENARIO": "slow", "FAKE_AGY_SLEEP": "1"}
        ids = [self.job_id(self.run_agy("start", "--model", m, "x", env=env).stdout) for m in ("flash", "opus", "gpt-oss")]
        t0 = time.time()
        w = self.run_agy("wait", *ids, "--timeout", "30")
        self.assertEqual(w.returncode, 0, w.stderr)
        self.assertLess(time.time() - t0, 6)
        for job, model in zip(ids, ("Gemini 3.8 Flash (High)", "Claude Opus 5.5 (Medium)", "GPT-OSS 120B (Medium)")):
            self.assertIn(f"===== agy job {job} (task, {model}) =====", w.stdout)
            self.assertIn(f"FAKE-OK model={model}", w.stdout)

    def test_wait_all_and_mixed_outcomes(self):
        ok = self.job_id(self.run_agy("start", "x", env={"FAKE_AGY_SCENARIO": "slow", "FAKE_AGY_SLEEP": "1"}).stdout)
        bad = self.job_id(self.run_agy("start", "x", env={"FAKE_AGY_SCENARIO": "error"}).stdout)
        time.sleep(0.3)
        w = self.run_agy("wait", ok, bad, "--timeout", "30")
        self.assertEqual(w.returncode, 1)
        self.assertIn("something broke", w.stderr)
        self.assertIn("FAKE-OK", w.stdout)
        slow = self.job_id(self.run_agy("start", "x", env={"FAKE_AGY_SCENARIO": "slow", "FAKE_AGY_SLEEP": "5"}).stdout)
        w = self.run_agy("wait", "all", "--timeout", "1")
        self.assertEqual(w.returncode, 75)
        self.assertIn(slow, w.stdout)
        self.assertNotIn(f"agy job {ok} ", w.stdout)
        self.assertEqual(self.run_agy("cancel", slow).returncode, 0)
        self.assertIn("No running agy jobs", self.run_agy("wait", "all").stdout)

    def test_wait_timeout_and_result_while_running(self):
        p = self.run_agy("start", "x", env={"FAKE_AGY_SCENARIO": "slow", "FAKE_AGY_SLEEP": "5"})
        job = self.job_id(p.stdout)
        w = self.run_agy("wait", job, "--timeout", "1")
        self.assertEqual(w.returncode, 75)
        self.assertIn("still running", w.stdout)
        r = self.run_agy("result", "last")
        self.assertEqual(r.returncode, 75)
        self.assertEqual(json.loads(self.run_agy("status", "last", "--json").stdout)["state"], "running")

    def test_foreground_wait_limit_leaves_the_job_running(self):
        p = self.run_agy("ask", "--wait", "1", "x", env={"FAKE_AGY_SCENARIO": "slow", "FAKE_AGY_SLEEP": "3"})
        self.assertEqual(p.returncode, 75)
        self.assertIn("still running", p.stdout)
        w = self.run_agy("wait", "last", "--timeout", "30")
        self.assertEqual(w.returncode, 0, w.stderr)
        self.assertTrue(w.stdout.startswith("FAKE-OK"))

    def check_cancel(self, detach):
        env = {"FAKE_AGY_SCENARIO": "slow", "FAKE_AGY_SLEEP": "30", "AGY_DETACH": detach}
        p = self.run_agy("start", "x", env=env)
        job = self.job_id(p.stdout)
        jd = self.state / "jobs" / job
        for _ in range(100):
            if (jd / "agy.pid").exists():
                break
            time.sleep(0.05)
        agy_pid = int((jd / "agy.pid").read_text())
        c = self.run_agy("cancel", job, env=env)
        self.assertEqual(c.returncode, 0, c.stderr)
        self.assertIn("Cancelled", c.stdout)
        self.assertEqual((jd / "exit_code").read_text().strip(), "130")
        info = json.loads(self.run_agy("status", job, "--json").stdout)
        self.assertEqual(info["state"], "cancelled")
        time.sleep(0.3)
        with self.assertRaises(ProcessLookupError):
            os.kill(agy_pid, 0)
        self.assertEqual(self.run_agy("result", job).returncode, 130)

    def test_cancel_setsid(self):
        if not shutil.which("setsid"):
            self.skipTest("setsid not installed")
        self.check_cancel("setsid")

    @unittest.skipUnless(shutil.which("perl"), "perl not installed")
    def test_cancel_perl(self):
        self.check_cancel("perl")

    def test_cancel_nohup(self):
        self.check_cancel("nohup")

    def test_job_references(self):
        a = self.job_id(self.run_agy("start", "first").stdout)
        self.run_agy("wait", a)
        b = self.job_id(self.run_agy("start", "second").stdout)
        self.run_agy("wait", b)
        prefix = a[:-1]
        if not b.startswith(prefix):  # a unique prefix finds the job
            self.assertEqual(self.run_agy("result", prefix).stdout, self.run_agy("result", a).stdout)
        self.assertEqual(self.run_agy("result", "nope-nope").returncode, 1)
        self.assertEqual(self.run_agy("result", "../x").returncode, 64)
        self.assertEqual(json.loads(self.run_agy("status", "last", "--json").stdout)["id"], b)

    def test_prune(self):
        job = self.job_id(self.run_agy("start", "x").stdout)
        self.run_agy("wait", job)
        p = self.run_agy("prune", "--days", "0")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.job_dirs(), [])

    def test_no_jobs(self):
        self.assertIn("No agy jobs yet", self.run_agy("status").stdout)
        self.assertEqual(self.run_agy("status", "--json").stdout.strip(), "[]")
        self.assertEqual(self.run_agy("result").returncode, 1)

    def test_shim_uses_short_name_in_hints(self):
        p = self.run_agy(cmd=[str(SHIM), "start", "x"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("agy-run wait ", p.stdout)


class Utility(Base):
    def test_check_reports_a_ready_install(self):
        (self.agy_home / "settings.json").write_text('{"model": "Gemini 4 Argon (High)"}')
        p = self.run_agy("check")
        self.assertEqual(p.returncode, 0, p.stderr)
        info = json.loads(p.stdout)
        self.assertTrue(info["installed"])
        self.assertEqual(info["auth"], "ok")
        self.assertEqual(info["models_available"], 13)
        self.assertEqual(info["version"], "1.4.2-fake")
        self.assertEqual(info["default_model"], "Gemini 4 Argon (High)")
        self.assertEqual(info["warnings"], [])

    def test_check_without_agy(self):
        info = json.loads(self.run_agy("check", env={"AGY_BIN": str(self.tmp / "nope")}).stdout)
        self.assertFalse(info["installed"])
        self.assertIn("install.sh", info["error"])

    def test_check_warns_about_old_plugin_backup(self):
        (self.agy_home / "settings.json.agy-plugin.bak").write_text("{}")
        info = json.loads(self.run_agy("check").stdout)
        self.assertEqual(len(info["warnings"]), 1)
        self.assertIn("antigravity-plugin-cc", info["warnings"][0])

    def test_models_lists_aliases_and_live_models(self):
        p = self.run_agy("models")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("flash-high", p.stdout)
        self.assertIn("(flash = High)", p.stdout)
        self.assertIn("gpt-oss-120b-medium", p.stdout)
        self.assertNotIn("Fetching", p.stdout)

    def test_usage(self):
        p = self.run_agy("usage")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Weekly Limit Remaining", p.stdout)
        self.assertIn("resets 2026-10-26T12:22:43Z", p.stdout)

    def test_help_and_unknown_subcommand(self):
        p = self.run_agy("help")
        self.assertEqual(p.returncode, 0)
        for word in ("/agy:delegate", "argon-high", "sonnet-low", "gpt-oss", "--effort", "--background", "cancel"):
            self.assertIn(word, p.stdout)
        bad = self.run_agy("frobnicate")
        self.assertEqual(bad.returncode, 64)
        self.assertIn("unknown subcommand", bad.stderr)
        self.assertEqual(self.run_agy("version").stdout.strip(), "agy-run.sh 1.0.0")


class Packaging(unittest.TestCase):
    def test_versions_agree(self):
        plugin = json.loads((ROOT / "plugins/agy/.claude-plugin/plugin.json").read_text())
        market = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
        script_version = next(
            line.split('"')[1] for line in SCRIPT.read_text().splitlines() if line.startswith("AGY_PLUGIN_VERSION=")
        )
        self.assertEqual(plugin["version"], script_version)
        self.assertEqual(market["plugins"][0]["version"], script_version)
        self.assertEqual(market["metadata"]["version"], script_version)
        self.assertEqual(market["plugins"][0]["name"], plugin["name"])

    def test_scripts_are_executable_and_parse(self):
        for path in (SCRIPT, SHIM, FAKE):
            with self.subTest(path=path.name):
                self.assertTrue(os.access(path, os.X_OK))
                subprocess.run([BASH, "-n", str(path)], check=True)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck not installed")
    def test_shellcheck(self):
        subprocess.run(
            ["shellcheck", "-S", "warning", str(SCRIPT), str(SHIM), str(FAKE)], check=True
        )

    def test_skill_and_agent_frontmatter(self):
        plugin_dir = ROOT / "plugins" / "agy"
        files = list((plugin_dir / "skills").glob("*/SKILL.md")) + list((plugin_dir / "agents").glob("*.md"))
        self.assertTrue(files)
        for f in files:
            with self.subTest(file=str(f.relative_to(ROOT))):
                text = f.read_text()
                self.assertTrue(text.startswith("---\n"))
                front = text.split("---\n", 2)[1]
                self.assertRegex(front, r"(?m)^description: \S")
                self.assertNotIn("dangerously-skip-permissions\n", front)

    @unittest.skipUnless(shutil.which("claude"), "claude CLI not installed")
    def test_claude_plugin_validate(self):
        for target in (ROOT, ROOT / "plugins" / "agy"):
            with self.subTest(target=str(target)):
                p = subprocess.run(
                    ["claude", "plugin", "validate", "--strict", str(target)],
                    capture_output=True, text=True, timeout=120,
                )
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
