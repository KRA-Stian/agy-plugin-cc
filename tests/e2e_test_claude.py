"""End-to-end tests: Claude Code with the plugin loaded, against the real agy.

    AGY_E2E=1 python3 -m unittest tests/e2e_test_claude.py -v

Each test runs `claude -p --plugin-dir plugins/agy` in a scratch git repo and
checks the tool calls Claude made and what came out. They cost Claude and agy
usage (Gemini 3.8 Flash (Low) for agy). AGY_E2E_MODEL picks Claude's model
(default: sonnet).
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "agy"
MODEL = os.environ.get("AGY_E2E_MODEL", "sonnet")


def setUpModule():
    if os.environ.get("AGY_E2E") != "1":
        raise unittest.SkipTest("set AGY_E2E=1 to run Claude Code end-to-end tests")
    for tool in ("claude", "agy"):
        if not shutil.which(tool):
            raise unittest.SkipTest(f"{tool} is not installed")


class Session:
    """Parsed stream-json output of one `claude -p` run."""

    def __init__(self, lines):
        self.tool_uses, self.results, self.texts, self.denials = [], [], [], []
        self.final = ""
        for line in lines:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") == "assistant":
                for c in d["message"]["content"]:
                    if c.get("type") == "tool_use":
                        self.tool_uses.append((c["name"], c["input"]))
                    elif c.get("type") == "text":
                        self.texts.append(c["text"])
            elif d.get("type") == "user":
                for c in d["message"].get("content", []):
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        content = c.get("content")
                        if isinstance(content, list):
                            content = " ".join(x.get("text", "") for x in content if isinstance(x, dict))
                        self.results.append(str(content))
            elif d.get("type") == "result":
                self.final = d.get("result") or ""
                self.denials += d.get("permission_denials") or []

    def bash_commands(self):
        return [i.get("command", "") for n, i in self.tool_uses if n == "Bash"]

    def agents(self):
        return [i.get("subagent_type") for n, i in self.tool_uses if n == "Agent"]


class E2E(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="agy-e2e-"))
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        (self.repo / "calc.py").write_text("def add(a, b):\n    return a - b\n\n\ndef mul(a, b):\n    return a * b\n")
        for cmd in (["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@e", "commit", "-q", "-m", "init"]):
            subprocess.run(["git", *cmd], cwd=self.repo, check=True, capture_output=True)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("AGY_PLUGIN_", "AGY_WAIT"))}
        self.env["AGY_PLUGIN_HOME"] = str(self.tmp / "state")

    def tearDown(self):
        subprocess.run(["bash", str(PLUGIN / "scripts" / "agy-run.sh"), "cancel", "all"],
                       env=self.env, capture_output=True, stdin=subprocess.DEVNULL)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def claude(self, prompt, *extra):
        # extra first: --allowedTools takes a variadic list that must not swallow the prompt
        p = subprocess.run(
            ["claude", "-p", *extra, "--plugin-dir", str(PLUGIN), "--model", MODEL,
             "--output-format", "stream-json", "--verbose", prompt],
            cwd=self.repo, env=self.env, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=1200,
        )
        self.assertEqual(p.returncode, 0, p.stderr[-2000:])
        return Session(p.stdout.splitlines())

    def agy_run(self, *args):
        return subprocess.run(["bash", str(PLUGIN / "scripts" / "agy-run.sh"), *args], cwd=self.repo,
                              env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900)

    # -- slash commands ------------------------------------------------------

    def test_help(self):
        s = self.claude("/agy:help")
        self.assertTrue(any("agy-run" in c and "help" in c for c in s.bash_commands()), s.tool_uses)
        self.assertIn("/agy:delegate", s.final)
        self.assertIn("argon-high", s.final)
        self.assertEqual(s.denials, [])

    def test_ask(self):
        s = self.claude("/agy:ask --model flash-low What is 17+25? Reply with just the number.")
        self.assertTrue(any("ask --args-stdin" in c for c in s.bash_commands()), s.tool_uses)
        self.assertIn("42", s.final)
        self.assertIn("Gemini 3.8 Flash (Low)", " ".join(s.results))
        self.assertEqual(s.denials, [])

    def test_delegate_through_runner(self):
        s = self.claude("/agy:delegate --model flash-low Fix the bug in calc.py so that add() returns the sum. Keep mul() unchanged.")
        self.assertIn("agy:runner", s.agents())
        code = (self.repo / "calc.py").read_text()
        self.assertIn("return a + b", code)
        self.assertIn("return a * b", code)
        self.assertEqual(s.denials, [])

    def test_delegate_background_then_result(self):
        s = self.claude("/agy:delegate --background --model flash-low Create a file notes.txt containing only the word pineapple.")
        self.assertNotIn("agy:runner", s.agents())
        self.assertTrue(any("task --args-stdin" in c for c in s.bash_commands()), s.tool_uses)
        w = self.agy_run("wait", "last", "--timeout", "600")
        self.assertEqual(w.returncode, 0, w.stderr)
        self.assertIn("pineapple", (self.repo / "notes.txt").read_text().lower())
        r = self.claude("/agy:result")
        self.assertTrue(any("result" in c for c in s.bash_commands() + r.bash_commands()))
        self.assertTrue(r.final.strip())

    def test_review(self):
        (self.repo / "calc.py").write_text("def add(a, b):\n    return a + b + 1\n\n\ndef mul(a, b):\n    return a * b\n")
        s = self.claude("/agy:review --model flash-low focus on correctness")
        self.assertTrue(any("review --args-stdin" in c for c in s.bash_commands()), s.tool_uses)
        self.assertRegex(s.final.lower(), r"\+ 1|off.by.one|add")
        self.assertEqual(s.denials, [])

    def test_status_and_models(self):
        self.agy_run("ask", "--model", "flash-low", "Reply with exactly: ok")
        s = self.claude("/agy:status")
        self.assertIn("ask", s.final)
        m = self.claude("/agy:models")
        self.assertIn("sonnet-high", m.final)

    # -- natural language ----------------------------------------------------

    def test_natural_language_fan_out(self):
        s = self.claude(
            'Spin up two Antigravity (agy) agents in parallel, both on the flash-low model: one creates hello.py '
            'that prints "hello", the other creates bye.py that prints "bye". Wait for both and tell me what they '
            'did. Do not write the files yourself.',
            "--allowedTools", "Bash(agy-run *)",
        )
        self.assertIn('print("hello")', (self.repo / "hello.py").read_text())
        self.assertIn('print("bye")', (self.repo / "bye.py").read_text())
        self.assertFalse(any(n in ("Write", "Edit") for n, _ in s.tool_uses))

    def test_natural_language_delegation_in_auto_mode(self):
        s = self.claude(
            "Have agy fix the bug in calc.py using the sonnet-low model. Don't edit the file yourself.",
            "--permission-mode", "auto",
        )
        self.assertIn("return a + b", (self.repo / "calc.py").read_text())
        self.assertFalse(any(n in ("Write", "Edit") for n, _ in s.tool_uses))
        self.assertIn("Claude Sonnet 5.5 (Low)", " ".join(s.results))


if __name__ == "__main__":
    unittest.main()
