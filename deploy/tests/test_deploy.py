"""Tests for the files that deploy/provision.sh installs.

Run with: python3 -m unittest discover -s deploy/tests
"""

import getpass
import subprocess
import sys
import unittest
from pathlib import Path

FILES = Path(__file__).resolve().parent.parent / "files"
AGENTCTL = FILES / "agentctl"
SUDOERS = FILES / "holt-agentctl.sudoers"


def run_agentctl(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(AGENTCTL), *args],
        capture_output=True,
        text=True,
        check=False,
    )


class AgentctlTest(unittest.TestCase):
    def test_ping_prints_the_current_user(self) -> None:
        result = run_agentctl("ping")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, getpass.getuser() + "\n")

    def test_no_subcommand_is_refused(self) -> None:
        result = run_agentctl()
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing subcommand", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_bad_subcommands_are_refused(self) -> None:
        for name in [
            "pong",
            "PING",
            "ping\n",
            " ping",
            "ping;id",
            "$(id)",
            "../ping",
            "-h",
            "--help",
            "",
            "a" * 33,
        ]:
            with self.subTest(name=name):
                result = run_agentctl(name)
                self.assertEqual(result.returncode, 2)
                self.assertIn("unknown subcommand", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_ping_refuses_arguments(self) -> None:
        for args in [["x"], ["--user", "root"], [""]]:
            with self.subTest(args=args):
                result = run_agentctl("ping", *args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("ping takes no arguments", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_too_many_arguments_are_refused(self) -> None:
        result = run_agentctl("ping", *["x"] * 20)
        self.assertEqual(result.returncode, 2)
        self.assertIn("too many arguments", result.stderr)

    def test_never_uses_a_shell(self) -> None:
        source = AGENTCTL.read_text()
        for banned in ["subprocess", "os.system", "os.popen", "shell=True", "eval(", "exec("]:
            with self.subTest(banned=banned):
                self.assertNotIn(banned, source)

    def test_runs_in_isolated_mode(self) -> None:
        first_line = AGENTCTL.read_text().splitlines()[0]
        self.assertEqual(first_line, "#!/usr/bin/python3 -I")


class SudoersTest(unittest.TestCase):
    def test_contains_only_the_agentctl_rule(self) -> None:
        rules = [
            line.strip()
            for line in SUDOERS.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        self.assertEqual(
            rules, ["holt ALL=(agent) NOPASSWD: /usr/local/libexec/holt/agentctl *"]
        )


if __name__ == "__main__":
    unittest.main()
