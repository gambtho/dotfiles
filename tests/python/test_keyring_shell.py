"""Exercise real zsh startup and hidden input without the operator's keyring."""
import getpass
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "linux" and shutil.which("zsh"), "Linux zsh startup integration")
class KeyringShellTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = pathlib.Path(temporary.name)
        self.fixture = self.home / "dotfiles"
        (self.fixture / "libexec").mkdir(parents=True)
        (self.fixture / "core/shell").mkdir(parents=True)
        (self.fixture / "core/shell/load-custom.zsh").write_text("")
        helper = self.fixture / "libexec/keyring"
        helper.write_text(f'''import runpy, os, sys, time
m = runpy.run_path({str(ROOT / "libexec/keyring")!r})
t = runpy.run_path({str(ROOT / "tests/python/test_keyring.py")!r})
from types import SimpleNamespace
module = SimpleNamespace(**m)
bus = t["FakeBus"](module)
bus.locked = os.environ.get("TEST_LOCKED") == "1"
def provider():
    if os.environ.get("TEST_SLOW_INSPECT") == "1":
        print("INSPECTING", file=sys.stderr, flush=True)
        time.sleep(30)
    return m["GnomeKeyring"](bus)
raise SystemExit(m["startup"](provider))
''')
        runtime = self.home / "run"
        runtime.mkdir(mode=0o700)
        cache = self.home / ".cache"
        cache.mkdir()
        # The input must complete before instant-prompt initialization.
        (cache / f"p10k-instant-prompt-{getpass.getuser()}.zsh").write_text("print -r -- INSTANT-PROMPT\n")
        (self.home / ".zshrc").write_text(
            f'[[ -z $TEST_PLATFORM ]] || OSTYPE=$TEST_PLATFORM\nsource "{ROOT / "core/shell/zshrc.symlink"}"\nprint -r -- INIT-COMPLETE\nexit 0\n'
        )
        self.env = dict(os.environ, HOME=str(self.home), ZDOTDIR=str(self.home),
                        DOTFILES=str(self.fixture), XDG_RUNTIME_DIR=str(runtime),
                        XDG_CACHE_HOME=str(cache), TEST_LOCKED="1",
                        DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(runtime / "bus"))
        for name in ("CI", "GH_PROMPT_DISABLED", "DOTFILES_KEYRING_PROMPT"):
            self.env.pop(name, None)

    def terminal(self, answer=b"test-password\n", extra_env=None, args=(), trigger=b"Keyring password:"):
        pid, terminal = pty.fork()
        if pid == 0:
            os.execvpe("zsh", ["zsh", "-d", *args], dict(self.env, **(extra_env or {})))
        output = b""
        sent = False
        reaped = False
        try:
            until = time.monotonic() + 6
            while time.monotonic() < until:
                if select.select([terminal], [], [], 0.05)[0]:
                    try:
                        output += os.read(terminal, 4096)
                    except OSError:
                        pass
                if trigger in output and not sent:
                    os.write(terminal, answer)
                    sent = True
                child, status = os.waitpid(pid, os.WNOHANG)
                if child:
                    reaped = True
                    # Drain startup output written immediately before exit.
                    while select.select([terminal], [], [], 0)[0]:
                        try:
                            data = os.read(terminal, 4096)
                        except OSError:
                            break
                        if not data:
                            break
                        output += data
                    return os.waitstatus_to_exitcode(status), output
            self.fail(f"shell initialization stalled: {output!r}")
        finally:
            if not reaped:
                os.killpg(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(terminal)

    def test_locked_human_terminal_prompts_before_instant_prompt(self):
        code, output = self.terminal()
        self.assertEqual(code, 0, output)
        self.assertIn(b"Keyring password:", output)
        self.assertLess(output.index(b"Keyring password:"), output.index(b"INSTANT-PROMPT"))
        self.assertIn(b"INIT-COMPLETE", output)
        self.assertNotIn(b"test-password", output)

    def test_unlocked_terminal_is_quiet(self):
        code, output = self.terminal(extra_env={"TEST_LOCKED": "0"})
        self.assertEqual(code, 0, output)
        self.assertNotIn(b"keyring", output.lower())
        self.assertIn(b"INIT-COMPLETE", output)

    def test_explicit_automation_opt_out_and_ci_are_quiet(self):
        for environment in ({"DOTFILES_KEYRING_PROMPT": "0"}, {"CI": "1"},
                            {"GH_PROMPT_DISABLED": "1"}, {"TEST_PLATFORM": "darwin24"}):
            with self.subTest(environment=environment):
                code, output = self.terminal(extra_env=environment)
                self.assertEqual(code, 0, output)
                self.assertNotIn(b"Keyring password:", output)

    def test_interactive_command_shell_never_prompts(self):
        code, output = self.terminal(args=("-ic", "print COMMAND"))
        self.assertEqual(code, 0, output)
        self.assertNotIn(b"Keyring password:", output)

    def test_ctrl_c_and_ctrl_z_cancel_without_aborting_initialization(self):
        for control in (b"\x03", b"\x1a"):
            with self.subTest(control=control):
                code, output = self.terminal(answer=control)
                self.assertEqual(code, 0, output)
                self.assertIn(b"Keyring password:", output)
                self.assertIn(b"INIT-COMPLETE", output)
                self.assertNotIn(b"Traceback", output)

    def test_early_interrupt_cancels_inspection_without_traceback_or_stopped_lock_holder(self):
        for control in (b"\x03", b"\x1a"):
            with self.subTest(control=control):
                code, output = self.terminal(answer=control, extra_env={"TEST_SLOW_INSPECT": "1"},
                                             trigger=b"INSPECTING")
                self.assertEqual(code, 0, output)
                self.assertIn(b"INIT-COMPLETE", output)
                self.assertNotIn(b"Traceback", output)
                self.assertNotIn(b"Keyring password:", output)
        # A cancelled inspector must release the prompt lock for the next shell.
        code, output = self.terminal()
        self.assertEqual(code, 0, output)
        self.assertIn(b"Keyring password:", output)

    def test_noninteractive_source_never_prompts(self):
        result = subprocess.run(["zsh", "-dfc", f'source "{ROOT / "core/shell/zshrc.symlink"}"; print DONE'],
                                env=self.env, capture_output=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(b"Keyring", result.stderr)
        self.assertIn(b"DONE", result.stdout)


if __name__ == "__main__":
    unittest.main()
