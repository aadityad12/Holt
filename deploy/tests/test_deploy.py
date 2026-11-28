"""Tests for the files that deploy/provision.sh installs.

Run with: python3 -m unittest discover -s deploy/tests
"""

import getpass
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import unittest
from pathlib import Path

DEPLOY = Path(__file__).resolve().parent.parent
FILES = DEPLOY / "files"
AGENTCTL = FILES / "agentctl"
GUARD_HOOK = FILES / "holt-guard-hook"
SUDOERS = FILES / "holt-agentctl.sudoers"
PROVISION = DEPLOY / "provision.sh"


def load_script_module(name: str, path: Path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


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


class GuardHookTest(unittest.TestCase):
    def test_runs_in_isolated_mode_without_shell(self) -> None:
        source = GUARD_HOOK.read_text()
        self.assertEqual(source.splitlines()[0], "#!/usr/bin/python3 -I")
        for banned in ["subprocess", "os.system", "os.popen", "shell=True", "eval(", "exec("]:
            with self.subTest(banned=banned):
                self.assertNotIn(banned, source)

    def test_enforces_only_for_target_user_and_fails_closed(self) -> None:
        mod = load_script_module("holt_guard_hook", GUARD_HOOK)
        me = getpass.getuser()
        my_uid = os.geteuid()
        self.assertTrue(mod.should_enforce(my_uid, target_user=me))
        self.assertFalse(mod.should_enforce(my_uid + 1, target_user=me))
        self.assertTrue(mod.should_enforce(my_uid, target_user="nonexistent-holt-user-xyz"))


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


class ProvisionSafetyTest(unittest.TestCase):
    def test_refuses_symlinks_in_ensure_helpers(self) -> None:
        source = PROVISION.read_text()
        self.assertIn("refuse_symlink", source)
        self.assertIn("chown -h", source)

    def test_never_uses_root_ensure_dir_or_file_inside_home_agent(self) -> None:
        for lineno, line in enumerate(PROVISION.read_text().splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            self.assertNotRegex(
                stripped,
                r"\b(ensure_dir|ensure_file|chown|chmod)\b.*/home/agent/",
                f"line {lineno} appears to run a root helper inside /home/agent/: {stripped}",
            )


if __name__ == "__main__":
    unittest.main()
