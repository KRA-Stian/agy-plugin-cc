"""Live tests: the wrapper against the real agy (uses your agy quota).

    AGY_LIVE=1 python3 -m unittest tests/live_test_agy.py -v

The model matrix runs every alias in parallel and checks, from agy's own log,
that each one reached the intended model and thinking level. Everything else
uses Gemini 3.8 Flash (Low) to keep the cost down.
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
CHEAP = "flash-low"

MATRIX = {
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


def setUpModule():
    if os.environ.get("AGY_LIVE") != "1":
        raise unittest.SkipTest("set AGY_LIVE=1 to run live agy tests")
    if not shutil.which("agy") and not os.environ.get("AGY_BIN"):
        raise unittest.SkipTest("agy is not installed")


class Live(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agy-live-"))
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("AGY_PLUGIN_", "AGY_WAIT", "AGY_DETACH"))}
        self.env["AGY_PLUGIN_HOME"] = str(self.tmp / "state")

    def tearDown(self):
        self.run_agy("cancel", "all")
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_agy(self, *args, input=None, cwd=None, timeout=900):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            input=input,
            stdin=None if input is not None else subprocess.DEVNULL,
            capture_output=True,
            text=True,
            cwd=str(cwd or self.work),
            env=self.env,
            timeout=timeout,
        )

    def job_id(self, stdout):
        return next(w for w in stdout.split() if len(w) == 20 and w[8] == "-" and w[15] == "-")

    def status(self, job):
        return json.loads(self.run_agy("status", job, "--json").stdout)

    def git_repo(self, files):
        for name, text in files.items():
            (self.work / name).write_text(text)
        for cmd in (["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@e", "commit", "-q", "-m", "init"]):
            subprocess.run(["git", *cmd], cwd=self.work, check=True, capture_output=True)

    # -- models ------------------------------------------------------------

    def test_every_alias_reaches_its_model(self):
        jobs = {}
        for alias in MATRIX:
            p = self.run_agy("ask", "--background", "--model", alias, "Reply with exactly the word: ok")
            self.assertEqual(p.returncode, 0, p.stderr)
            jobs[alias] = self.job_id(p.stdout)
        w = self.run_agy("wait", *jobs.values(), "--timeout", "600")
        self.assertEqual(w.returncode, 0, w.stdout + w.stderr)
        for alias, label in MATRIX.items():
            with self.subTest(alias=alias):
                info = self.status(jobs[alias])
                self.assertEqual(info["state"], "done")
                self.assertEqual(info["model_label"], label)  # what agy itself logged
                out = self.run_agy("result", jobs[alias]).stdout
                self.assertIn("ok", out.lower())

    def test_effort_flag(self):
        for args, label in (
            (("--model", "sonnet", "--effort", "low"), "Claude Sonnet 5.5 (Low)"),
            (("--model", "flash", "--thinking", "medium"), "Gemini 3.8 Flash (Medium)"),
            (("--model", "Claude Opus 5.5 (Low)"), "Claude Opus 5.5 (Low)"),
        ):
            with self.subTest(args=args):
                p = self.run_agy("ask", *args, "Reply with exactly the word: ok")
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn(f'model="{label}"', p.stderr)

    def test_unknown_model_is_rejected_by_agy(self):
        p = self.run_agy("ask", "--model", "gemini-0-nonexistent", "hi")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not recognized", p.stderr)
        self.assertIn("models", p.stderr)

    # -- conversations and tasks -------------------------------------------

    def test_resume_follow_up(self):
        p = self.run_agy("ask", "--model", CHEAP, "Remember the codeword TANGERINE-42. Reply only with: stored")
        self.assertEqual(p.returncode, 0, p.stderr)
        cid = next(w.split("=", 1)[1] for w in p.stderr.split() if w.startswith("conversation="))
        q = self.run_agy("ask", "--resume", cid, "What codeword did I give you? Reply with just the codeword.")
        self.assertEqual(q.returncode, 0, q.stderr)
        self.assertIn("TANGERINE-42", q.stdout)

    def test_task_edits_files_and_reports(self):
        self.git_repo({"calc.py": "def add(a, b):\n    return a - b\n"})
        p = self.run_agy("task", "--model", CHEAP, "Fix the bug in calc.py so add() returns the sum.")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("a + b", (self.work / "calc.py").read_text())
        self.assertTrue(p.stdout.strip())

    def test_denied_command_is_recovered(self):
        self.git_repo({"calc.py": "def add(a, b):\n    return a - b\n"})
        p = self.run_agy(
            "task", "--raw", "--model", CHEAP,
            'Fix the bug in calc.py so add() returns the sum, then run `python3 -c "import calc; print(calc.add(2,3))"` to verify.',
        )
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("a + b", (self.work / "calc.py").read_text())
        self.assertTrue(p.stdout.strip())
        # agy usually tries the command, gets auto-denied and is resumed; if it
        # skipped the command there is nothing to recover, which is fine too.
        if "recovered" not in p.stderr:
            print("\n  (agy did not try the command this time; recovery not exercised)")

    def test_review(self):
        self.git_repo({"calc.py": "def add(a, b):\n    return a + b\n"})
        (self.work / "calc.py").write_text("def add(a, b):\n    return a - b\n")
        p = self.run_agy("review", "--model", CHEAP)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout.lower(), r"subtract|minus|a - b|sum")
        self.assertIn("a - b", (self.work / "calc.py").read_text())  # read-only

    def test_research(self):
        p = self.run_agy("research", "--model", CHEAP, "What is the latest stable release of the Go programming language?")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r"https?://")

    def test_image(self):
        out = self.work / "assets" / "circle.png"
        p = self.run_agy("image", "--model", CHEAP, "--name", "red_circle", "--output", str(out),
                         "a flat red circle on a plain white background")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Image saved:", p.stdout)
        saved = Path(p.stdout.split("Image saved:", 1)[1].split()[0])
        self.assertTrue(saved.is_file())
        self.assertTrue(out.is_file())
        self.assertEqual(out.read_bytes(), saved.read_bytes())

    def test_background_cancel(self):
        p = self.run_agy("start", "--model", CHEAP,
                         "Write a 3000-word essay on the history of the printing press into essay.md.")
        job = self.job_id(p.stdout)
        time.sleep(4)
        c = self.run_agy("cancel", job)
        self.assertEqual(c.returncode, 0, c.stderr)
        self.assertEqual(self.status(job)["state"], "cancelled")

    # -- utility -----------------------------------------------------------

    def test_check_models_usage(self):
        info = json.loads(self.run_agy("check").stdout)
        self.assertTrue(info["installed"])
        self.assertEqual(info["auth"], "ok", info["error"])
        self.assertGreaterEqual(info["models_available"], 13)
        models = self.run_agy("models").stdout
        for label in set(MATRIX.values()):
            self.assertIn(label, models)
        usage = self.run_agy("usage")
        self.assertEqual(usage.returncode, 0, usage.stderr)
        self.assertIn("resets", usage.stdout)


if __name__ == "__main__":
    unittest.main()
