import contextlib
import importlib.machinery
import importlib.util
import io
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
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
        self.methods = self.methods.replace('</interface>', '<method name="CreateWithMasterPassword"><arg direction="in" type="a{sv}"/><arg direction="in" type="(oayays)"/><arg direction="out" type="o"/></method></interface>')
        self.default = "/"
        self.pid = 424242
        self.uid = os.getuid()
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
        if method in ("GetConnectionUnixProcessID", "GetConnectionUnixUser"):
            assert args == (self.owner,) and signature == "(s)"
            return (self.pid if method == "GetConnectionUnixProcessID" else self.uid,)
        if method == "StartServiceByName":
            self.owner = self.gnome_owner = ":1.42"
            return (1,)
        if destination != self.owner:
            raise self.module.KeyringError("provider disappeared")
        if method == "Introspect":
            return (self.methods,)
        if method == "ReadAlias":
            return (self.default if args[0] == "default" else self.collection,)
        if method == "CreateWithMasterPassword":
            assert self.collection == "/", "must not create over existing login"
            assert signature == "(a{sv}(oayays))"
            assert args[0] == {"org.freedesktop.Secret.Collection.Label": "login"}
            assert args[1][2] == list(b"test-password")
            self.collection = "/org/freedesktop/secrets/collection/login"
            self.locked = self.stay_locked
            return (self.collection,)
        if method == "SetAlias":
            assert signature == "(so)" and args == ("default", self.collection)
            self.default = args[1]
            return ()
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

    def test_existing_commands_preserve_ignored_extra_arguments(self):
        self.bus.locked = False
        with (
            mock.patch.object(self.module.sys, "platform", "linux"),
            mock.patch.object(self.module, "GnomeKeyring", return_value=self.provider),
            contextlib.redirect_stdout(self.output),
            contextlib.redirect_stderr(self.output),
        ):
            self.assertEqual(self.module.main(["check", "unused"]), 0)

    def test_unlock_preserves_input_only_capability_check(self):
        self.bus.methods = self.bus.methods.replace(
            '<arg direction="in" type="o"/>',
            '<arg direction="in" type="o"/><arg direction="out" type="b"/>',
        )
        self.assertEqual(self.run_command("unlock"), 0)

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


