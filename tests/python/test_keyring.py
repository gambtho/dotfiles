import contextlib
import importlib.machinery
import importlib.util
import io
import os
import pathlib
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_helper():
    path = ROOT / "libexec" / "keyring"
    if not path.exists():
        raise AssertionError("private keyring helper has not been implemented")
    loader = importlib.machinery.SourceFileLoader("dotfiles_keyring", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FakeBus:
    """A strict, dependency-free Secret Service protocol boundary."""

    def __init__(self, module):
        self.module = module
        self.owner: str | None = ":1.42"
        self.gnome_owner = ":1.42"
        self.locked = True
        self.collection = "/org/freedesktop/secrets/collection/login"
        self.methods = '<node><interface name="org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"><method name="UnlockWithMasterPassword"><arg direction="in" type="o"/><arg direction="in" type="(oayays)"/></method></interface></node>'
        self.calls = []
        self.fail_unlock = False
        self.stay_locked = False
        self.fail_close = False

    def call(self, destination, path, interface, method, signature, args):
        self.calls.append((destination, path, interface, method, signature, args))
        if method == "GetNameOwner":
            return (
                self.owner
                if args[0] == "org.freedesktop.secrets"
                else self.gnome_owner,
            )
        if method == "StartServiceByName":
            self.owner = self.gnome_owner = ":1.42"
            return (1,)
        if destination != self.owner:
            raise self.module.KeyringError("provider disappeared")
        if method == "Introspect":
            return (self.methods,)
        if method == "ReadAlias":
            return (self.collection,)
        if method == "Get":
            return (self.locked,)
        if method == "OpenSession":
            return ("", "/org/freedesktop/secrets/session/test")
        if method == "UnlockWithMasterPassword":
            if self.fail_unlock:
                raise self.module.KeyringError("password rejected")
            secret = args[1]
            if secret[2] != list(b"test-password"):
                raise self.module.KeyringError("password rejected")
            self.locked = self.stay_locked
            return ()
        if method == "Close":
            if self.fail_close:
                raise self.module.KeyringError("session close failed")
            return ()
        raise AssertionError(f"unexpected protocol call: {method}")


class KeyringTests(unittest.TestCase):
    def setUp(self):
        self.module = load_helper()
        self.bus = FakeBus(self.module)
        self.provider = self.module.GnomeKeyring(self.bus)
        self.output = io.StringIO()

    def run_command(self, command, password="test-password", prompt=None):
        with (
            contextlib.redirect_stdout(self.output),
            contextlib.redirect_stderr(self.output),
        ):
            return self.module.run(command, self.provider, prompt or (lambda: password))

    def methods(self):
        return [call[3] for call in self.bus.calls]

    def test_check_locked_never_activates_or_opens_secret_session(self):
        self.assertEqual(self.run_command("check"), 1)
        self.assertIn("locked", self.output.getvalue().lower())
        self.assertNotIn("StartServiceByName", self.methods())
        self.assertNotIn("OpenSession", self.methods())

    def test_inactive_check_does_not_activate(self):
        self.bus.owner = None
        self.assertEqual(self.run_command("check"), 1)
        self.assertIn("inactive", self.output.getvalue().lower())
        self.assertNotIn("StartServiceByName", self.methods())

    def test_unlock_uses_native_activation_when_inactive(self):
        self.bus.owner = None
        self.assertEqual(self.run_command("unlock"), 0)
        self.assertIn("StartServiceByName", self.methods())

    def test_already_unlocked_never_prompts(self):
        self.bus.locked = False
        prompt = mock.Mock(side_effect=AssertionError("must not prompt"))
        self.assertEqual(self.run_command("unlock", prompt=prompt), 0)
        self.assertNotIn("OpenSession", self.methods())

    def test_success_unlocks_unique_owner_and_closes_session(self):
        self.assertEqual(self.run_command("unlock"), 0)
        self.assertFalse(self.bus.locked)
        secret_call = next(
            call for call in self.bus.calls if call[3] == "UnlockWithMasterPassword"
        )
        self.assertEqual(secret_call[0], ":1.42")
        self.assertEqual(secret_call[4], "(o(oayays))")
        self.assertEqual(self.methods()[-1], "Close")
        self.assertNotIn("test-password", self.output.getvalue())

    def test_wrong_password_closes_session_and_stays_locked(self):
        self.assertEqual(self.run_command("unlock", password="wrong"), 1)
        self.assertTrue(self.bus.locked)
        self.assertIn("Close", self.methods())
        self.assertNotIn("wrong", self.output.getvalue())

    def test_close_failure_does_not_mask_unlock_failure(self):
        self.bus.fail_unlock = self.bus.fail_close = True
        self.assertEqual(self.run_command("unlock"), 1)
        self.assertIn("password rejected", self.output.getvalue())

    def test_missing_keyring_does_not_prompt_or_create(self):
        self.bus.collection = "/"
        self.assertEqual(
            self.run_command("unlock", prompt=mock.Mock(side_effect=AssertionError)), 1
        )
        self.assertIn("absent", self.output.getvalue().lower())
        self.assertNotIn("OpenSession", self.methods())

    def test_unsupported_provider_does_not_prompt(self):
        self.bus.gnome_owner = ":1.99"
        self.assertEqual(
            self.run_command("unlock", prompt=mock.Mock(side_effect=AssertionError)), 1
        )
        self.assertNotIn("UnlockWithMasterPassword", self.methods())

    def test_missing_or_incompatible_private_api_is_rejected(self):
        for xml in ("<node/>", self.bus.methods.replace("(oayays)", "s")):
            with self.subTest(xml=xml):
                self.bus.methods = xml
                self.assertEqual(self.run_command("unlock"), 1)
                self.assertNotIn("UnlockWithMasterPassword", self.methods())

    def test_owner_change_during_prompt_never_sends_password(self):
        def prompt():
            self.bus.owner = self.bus.gnome_owner = ":1.99"
            return "test-password"

        self.assertEqual(self.run_command("unlock", prompt=prompt), 1)
        self.assertNotIn("UnlockWithMasterPassword", self.methods())

    def test_empty_password_is_not_sent(self):
        self.assertEqual(self.run_command("unlock", password=""), 1)
        self.assertNotIn("OpenSession", self.methods())

    def test_cancelled_prompt_is_reported_without_traceback(self):
        for error in (EOFError, KeyboardInterrupt):
            with self.subTest(error=error):
                self.assertEqual(
                    self.run_command("unlock", prompt=mock.Mock(side_effect=error)), 1
                )
                self.assertNotIn("UnlockWithMasterPassword", self.methods())

    def test_unavailable_session_bus_is_reported_by_cli(self):
        with (
            mock.patch.object(self.module.sys, "platform", "linux"),
            mock.patch.object(
                self.module,
                "GnomeKeyring",
                side_effect=self.module.KeyringError("Session bus unavailable"),
            ),
            contextlib.redirect_stderr(self.output),
        ):
            self.assertEqual(self.module.main(["check"]), 1)
        self.assertIn("Session bus unavailable", self.output.getvalue())

    def test_bus_timeout_does_not_prompt(self):
        self.bus.call = mock.Mock(side_effect=self.module.KeyringError("D-Bus timeout"))
        self.assertEqual(
            self.run_command("unlock", prompt=mock.Mock(side_effect=AssertionError)), 1
        )
        self.assertIn("timeout", self.output.getvalue())

    def test_verifies_unlocked_state(self):
        self.bus.stay_locked = True
        self.assertEqual(self.run_command("unlock"), 1)
        self.assertIn("still locked", self.output.getvalue().lower())

    def test_prompt_refuses_missing_controlling_terminal(self):
        with (
            mock.patch("builtins.open", side_effect=OSError("no tty")),
            self.assertRaises(self.module.KeyringError),
        ):
            self.module.read_password()

    def test_prompt_refuses_getpass_echo_fallback(self):
        import getpass
        import warnings

        def fallback(**kwargs):
            warnings.warn("cannot hide input", getpass.GetPassWarning)

        with (
            mock.patch("builtins.open", mock.mock_open()),
            mock.patch.object(getpass, "getpass", fallback),
            self.assertRaises(self.module.KeyringError),
        ):
            self.module.read_password()

    @unittest.skipUnless(os.name == "posix", "requires a pseudo-terminal")
    def test_real_terminal_accepts_hidden_password_input(self):
        import pty
        import select
        import time

        pid, terminal = pty.fork()
        if pid == 0:
            try:
                password = self.module.read_password()
                os._exit(0 if password == "test-password" else 1)
            except (self.module.KeyringError, OSError):
                os._exit(2)
        reaped = False
        try:
            deadline = time.monotonic() + 5
            output = b""
            sent = False
            while time.monotonic() < deadline:
                if select.select([terminal], [], [], 0.1)[0]:
                    try:
                        output += os.read(terminal, 4096)
                    except OSError:
                        pass
                if b"Keyring password:" in output and not sent:
                    os.write(terminal, b"test-password\n")
                    sent = True
                child, status = os.waitpid(pid, os.WNOHANG)
                if child:
                    reaped = True
                    self.assertEqual(os.waitstatus_to_exitcode(status), 0)
                    self.assertNotIn(b"test-password", output)
                    return
            self.fail("hidden input did not complete")
        finally:
            os.close(terminal)
            if not reaped:
                os.kill(pid, 15)
                os.waitpid(pid, 0)

    def test_non_linux_rejected_without_loading_gi(self):
        with (
            mock.patch.object(self.module.sys, "platform", "darwin"),
            mock.patch.object(
                self.module,
                "GnomeKeyring",
                side_effect=AssertionError("must not connect"),
            ),
            contextlib.redirect_stderr(self.output),
        ):
            self.assertEqual(self.module.main(["check"]), 1)
            self.assertEqual(self.module.main(["unlock"]), 1)


if __name__ == "__main__":
    unittest.main()
