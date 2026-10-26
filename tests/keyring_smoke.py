#!/usr/bin/python3
"""Opt-in real-provider smoke test. Never use the operator's bus or keyring."""

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
from xml.sax.saxutils import escape

HELPER = pathlib.Path(__file__).resolve().parents[1] / "libexec" / "keyring"


def isolated_test():
    root = pathlib.Path(os.environ["DOTFILES_KEYRING_TEST_ROOT"])
    assert pathlib.Path(os.environ["HOME"]) == root
    assert os.environ["XDG_RUNTIME_DIR"] == str(root / "run")
    loader = importlib.machinery.SourceFileLoader("keyring_smoke_helper", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    helper = importlib.util.module_from_spec(spec)
    loader.exec_module(helper)
    transport = helper.SessionBus()

    def owner(name):
        return transport.call(
            helper.DBUS, helper.DBUS_PATH, helper.DBUS, "GetNameOwner", "(s)", (name,)
        )[0]

    def command(action, password=None):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = helper.run(action, helper.GnomeKeyring(transport), lambda: password)
        return code, output.getvalue()

    assert owner(helper.PROVIDER) is None
    assert command("check")[0] == 1
    assert owner(helper.PROVIDER) is None, "check must not autoactivate a daemon"
    daemon = subprocess.Popen(
        [
            "gnome-keyring-daemon",
            "--foreground",
            "--unlock",
            "--components=secrets",
            "--control-directory=" + str(root / "run" / "keyring"),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        # Approved test-only initialization: dummy password, fresh isolated bus,
        # one owned foreground process. The production helper never does this.
        assert daemon.stdin is not None
        daemon.stdin.write(b"test-password")
        daemon.stdin.close()
        for _ in range(100):
            if daemon.poll() is not None:
                raise AssertionError("disposable daemon exited during startup")
            current = owner(helper.PROVIDER)
            if current is not None and owner("org.gnome.keyring") == current:
                try:
                    if command("check")[0] == 0:
                        break
                except helper.KeyringError:
                    pass
            time.sleep(0.05)
        else:
            raise AssertionError("disposable daemon did not become ready")
        pid = transport.call(
            helper.DBUS,
            helper.DBUS_PATH,
            helper.DBUS,
            "GetConnectionUnixProcessID",
            "(s)",
            (current,),
        )[0]
        assert pid == daemon.pid, "test bus must belong to the owned daemon"
        keyring = root / "data" / "keyrings" / "login.keyring"
        assert keyring.is_file(), (
            "test initialization must create only disposable keyring state"
        )

        collection = "/org/freedesktop/secrets/collection/login"
        transport.call(
            current, helper.SERVICE, helper.SECRETS, "Lock", "(ao)", ([collection],)
        )
        assert command("check")[0] == 1
        code, output = command("unlock", "wrong-password")
        assert code == 1 and "wrong-password" not in output
        assert command("check")[0] == 1
        assert command("unlock", "test-password")[0] == 0
        assert command("check")[0] == 0
        assert command("unlock")[0] == 0, "unlocked fast path must skip password prompt"
        assert owner(helper.PROVIDER) == current == owner("org.gnome.keyring")
        print(
            "PASS: inactive check, owned daemon, locked check, wrong password, unlock, unlocked fast path"
        )
    finally:
        if daemon.poll() is None:
            daemon.terminate()
        daemon.wait(timeout=5)


def main():
    if sys.platform != "linux":
        raise SystemExit("Keyring smoke test requires Linux.")
    for executable in ("dbus-run-session", "gnome-keyring-daemon"):
        if shutil.which(executable) is None:
            raise SystemExit(f"Missing test dependency: {executable}")
    if sys.argv[1:] == ["--inside"]:
        isolated_test()
        return
    if sys.argv[1:]:
        raise SystemExit("Usage: /usr/bin/python3 tests/keyring_smoke.py")
    with tempfile.TemporaryDirectory(prefix="dotfiles-keyring-test-") as directory:
        root = pathlib.Path(directory)
        for name in ("run", "data", "config", "services"):
            (root / name).mkdir(mode=0o700)
        config = root / "session.conf"
        config.write_text(
            "<busconfig><type>session</type>"
            f"<listen>unix:tmpdir={escape(str(root / 'run'))}</listen>"
            "<auth>EXTERNAL</auth>"
            f"<servicedir>{escape(str(root / 'services'))}</servicedir>"
            '<policy context="default"><allow own="*"/>'
            '<allow send_destination="*"/><allow receive_sender="*"/>'
            "</policy></busconfig>"
        )
        # Establish isolation BEFORE starting the bus: service activation must
        # never inherit the operator's HOME, runtime directory or user manager.
        env = dict(os.environ)
        for key in (
            "DBUS_SESSION_BUS_ADDRESS",
            "DBUS_SESSION_BUS_PID",
            "DBUS_STARTER_ADDRESS",
            "DBUS_STARTER_BUS_TYPE",
            "GNOME_KEYRING_CONTROL",
            "GNOME_KEYRING_PID",
            "XDG_SESSION_ID",
            "SSH_AUTH_SOCK",
        ):
            env.pop(key, None)
        env.update(
            HOME=str(root),
            XDG_RUNTIME_DIR=str(root / "run"),
            XDG_DATA_HOME=str(root / "data"),
            XDG_CONFIG_HOME=str(root / "config"),
            XDG_CACHE_HOME=str(root / "cache"),
            DOTFILES_KEYRING_TEST_ROOT=str(root),
        )
        subprocess.run(
            [
                "dbus-run-session",
                "--config-file=" + str(config),
                "--",
                sys.executable,
                str(pathlib.Path(__file__).resolve()),
                "--inside",
            ],
            env=env,
            check=True,
            timeout=30,
        )


if __name__ == "__main__":
    main()