class InitTests(unittest.TestCase):
    run_command = KeyringTests.run_command
    methods = KeyringTests.methods

    def setUp(self):
        self.module = load_helper()
        self.bus = FakeBus(self.module)
        self.provider = self.module.GnomeKeyring(self.bus)
        self.output = io.StringIO()
        self.bus.collection = "/"
        platform = mock.patch.object(self.module.sys, "platform", "linux")
        platform.start()
        self.addCleanup(platform.stop)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = pathlib.Path(temporary.name)
        self.daemon_home = self.home / "daemon-home"
        self.daemon_data = self.home / "daemon-data"
        self.environ = self.home / "daemon.environ"
        self.environ.write_bytes(b"HOME=" + os.fsencode(self.daemon_home) + b"\0XDG_DATA_HOME=" +
                                 os.fsencode(self.daemon_data) + b"\0OTHER_SECRET=never-retain-me\0")
        self.environ_unreadable = False
        self.environ_reads = 0
        original_open = open

        def open_fixture(path, *args, **kwargs):
            if str(path).startswith("/proc/"):
                self.assertEqual(str(path), "/proc/424242/environ")
                self.environ_reads += 1
                if self.environ_unreadable:
                    raise PermissionError("fixture access denied")
                return original_open(self.environ, *args, **kwargs)
            return original_open(path, *args, **kwargs)

        proc = mock.patch("builtins.open", side_effect=open_fixture)
        proc.start()
        self.addCleanup(proc.stop)
        environment = mock.patch.dict(os.environ, HOME=str(self.home),
                                      XDG_DATA_HOME=str(self.home / "data"))
        environment.start()
        self.addCleanup(environment.stop)
        terminal = mock.patch.object(self.module, "foreground_terminal", return_value=True)
        terminal.start()
        self.addCleanup(terminal.stop)

    # These tests catch sending a create request before every refusal guard,
    # missing confirmation/default setup, and leaking or accepting secret argv.
    def test_init_creates_login_unlocked_and_default(self):
        self.assertEqual(self.run_command("init"), 0, self.output.getvalue())
        self.assertEqual(self.bus.collection, "/org/freedesktop/secrets/collection/login")
        self.assertEqual(self.bus.default, self.bus.collection)
        self.assertFalse(self.bus.locked)
        self.assertIn("CreateWithMasterPassword", self.methods())
        self.assertIn("Close", self.methods())
        self.assertNotIn("test-password", self.output.getvalue())

    def test_init_refuses_existing_login_without_write_or_prompt(self):
        self.bus.collection = "/org/freedesktop/secrets/collection/login"
        for locked in (True, False):
            self.bus.locked = locked
            self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertNotIn("OpenSession", self.methods())
        self.assertNotIn("CreateWithMasterPassword", self.methods())
        self.assertNotIn("SetAlias", self.methods())

    def test_init_refuses_unloaded_login_file_without_reading_or_writing_it(self):
        for directory in (self.home / "data/keyrings", self.home / ".gnome2/keyrings"):
            with self.subTest(directory=directory):
                directory.mkdir(parents=True)
                existing = directory / "login.keyring"
                existing.write_bytes(b"not a valid keyring")
                before = existing.stat()
                self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
                self.assertIn("existing login keyring", self.output.getvalue().lower())
                self.assertEqual(existing.stat(), before)
                self.assertNotIn("OpenSession", self.methods())
                self.assertNotIn("CreateWithMasterPassword", self.methods())
                existing.unlink()  # Remove only this test's invalid disposable fixture.

    def test_init_refuses_dangling_login_symlink(self):
        directory = self.home / "data/keyrings"
        directory.mkdir(parents=True)
        (directory / "login.keyring").symlink_to(directory / "missing")
        self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertNotIn("OpenSession", self.methods())

    def test_init_refuses_login_in_different_daemon_storage(self):
        for directory in (self.daemon_data / "keyrings", self.daemon_home / ".gnome2/keyrings"):
            with self.subTest(directory=directory):
                directory.mkdir(parents=True)
                existing = directory / "login.keyring"
                existing.write_bytes(b"unloadable fixture")
                before = existing.stat()
                self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
                self.assertIn("existing login keyring", self.output.getvalue().lower())
                self.assertEqual(existing.stat(), before)
                self.assertNotIn("OpenSession", self.methods())
                self.assertNotIn("CreateWithMasterPassword", self.methods())
                existing.unlink()

    def test_init_unreadable_daemon_environ_fails_before_prompt_or_create(self):
        self.environ_unreadable = True
        self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertIn("daemon", self.output.getvalue().lower())
        self.assertNotIn("OpenSession", self.methods())
        self.assertNotIn("CreateWithMasterPassword", self.methods())

    def test_init_daemon_uid_mismatch_does_not_read_environment(self):
        self.bus.uid = os.getuid() + 1
        self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertEqual(self.environ_reads, 0)
        self.assertIn("daemon", self.output.getvalue().lower())
        self.assertNotIn("OpenSession", self.methods())

    def test_init_invalid_pid_or_storage_paths_fail_closed(self):
        for pid in (None, 0, "424242"):
            with self.subTest(pid=pid):
                self.bus.pid = pid
                self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
                self.assertEqual(self.environ_reads, 0)
        self.bus.pid = 424242
        for content in (b"", b"HOME=relative\0", b"HOME=/fixture\0XDG_DATA_HOME=relative\0"):
            with self.subTest(content=content):
                self.environ.write_bytes(content)
                self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertNotIn("OpenSession", self.methods())

    def test_init_non_linux_refuses_without_reading_daemon_environment(self):
        with mock.patch.object(self.module.sys, "platform", "darwin"):
            self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertEqual(self.environ_reads, 0)
        self.assertIn("Linux", self.output.getvalue())
        self.assertNotIn("OpenSession", self.methods())

    def test_daemon_environment_keeps_only_allowed_variables(self):
        self.provider.inspect(initialize=True)
        self.assertEqual(self.provider.daemon_environment(),
                         {b"HOME": os.fsencode(self.daemon_home),
                          b"XDG_DATA_HOME": os.fsencode(self.daemon_data)})
        self.assertNotIn("never-retain-me", self.output.getvalue())

    def test_init_requires_confirmation_and_aborts_mismatch(self):
        for answers in (("test-password", "different"), ("",), (KeyboardInterrupt,)):
            with self.subTest(answers=answers):
                self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=answers)), 1)
                self.assertNotIn("OpenSession", self.methods())
                self.assertNotIn("test-password", self.output.getvalue())
                self.assertNotIn("different", self.output.getvalue())

    def test_init_refuses_nonterminal_before_bus_access(self):
        with (
            mock.patch.object(self.module, "foreground_terminal", return_value=False),
            mock.patch.object(self.module, "GnomeKeyring", side_effect=AssertionError("no bus")),
            contextlib.redirect_stderr(self.output),
        ):
            self.assertEqual(self.module.main(["init"]), 1)
        self.assertIn("terminal", self.output.getvalue())
        self.assertEqual(self.bus.calls, [])

    def test_init_rejects_changed_create_signature_before_prompt(self):
        original = self.bus.methods
        for xml in ("<node/>", original.replace('type="a{sv}"', 'type="s"'),
                    original.replace('direction="out" type="o"', 'direction="out" type="s"')):
            self.bus.methods = xml
            self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertNotIn("OpenSession", self.methods())

    def test_init_rechecks_absence_and_owner_after_confirmation(self):
        def existing():
            self.bus.collection = "/org/freedesktop/secrets/collection/login"
            return "test-password"

        self.assertEqual(self.run_command("init", prompt=existing), 1)
        self.assertNotIn("OpenSession", self.methods())
        self.bus.collection = "/"
        self.assertEqual(self.run_command("init", prompt=lambda: self.change_owner()), 1)
        self.assertNotIn("OpenSession", self.methods())

    def change_owner(self):
        self.bus.owner = self.bus.gnome_owner = ":1.99"
        return "test-password"

    def test_init_unsupported_provider_and_bus_failure_do_not_prompt(self):
        self.bus.gnome_owner = ":1.99"
        self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)
        self.assertNotIn("OpenSession", self.methods())
        self.bus.call = mock.Mock(side_effect=self.module.KeyringError("bus unavailable"))
        self.assertEqual(self.run_command("init", prompt=mock.Mock(side_effect=AssertionError)), 1)

    def test_init_checks_unlocked_state_before_default_alias(self):
        self.bus.stay_locked = True
        self.assertEqual(self.run_command("init"), 1)
        self.assertNotIn("SetAlias", self.methods())
        self.assertIn("Close", self.methods())

    def test_init_failure_after_create_reports_possible_partial_state_without_reset(self):
        call = self.bus.call

        def fail_alias(destination, path, interface, method, signature, args):
            if method == "SetAlias":
                raise self.module.KeyringError("SetAlias failed")
            return call(destination, path, interface, method, signature, args)

        self.bus.call = fail_alias
        self.assertEqual(self.run_command("init"), 1)
        self.assertEqual(self.bus.collection, "/org/freedesktop/secrets/collection/login")
        self.assertIn("may have been created", self.output.getvalue())
        self.assertIn("make keyring-check", self.output.getvalue())
        self.assertEqual(self.methods().count("CreateWithMasterPassword"), 1)
        self.assertNotIn("Delete", self.methods())
        self.assertIn("Close", self.methods())
        self.assertNotIn("test-password", self.output.getvalue())

    def test_init_extra_argv_rejected_without_printing_secret_or_using_bus(self):
        result = subprocess.run([sys.executable, str(ROOT / "libexec/keyring"), "init", "test-password"],
                                capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"test-password", result.stdout + result.stderr)
        self.assertNotIn(b"invalid choice", result.stderr)


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.module = load_helper()
        self.bus = FakeBus(self.module)
        self.provider = self.module.GnomeKeyring(self.bus)
        self.output = io.StringIO()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.runtime = pathlib.Path(self.temporary.name)
        self.runtime.chmod(0o700)
        self.environment = mock.patch.dict(os.environ, {
            "XDG_RUNTIME_DIR": str(self.runtime),
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(self.runtime / "bus"),
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def methods(self):
        return [call[3] for call in self.bus.calls]

    def start(self, prompt=None):
        with (
            mock.patch.object(self.module, "foreground_terminal", return_value=True),
            contextlib.redirect_stdout(self.output),
            contextlib.redirect_stderr(self.output),
        ):
            return self.module.startup(lambda: self.provider, prompt or (lambda: "test-password"))

    def test_unlocked_startup_is_silent(self):
        self.bus.locked = False
        self.assertEqual(self.start(mock.Mock(side_effect=AssertionError)), 0)
        self.assertEqual(self.output.getvalue(), "")

    def test_locked_startup_unlocks_and_rechecks_after_relock(self):
        self.assertEqual(self.start(), 0)
        self.assertFalse(self.bus.locked)
        self.bus.locked = True
        self.assertEqual(self.start(), 0)
        self.assertEqual(self.methods().count("UnlockWithMasterPassword"), 2)
        self.assertNotIn("test-password", self.output.getvalue())

    def test_startup_activates_natively(self):
        self.bus.owner = None
        self.assertEqual(self.start(), 0)
        self.assertIn("StartServiceByName", self.methods())

    def test_startup_cancel_and_rejection_leave_successful_shell(self):
        for prompt in (mock.Mock(side_effect=KeyboardInterrupt), lambda: "bad-password"):
            with self.subTest(prompt=prompt):
                self.assertEqual(self.start(prompt), 0)
                self.assertTrue(self.bus.locked)
                self.assertNotIn("bad-password", self.output.getvalue())
                self.assertNotIn("Traceback", self.output.getvalue())

    def test_unsupported_or_absent_startup_is_silent(self):
        for state in ("provider", "collection"):
            with self.subTest(state=state):
                self.bus.gnome_owner = ":1.99" if state == "provider" else self.bus.owner
                self.bus.collection = "/"
                self.assertEqual(self.start(mock.Mock(side_effect=AssertionError)), 0)
                self.assertEqual(self.output.getvalue(), "")

    def test_startup_refuses_without_foreground_terminal(self):
        with mock.patch.object(self.module, "foreground_terminal", return_value=False):
            self.assertEqual(self.module.startup(mock.Mock(side_effect=AssertionError)), 0)
        self.assertEqual(self.bus.calls, [])

    def test_concurrent_startup_skips_without_prompt(self):
        with self.module.startup_lock() as acquired:
            self.assertTrue(acquired)
            self.assertEqual(self.start(mock.Mock(side_effect=AssertionError)), 0)
        self.assertEqual(self.bus.calls, [])
        self.assertEqual(self.output.getvalue(), "")
        self.assertEqual(self.start(), 0)
        self.assertFalse(self.bus.locked)

    def test_unsafe_runtime_and_symlink_lock_are_not_used(self):
        self.runtime.chmod(0o755)
        self.assertEqual(self.start(mock.Mock(side_effect=AssertionError)), 0)
        self.assertEqual(self.bus.calls, [])
        self.runtime.chmod(0o700)
        with self.module.startup_lock() as acquired:
            self.assertTrue(acquired)
        lock = next(self.runtime.glob("dotfiles-keyring-*.lock"))
        lock.unlink()
        target = self.runtime / "target"
        target.write_text("untouched")
        lock.symlink_to(target)
        self.assertEqual(self.start(mock.Mock(side_effect=AssertionError)), 0)
        self.assertEqual(target.read_text(), "untouched")
        self.assertEqual(self.bus.calls, [])

    def test_crashed_holder_releases_lock(self):
        code = f'''import runpy, os
m = runpy.run_path({str(ROOT / "libexec/keyring")!r})
with m["startup_lock"]() as acquired:
    os._exit(0 if acquired else 2)
'''
        self.assertEqual(subprocess.run([sys.executable, "-c", code], check=False).returncode, 0)
        with self.module.startup_lock() as acquired:
            self.assertTrue(acquired)

    def test_startup_deadline_includes_provider_construction(self):
        code = f'''import runpy, time
m = runpy.run_path({str(ROOT / "libexec/keyring")!r})
m["startup"].__globals__["foreground_terminal"] = lambda: True
m["startup"](lambda: time.sleep(30))
'''
        result = subprocess.run([sys.executable, "-c", code], timeout=4, check=False)
        self.assertEqual(result.returncode, 0)

    def test_deadline_terminates_a_blocked_operation(self):
        code = f'''import runpy, time
m = runpy.run_path({str(ROOT / "libexec/keyring")!r})
with m["deadline"](0.1):
    time.sleep(30)
'''
        result = subprocess.run([sys.executable, "-c", code], timeout=3, check=False)
        self.assertEqual(result.returncode, 1)


class GhCheckTests(unittest.TestCase):
    def setUp(self):
        self.module = load_helper()
        self.bus = FakeBus(self.module)
        self.provider = self.module.GnomeKeyring(self.bus)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = pathlib.Path(self.temporary.name)
        self.config = self.home / ".config/gh"
        self.config.mkdir(parents=True)
        self.hosts = self.config / "hosts.yml"
        self.hosts.write_text("github.com:\n    user: test-user\n")
        environment = {key: value for key, value in os.environ.items() if key not in (
            "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "AppData", "GH_TOKEN", "GITHUB_TOKEN",
            "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")}
        environment["HOME"] = str(self.home)
        self.environment = mock.patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def check(self, *args):
        return self.module.gh_check(list(args), lambda: self.provider)

    def test_locked_or_inactive_keyring_refuses_without_activation_or_secret_reads(self):
        for owner in (":1.42", None):
            with self.subTest(owner=owner):
                self.bus.owner = owner
                self.assertEqual(self.check("auth", "status"), 1)
        methods = [call[3] for call in self.bus.calls]
        self.assertNotIn("StartServiceByName", methods)
        self.assertNotIn("OpenSession", methods)

    def test_unlocked_and_other_providers_delegate(self):
        self.bus.locked = False
        self.assertEqual(self.check("pr", "list"), 0)
        self.bus.gnome_owner = ":1.99"
        self.bus.locked = True
        self.assertEqual(self.check("pr", "list"), 0)

    def test_token_and_plaintext_compatibility_bypass(self):
        for token in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
            with self.subTest(token=token), mock.patch.dict(os.environ, {token: "dummy"}):
                self.assertEqual(self.check("api", "user"), 0)
        for key in ("oauth_token", '"oauth_token"', "'oauth_token'"):
            self.hosts.write_text(f"github.com:\n    {key}: dummy\n")
            self.assertEqual(self.check("api", "user"), 0)
        self.assertEqual(self.bus.calls, [])

    def test_login_does_not_bypass_locked_storage_with_tokens_or_plaintext(self):
        self.hosts.write_text("github.com:\n    oauth_token: dummy\n")
        with mock.patch.dict(os.environ, {"GH_TOKEN": "dummy"}):
            self.assertEqual(self.check("auth", "login", "--web"), 1)
        self.hosts.unlink()
        self.assertEqual(self.check("auth", "login"), 1)

    def test_effective_config_precedence(self):
        for variable in ("XDG_CONFIG_HOME", "GH_CONFIG_DIR"):
            directory = self.home / variable
            target = directory / {"XDG_CONFIG_HOME": "gh", "GH_CONFIG_DIR": ""}[variable]
            target.mkdir(parents=True)
            (target / "hosts.yml").write_text("github.com:\n    oauth_token: dummy\n")
            os.environ[variable] = str(directory)
            self.assertEqual(self.check("pr", "list"), 0)
            (target / "hosts.yml").write_text("github.com:\n    user: test-user\n")
            self.assertEqual(self.check("pr", "list"), 1)

    def test_linux_ignores_windows_appdata_config_path(self):
        appdata = self.home / "windows"
        (appdata / "GitHub CLI").mkdir(parents=True)
        (appdata / "GitHub CLI/hosts.yml").write_text("github.com:\n    oauth_token: dummy\n")
        with mock.patch.dict(os.environ, {"AppData": str(appdata)}):
            self.assertEqual(self.check("auth", "status"), 1)

    def test_missing_config_is_not_forced_into_keyring_enrollment(self):
        self.hosts.unlink()
        self.assertEqual(self.check("auth", "status"), 0)
        self.assertEqual(self.bus.calls, [])

    def test_auth_free_commands_bypass_without_misreading_hostname_or_input(self):
        for argv in ([], ["--help"], ["-h"], ["help", "auth"], ["version"], ["--version"],
                     ["completion", "-s", "zsh"], ["config", "get", "editor"],
                     ["config", "list"], ["config", "set", "editor", "vim"],
                     ["alias", "list"], ["alias", "set", "x", "pr list"], ["alias", "delete", "x"],
                     ["auth", "login", "--help"], ["pr", "--help"]):
            with self.subTest(argv=argv):
                self.assertEqual(self.check(*argv), 0)
        self.assertEqual(self.bus.calls, [])
        self.assertEqual(self.check("auth", "status", "-h", "github.com"), 1)
        self.assertEqual(self.check("api", "--input", "--help"), 1)
        self.assertEqual(self.check("api", "-f", "--help"), 1)

    def test_credential_noops_delegate_but_get_is_guarded(self):
        for operation in ("store", "erase", "invalid"):
            for args in ([operation], ["--", operation], [operation, "--"]):
                self.assertEqual(self.check("auth", "git-credential", *args), 0)
        self.assertEqual(self.bus.calls, [])
        for args in (["get"], ["--", "get"], ["get", "--"]):
            with self.subTest(args=args):
                self.assertEqual(self.check("auth", "git-credential", *args), 1)

    @unittest.skipUnless(sys.platform == "linux", "Linux Gio bus boundary")
    def test_gh_deadline_bounds_unresponsive_real_bus(self):
        python = "/usr/bin/python3"
        if subprocess.run([python, "-c", "import gi"], capture_output=True, check=False).returncode:
            self.skipTest("system Gio bindings unavailable")
        server = socket.socket(socket.AF_UNIX)
        self.addCleanup(server.close)
        address = str(self.home / "blocked-bus")
        server.bind(address)
        server.listen(1)
        result = subprocess.run([python, str(ROOT / "libexec/keyring"), "gh-check", "--", "auth", "login"],
                                env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS="unix:path=" + address),
                                capture_output=True, timeout=4, check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, b"")
        # The watchdog must terminate a real blocked Gio C call, not just sleep.
        server.settimeout(0.1)
        connection, _ = server.accept()
        connection.close()

    def test_missing_bindings_do_not_allow_unverified_credential_storage(self):
        with mock.patch.dict(sys.modules, {"gi": None}):
            self.assertEqual(self.module.gh_check(["auth", "login"]), 1)
            self.assertEqual(self.module.gh_check(["pr", "list"]), 1)

    def test_gh_deadline_includes_provider_construction(self):
        code = f'''import runpy, time
m = runpy.run_path({str(ROOT / "libexec/keyring")!r})
m["gh_check"](["auth", "login"], lambda: time.sleep(30))
'''
        result = subprocess.run([sys.executable, "-c", code], timeout=4, check=False)
        self.assertEqual(result.returncode, 1)


class BootUnlockTests(unittest.TestCase):
    def setUp(self):
        self.module = load_helper()
        self.bus = FakeBus(self.module)
        self.provider = self.module.GnomeKeyring(self.bus)
        self.output = io.StringIO()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.credentials = pathlib.Path(self.temporary.name)
        self.sleeps = []

    def methods(self):
        return [call[3] for call in self.bus.calls]

    def seal(self, content=b"test-password"):
        (self.credentials / "dotfiles-keyring").write_bytes(content)

    def boot(self, environment=None, factory=None, attempts=3):
        environment = {"CREDENTIALS_DIRECTORY": str(self.credentials)} if environment is None else environment
        with (
            mock.patch.dict(os.environ, environment, clear=True),
            contextlib.redirect_stdout(self.output),
            contextlib.redirect_stderr(self.output),
        ):
            return self.module.boot_unlock(factory or (lambda: self.provider),
                                           attempts=attempts, sleep=self.sleeps.append)

    def test_no_credential_refuses_without_bus_access(self):
        factory = mock.Mock(side_effect=AssertionError("bus used"))
        self.assertEqual(self.boot(environment={}, factory=factory), 1)
        self.assertEqual(self.boot(factory=factory), 1)
        factory.assert_not_called()
        self.assertTrue(self.bus.locked)
        self.assertIn("make keyring-unlock", self.output.getvalue())
        self.assertEqual(self.output.getvalue().count("boot unlock failed"), 2)

    def test_credential_unlocks_once_and_closes_session(self):
        self.seal(b"test-password\n")
        self.assertEqual(self.boot(), 0)
        self.assertFalse(self.bus.locked)
        self.assertEqual(self.methods().count("UnlockWithMasterPassword"), 1)
        self.assertIn("Close", self.methods())
        self.assertNotIn("CreateWithMasterPassword", self.methods())
        self.assertNotIn("test-password", self.output.getvalue())

    def test_password_never_comes_from_environment_or_arguments(self):
        planted = {name: "test-password" for name in (
            "PASSWORD", "KEYRING_PASSWORD", "DOTFILES_KEYRING", "dotfiles-keyring")}
        self.assertEqual(self.boot(environment=planted), 1)
        self.assertTrue(self.bus.locked)
        self.assertNotIn("UnlockWithMasterPassword", self.methods())
        self.seal()
        self.assertEqual(self.boot(environment=dict(planted, CREDENTIALS_DIRECTORY=str(self.credentials),
                                                    KEYRING_PASSWORD="wrong")), 0)
        unlock = [call for call in self.bus.calls if call[3] == "UnlockWithMasterPassword"]
        self.assertEqual(len(unlock), 1)
        self.assertEqual(unlock[0][5][1][2], list(b"test-password"))
        result = subprocess.run([sys.executable, str(ROOT / "libexec/keyring"), "boot-unlock", "test-password"],
                                env=dict(os.environ, CREDENTIALS_DIRECTORY=str(self.credentials)),
                                capture_output=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b"test-password", result.stdout + result.stderr)

    def test_symlinked_or_empty_credential_is_refused(self):
        target = self.credentials / "elsewhere"
        target.write_bytes(b"test-password")
        (self.credentials / "dotfiles-keyring").symlink_to(target)
        self.assertEqual(self.boot(), 1)
        (self.credentials / "dotfiles-keyring").unlink()
        self.seal(b"\n")
        self.assertEqual(self.boot(), 1)
        self.assertNotIn("UnlockWithMasterPassword", self.methods())

    def test_waits_for_secret_service_then_unlocks(self):
        self.seal()
        self.bus.owner = self.bus.gnome_owner = None
        failures = iter([self.module.KeyringError("bus not ready")])

        def factory():
            for error in failures:
                raise error
            return self.provider

        real = self.bus.call

        def not_activatable_once(destination, path, interface, method, signature, args):
            if method == "StartServiceByName" and not getattr(self, "activated", False):
                self.activated = True
                raise self.module.KeyringError("StartServiceByName failed")
            return real(destination, path, interface, method, signature, args)

        self.bus.call = not_activatable_once
        self.assertEqual(self.boot(factory=factory, attempts=3), 0)
        self.assertEqual(len(self.sleeps), 2)
        self.assertFalse(self.bus.locked)
        self.assertEqual(self.methods().count("UnlockWithMasterPassword"), 1)

    def test_gives_up_after_bounded_retries_with_one_line(self):
        self.seal()
        factory = mock.Mock(side_effect=self.module.KeyringError("Session bus unavailable."))
        self.assertEqual(self.boot(factory=factory, attempts=3), 1)
        self.assertEqual(factory.call_count, 3)
        self.assertEqual(len(self.sleeps), 2)
        self.assertEqual(self.output.getvalue().strip().count("\n"), 0)
        self.assertIn("boot unlock failed: Session bus unavailable.", self.output.getvalue())

    def test_wrong_password_is_tried_once(self):
        self.seal(b"wrong-password")
        self.assertEqual(self.boot(), 1)
        self.assertTrue(self.bus.locked)
        self.assertEqual(self.methods().count("UnlockWithMasterPassword"), 1)
        self.assertEqual(self.sleeps, [])
        self.assertNotIn("wrong-password", self.output.getvalue())

    def test_already_unlocked_or_absent_or_other_provider_never_sends_password(self):
        self.seal()
        self.bus.locked = False
        self.assertEqual(self.boot(), 0)
        self.bus.locked = True
        self.bus.collection = "/"
        self.assertEqual(self.boot(attempts=1), 1)
        self.bus.collection = "/org/freedesktop/secrets/collection/login"
        self.bus.gnome_owner = ":1.99"
        self.assertEqual(self.boot(attempts=1), 1)
        self.assertEqual(self.sleeps, [])
        self.assertNotIn("UnlockWithMasterPassword", self.methods())
        self.assertNotIn("CreateWithMasterPassword", self.methods())


class SealTests(unittest.TestCase):
    def setUp(self):
        self.module = load_helper()
        self.bus = FakeBus(self.module)
        self.provider = self.module.GnomeKeyring(self.bus)
        self.commands = []
        self.inputs = []
        self.output = io.StringIO()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.tpm = pathlib.Path(self.temporary.name) / "tpmrm0"
        self.tpm.touch()

    def run_seal(self, prompt=None):
        def run(command, input=None, check=False, stdout=None):
            self.commands.append(command)
            self.inputs.append(input)
            return subprocess.CompletedProcess(command, 0)

        # Independent of the runner's account: root would be refused as a unit user.
        with (
            mock.patch.object(self.module.os, "getuid", return_value=1000),
            mock.patch.object(self.module.pwd, "getpwuid", return_value=mock.Mock(pw_name="tng")),
            contextlib.redirect_stdout(self.output),
            contextlib.redirect_stderr(self.output),
        ):
            try:
                return self.module.seal(self.provider, prompt or (lambda: "test-password"),
                                        run=run, tpm=str(self.tpm))
            except self.module.KeyringError as error:
                return str(error)

    def test_refuses_without_tpm_before_prompt(self):
        self.tpm.unlink()
        prompt = mock.Mock()
        self.assertIn("No TPM", self.run_seal(prompt))
        prompt.assert_not_called()
        self.assertEqual(self.commands, [])

    def test_refuses_without_login_keyring_before_prompt(self):
        self.bus.collection = "/"
        prompt = mock.Mock()
        self.assertIn("absent", self.run_seal(prompt))
        prompt.assert_not_called()
        self.assertEqual(self.commands, [])
        self.assertNotIn("CreateWithMasterPassword", [call[3] for call in self.bus.calls])

    def test_seals_without_pcrs_and_passes_password_only_on_stdin(self):
        self.assertEqual(self.run_seal(), 0)
        encrypt = self.commands[1]
        self.assertEqual(encrypt, ["sudo", "systemd-creds", "encrypt", "--with-key=tpm2", "--tpm2-pcrs=",
                                   "--name=dotfiles-keyring", "-",
                                   "/etc/credstore.encrypted/dotfiles-keyring"])
        self.assertEqual(self.inputs[1], b"test-password")
        for command in self.commands:
            self.assertFalse(any("test-password" in part for part in command))
        self.assertNotIn("test-password", self.output.getvalue())
        unit = self.inputs[self.commands.index(["sudo", "tee", "/etc/systemd/system/dotfiles-keyring-unlock.service"])]
        self.assertIn(f"ExecStart=/usr/bin/python3 {ROOT / 'libexec/keyring'} boot-unlock".encode(), unit)
        self.assertIn(b"User=tng\n", unit)
        self.assertIn(b"After=user@1000.service\n", unit)
        self.assertEqual(self.commands[-2:], [
            ["sudo", "systemctl", "enable", "dotfiles-keyring-unlock.service"],
            ["sudo", "systemctl", "start", "dotfiles-keyring-unlock.service"],
        ])
        self.assertNotIn("UnlockWithMasterPassword", [call[3] for call in self.bus.calls])

    def test_empty_password_is_not_sealed(self):
        self.assertIn("empty", self.run_seal(lambda: ""))
        self.assertEqual(self.commands, [])

    def test_seal_refuses_extra_arguments(self):
        result = subprocess.run([sys.executable, str(ROOT / "libexec/keyring"), "seal", "test-password"],
                                capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"test-password", result.stdout + result.stderr)


class UnitRenderTests(unittest.TestCase):
    def setUp(self):
        self.module = load_helper()
        self.template = (ROOT / "tools/coordinator-vm/dotfiles-keyring-unlock.service").read_text()

    def test_unit_renders_with_absolute_paths_and_no_specifiers(self):
        unit = self.module.render_unit(self.template, "tng", 1000, "/home/tng/.dotfiles/libexec/keyring")
        body = [line for line in unit.splitlines() if not line.startswith("#")]
        self.assertFalse(any(re.search(r"@[A-Z]+@", line) for line in body))
        self.assertFalse(any("%" in line for line in body))
        for expected in (
            "User=tng",
            "Requires=user@1000.service",
            "After=user@1000.service",
            "Environment=XDG_RUNTIME_DIR=/run/user/1000",
            "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
            "LoadCredentialEncrypted=dotfiles-keyring",
            "ExecStart=/usr/bin/python3 /home/tng/.dotfiles/libexec/keyring boot-unlock",
        ):
            self.assertIn(expected, body)

    def test_unit_refuses_paths_systemd_would_reinterpret(self):
        for helper in ("libexec/keyring", "/home/a b/keyring", "/home/%h/keyring", "/home/x;y/keyring"):
            with self.assertRaises(self.module.KeyringError):
                self.module.render_unit(self.template, "tng", 1000, helper)
        for user, uid in (("root user", 1000), ("tng", 0), ("tng", "1000")):
            with self.assertRaises(self.module.KeyringError):
                self.module.render_unit(self.template, user, uid, "/home/tng/keyring")


if __name__ == "__main__":
    unittest.main()
