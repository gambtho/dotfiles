"""Heeler's root boundary: metadata in, a narrowly bound sshd argv out."""
import contextlib
import importlib.util
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'tools/herdr/heeler/sshd-entrypoint.py'


def load_entry():
    spec = importlib.util.spec_from_file_location('heeler_sshd', ENTRY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HeelerRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(ENTRY.is_file(), 'Heeler SSH entrypoint is missing')
        self.entry = load_entry()

    def status(self, ips=None):
        return {'BackendState': 'Running', 'Self': {
            'Online': True, 'TailscaleIPs': ips or ['100.84.88.33', 'fd7a::1']}}

    def test_selects_exact_online_tailnet_ipv4(self):
        self.assertEqual(self.entry.tailnet_ipv4(self.status()), '100.84.88.33')

    def test_fails_closed_on_invalid_or_ambiguous_network_state(self):
        bad = [None, {}, {'BackendState': 'Stopped'},
               {'BackendState': 'Running', 'Self': {'Online': False}},
               self.status(['127.0.0.1']), self.status(['192.168.1.2']),
               self.status(['0.0.0.0']), self.status(['100.84.88.33', '100.84.88.34']),
               self.status(['100.84.88.33', 'garbage']), self.status(['fd7a::1'])]
        for state in bad:
            with self.subTest(state=state), self.assertRaises(ValueError):
                self.entry.tailnet_ipv4(state)

    def test_account_and_home_are_not_configuration_injection(self):
        self.entry.validate_identity('someone', 1000, '/home/someone')
        for name, uid, home in [('root', 0, '/root'), ('daemon', 1, '/usr/share'),
                                ('a*', 1000, '/home/a'), ('a\nAllowUsers *', 1000, '/home/a'),
                                ('a', 1000, '/home/a%h'), ('a', 1000, '/home/a b'),
                                ('a', 1000, '/home/../etc'), ('a', 1000, '/')]:
            with self.subTest(name=name, home=home), self.assertRaises(ValueError):
                self.entry.validate_identity(name, uid, home)

    def test_exact_default_socket_forwarding_and_key_only_listener(self):
        args = self.entry.sshd_argv('someone', 1000, '/home/someone', '100.84.88.33')
        self.assertEqual(args[:5], ['/usr/sbin/sshd', '-D', '-e', '-f', '/dev/null'])
        options = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == '-o']
        self.assertIn('ListenAddress=100.84.88.33', options)
        self.assertIn('PermitOpen=[/home/someone/.config/herdr/herdr.sock]:*', options)
        self.assertIn('AllowTcpForwarding=local', options)
        self.assertIn('AllowStreamLocalForwarding=local', options)
        self.assertIn('AuthorizedKeysFile=/home/someone/.local/share/heeler-trial/authorized_keys', options)
        for option in ['AuthenticationMethods=publickey', 'PasswordAuthentication=no',
                       'KbdInteractiveAuthentication=no', 'PermitRootLogin=no',
                       'AllowAgentForwarding=no', 'X11Forwarding=no', 'AllowUsers=someone']:
            self.assertIn(option, options)
        self.assertNotIn('0.0.0.0', args)
        self.assertNotIn('mise', args)
        self.assertNotIn('herdr', args)

    def test_numeric_tailnet_ip_is_not_a_valid_cli_address(self):
        state = self.status([1683269665])
        with self.assertRaises(ValueError):
            self.entry.tailnet_ipv4(state)

    def test_cannot_construct_public_listener(self):
        for ip in ['0.0.0.0', '192.168.1.1', '::', '127.0.0.1', '100.84.88.33\nPort 22']:
            with self.subTest(ip=ip), self.assertRaises(ValueError):
                self.entry.sshd_argv('someone', 1000, '/home/someone', ip)

    def test_runtime_uses_only_absolute_system_tools_and_clean_environment(self):
        record = type('Account', (), {'pw_name': 'someone', 'pw_uid': 1000, 'pw_dir': '/home/someone'})
        with patch.object(self.entry.os, 'geteuid', return_value=0), \
             patch.object(self.entry.pwd, 'getpwnam', return_value=record), \
             patch.object(self.entry.subprocess, 'run') as run, \
             patch.object(self.entry.os, 'execve') as execute:
            run.return_value.stdout = json.dumps(self.status())
            self.entry.launch('someone')
            self.assertEqual(run.call_args.args[0], ['/usr/bin/tailscale', 'status', '--json'])
            self.assertLessEqual(run.call_args.kwargs['timeout'], 10)
            self.assertEqual(execute.call_args.args[0], '/usr/sbin/sshd')
            self.assertNotIn('PYTHONPATH', execute.call_args.args[2])
            self.assertNotIn('HOME', execute.call_args.args[2])

    def test_operator_configuration_check_validates_without_binding_or_exec(self):
        record = type('Account', (), {'pw_name': 'someone', 'pw_uid': 1000, 'pw_dir': '/home/someone'})
        with patch.object(self.entry.os, 'geteuid', return_value=0), \
             patch.object(self.entry.pwd, 'getpwnam', return_value=record), \
             patch.object(self.entry.subprocess, 'run') as run, \
             patch.object(self.entry.os, 'execve') as execute:
            run.return_value.stdout = json.dumps(self.status())
            with contextlib.redirect_stdout(io.StringIO()):
                self.entry.launch('someone', check=True)
            args = run.call_args.args[0]
            self.assertEqual(args[:4], ['/usr/sbin/sshd', '-t', '-f', '/dev/null'])
            self.assertIn('PermitOpen=[/home/someone/.config/herdr/herdr.sock]:*', args)
            self.assertNotIn('-D', args)
            execute.assert_not_called()

    def test_unprivileged_runtime_and_offline_state_never_exec(self):
        with patch.object(self.entry.os, 'geteuid', return_value=1000), \
             patch.object(self.entry.os, 'execve') as execute:
            with self.assertRaises(PermissionError):
                self.entry.launch('someone')
            execute.assert_not_called()

    @unittest.skipUnless(Path('/usr/sbin/sshd').exists(), 'OpenSSH parser not installed')
    def test_actual_openssh_parser_accepts_restricted_socket_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            key = str(Path(directory) / 'hostkey')
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', key], check=True)
            args = self.entry.sshd_argv('someone', 1000, '/home/someone', '100.84.88.33')
            args.remove('-D')
            args.remove('-e')
            args[1:1] = ['-T', '-h', key]
            result = subprocess.run(args, capture_output=True, text=True, check=True)
            self.assertIn('allowtcpforwarding local', result.stdout)
            self.assertIn('permitopen [/home/someone/.config/herdr/herdr.sock]:*', result.stdout)


@unittest.skipUnless(sys.platform.startswith('linux') and os.getuid() >= 1000,
                     'preparation operates as an ordinary Linux user')
class HeelerPreparationTests(unittest.TestCase):
    def setUp(self):
        self.path = ROOT / 'tools/herdr/heeler/prepare.py'
        self.assertTrue(self.path.is_file(), 'Heeler preparation is missing')
        spec = importlib.util.spec_from_file_location('heeler_prepare', self.path)
        self.prep = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.prep)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.home.mkdir()
        self.uid = os.getuid()
        self.name = 'someone'
        self.calls = []
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        output = 'disabled\n' if 'is-enabled' in args else ''
        return subprocess.CompletedProcess(args, 0, output, '')

    def apply(self):
        with patch.object(self.prep, 'preflight'), \
             patch.object(self.prep, 'command', side_effect=self.fake_run):
            return self.prep.apply(ROOT, self.name, self.uid, self.home)

    def test_rendered_units_have_separate_authority_and_boot_dependencies(self):
        user, system = self.prep.render_units(ROOT, self.name, self.uid, self.home)
        self.assertIn('/usr/bin/mise exec -- %h/.local/bin/herdr server', user)
        self.assertIn('KillMode=mixed', user)
        self.assertNotIn('heeler-trial server', user)
        self.assertIn(str(ROOT / 'bin'), user)
        for text in ['Requires=tailscaled.service', 'StartLimitIntervalSec=0',
                     'Restart=on-failure', 'RestartSec=5',
                     '/usr/bin/python3 -I /usr/local/lib/dotfiles-heeler/sshd-entrypoint.py',
                     '--user someone', '/run/sshd', 'RuntimeDirectory=dotfiles-heeler']:
            self.assertIn(text, system)
        self.assertNotIn('100.84.', system)
        self.assertNotIn('/home/someone', system)

    def test_apply_stages_and_enables_without_starting_any_service(self):
        self.apply()
        self.assertTrue((self.home / '.config/systemd/user/dotfiles-herdr.service').is_file())
        self.assertTrue((self.home / '.local/share/heeler/dotfiles-heeler-sshd.service').is_file())
        self.assertEqual((self.home / '.local/share/heeler-trial/authorized_keys').stat().st_mode & 0o777, 0o600)
        self.assertTrue(any('enable' in call for call in self.calls))
        self.assertFalse(any(word in call for call in self.calls for word in ['start', 'restart', 'stop', 'sudo']))

    def test_existing_phone_key_is_preserved_and_reapply_is_noop(self):
        import base64
        import struct
        blob = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes(range(32))
        key = b'ssh-ed25519 ' + base64.b64encode(blob) + b' synthetic-test-key\n'
        target = self.home / '.local/share/heeler-trial/authorized_keys'
        target.parent.mkdir(parents=True, mode=0o700)
        target.write_bytes(key)
        target.chmod(0o600)
        self.apply()
        self.assertEqual(target.read_bytes(), key)
        self.calls.clear()
        def enabled(args, **kwargs):
            self.calls.append(args)
            return subprocess.CompletedProcess(args, 0, 'enabled\n', '')
        with patch.object(self.prep, 'preflight'), patch.object(self.prep, 'command', side_effect=enabled):
            self.prep.apply(ROOT, self.name, self.uid, self.home)
        self.assertFalse(any('enable' in call or 'daemon-reload' in call for call in self.calls))
        self.assertEqual(target.read_bytes(), key)

    def test_foreign_user_unit_is_refused_before_creating_key(self):
        unit = self.home / '.config/systemd/user/dotfiles-herdr.service'
        unit.parent.mkdir(parents=True)
        unit.write_text('[Service]\nExecStart=/bin/sleep infinity\n')
        with self.assertRaises(ValueError):
            self.apply()
        self.assertEqual(unit.read_text(), '[Service]\nExecStart=/bin/sleep infinity\n')
        self.assertFalse((self.home / '.local/share/heeler-trial').exists())

    def test_symlinked_key_and_stage_are_refused(self):
        target = self.home / '.local/share/heeler-trial/authorized_keys'
        target.parent.mkdir(parents=True)
        original = self.home / 'original'
        original.write_text('do not change')
        target.symlink_to(original)
        with self.assertRaises(ValueError):
            self.apply()
        self.assertEqual(original.read_text(), 'do not change')

    def test_failed_enable_restores_previous_unit_and_enablement(self):
        def fail_enable(args, **kwargs):
            self.calls.append(args)
            if 'enable' in args:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, 'disabled\n', '')
        with patch.object(self.prep, 'preflight'), \
             patch.object(self.prep, 'command', side_effect=fail_enable), \
             self.assertRaises(subprocess.CalledProcessError):
            self.prep.apply(ROOT, self.name, self.uid, self.home)
        self.assertFalse((self.home / '.config/systemd/user/dotfiles-herdr.service').exists())
        self.assertTrue(any('disable' in call for call in self.calls))

    def test_cgroup_identity_does_not_confuse_unmanaged_socket_with_owned_unit(self):
        self.assertFalse(self.prep.owned_cgroup('', '0::/user.slice/session.scope\n'))
        expected = '/user.slice/user-1000.slice/app.slice/dotfiles-herdr.service'
        self.assertFalse(self.prep.owned_cgroup(expected, '0::/user.slice/session.scope\n'))
        self.assertFalse(self.prep.owned_cgroup(expected, '0::' + expected + '-foreign\n'))
        self.assertTrue(self.prep.owned_cgroup(expected, '0::' + expected + '\n'))

    def test_backup_write_failures_leave_policy_unchanged_and_allow_retry(self):
        self.apply()
        paths = self.prep.paths(self.home)
        original = {path: path.read_bytes() for path in paths}
        for method in ['write_bytes', 'write_text']:
            with self.subTest(method=method):
                self.calls.clear()
                write = getattr(Path, method)
                def fail_backup(path, data, *args, write=write, **kwargs):
                    if path.parent.name.startswith('.rollback-'):
                        raise OSError('simulated backup write failure')
                    return write(path, data, *args, **kwargs)
                with patch.object(Path, method, fail_backup), \
                     patch.object(self.prep, 'atomic_write') as publish, \
                     self.assertRaisesRegex(OSError, 'backup write failure'):
                    self.apply()
                publish.assert_not_called()
                self.assertFalse(list(paths[1].parent.glob('.rollback-*')))
                self.assertEqual({path: path.read_bytes() for path in paths}, original)
                self.assertFalse(any('enable' in call or 'daemon-reload' in call for call in self.calls))
                self.apply()

    def test_backup_cleanup_failure_reports_retained_path_without_mutating_policy(self):
        self.apply()
        paths = self.prep.paths(self.home)
        original = {path: path.read_bytes() for path in paths}
        self.calls.clear()
        with patch.object(Path, 'write_text', side_effect=OSError('manifest write failure')), \
             patch.object(self.prep.shutil, 'rmtree', side_effect=OSError('cleanup failure')), \
             patch.object(self.prep, 'atomic_write') as publish, \
             self.assertRaisesRegex(RuntimeError, 'manifest write failure.*retained at.*cleanup failure'):
            self.apply()
        publish.assert_not_called()
        backups = list(paths[1].parent.glob('.rollback-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o700)
        self.assertEqual((backups[0] / '0').read_bytes(), original[paths[0]])
        self.assertEqual({path: path.read_bytes() for path in paths}, original)
        self.assertFalse(any('enable' in call or 'daemon-reload' in call for call in self.calls))

    def test_failed_rollback_retains_original_policy_for_operator_recovery(self):
        self.apply()
        unit = self.home / '.config/systemd/user/dotfiles-herdr.service'
        original = unit.read_bytes()
        write = self.prep.atomic_write
        def fail_restore(path, data, mode=0o644):
            if path == unit and data == original:
                raise OSError('simulated restore failure')
            write(path, data, mode)
        def fail_enable(args, **kwargs):
            if 'enable' in args:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, 'disabled\n', '')
        rendered = self.prep.render_units(ROOT, self.name, self.uid, self.home)
        with patch.object(self.prep, 'preflight'), \
             patch.object(self.prep, 'render_units', return_value=(rendered[0] + '# update\n', rendered[1])), \
             patch.object(self.prep, 'atomic_write', side_effect=fail_restore), \
             patch.object(self.prep, 'command', side_effect=fail_enable), \
             self.assertRaisesRegex(RuntimeError, 'retained'):
            self.prep.apply(ROOT, self.name, self.uid, self.home)
        backups = list((self.home / '.local/share/heeler').glob('.rollback-*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / '0').read_bytes(), original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o700)

    def test_stale_sshd_arguments_cannot_appear_managed_live(self):
        expected = self.prep.runtime.sshd_argv(self.name, self.uid, str(self.home), '100.84.88.33')
        correct = ('sshd: ' + ' '.join(expected) + ' [listener] 0 of 10-100 startups').encode() + b'\0'
        self.assertTrue(self.prep.sshd_process_matches(correct, expected))
        wrong = correct.replace(b'AllowTcpForwarding=local', b'AllowTcpForwarding=yes')
        self.assertFalse(self.prep.sshd_process_matches(wrong, expected))
        self.assertFalse(self.prep.sshd_process_matches(b'python3 unrelated-daemon\0', expected))

    def public_key(self):
        import base64
        import struct
        blob = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + bytes(range(32))
        target = self.home / '.local/share/heeler-trial/authorized_keys'
        target.write_text('ssh-ed25519 ' + base64.b64encode(blob).decode() + ' synthetic-test-key\n')
        target.chmod(0o600)
        return target

    def published_fixture(self):
        self.apply()
        self.public_key()
        entry = self.home / 'published-entry'
        entry.write_bytes(ENTRY.read_bytes())
        unit = self.home / 'published-unit'
        unit.write_bytes((self.home / '.local/share/heeler/dotfiles-heeler-sshd.service').read_bytes())
        self.enterContext(patch.object(self.prep, 'PUBLISHED_ENTRY', entry))
        self.enterContext(patch.object(self.prep, 'PUBLISHED_UNIT', unit))
        # Ownership is covered separately; emulate the operator-only copies.
        self.enterContext(patch.object(self.prep, 'trusted_root_path', return_value=True))

    def test_check_is_read_only_and_reports_operator_publication_pending(self):
        self.apply()
        key = self.public_key()
        unit, staged, _ = self.prep.paths(self.home)
        before = [(p.read_bytes(), p.stat().st_mtime_ns) for p in [unit, staged, key]]
        with patch.object(self.prep, 'PUBLISHED_ENTRY', self.home / 'not-published'):
            self.assertEqual(self.prep.inspect(ROOT, self.name, self.uid, self.home), 2)
        self.assertEqual(before, [(p.read_bytes(), p.stat().st_mtime_ns) for p in [unit, staged, key]])

    def test_running_but_disabled_services_are_not_reboot_managed(self):
        self.published_fixture()
        with patch.object(self.prep, 'command', side_effect=self.fake_run):
            self.assertEqual(self.prep.inspect(ROOT, self.name, self.uid, self.home), 2)
        self.assertIn('persistent enablement pending', self.output.getvalue())

    def test_existing_unmanaged_default_daemon_does_not_count_as_managed_live(self):
        self.published_fixture()
        def enabled(args, **kwargs):
            output = 'yes\n' if 'show-user' in args else 'enabled\n'
            if any(unit in args for unit in ['ssh.service', 'ssh.socket']):
                output = 'masked\n'
            return subprocess.CompletedProcess(args, 0, output, '')
        def states(unit, user=False):
            return {'ActiveState': 'inactive' if user else 'active', 'MainPID': '0' if user else '1234'}
        with patch.object(self.prep, 'command', side_effect=enabled), \
             patch.object(self.prep, 'unit_state', side_effect=states), \
             patch.object(self.prep, 'probe', return_value=os.getpid()) as probe:
            self.assertEqual(self.prep.inspect(ROOT, self.name, self.uid, self.home), 2)
            probe.assert_not_called()

    def test_concurrent_preparation_refuses_without_publishing(self):
        with patch.object(self.prep, 'preflight'), \
             patch.object(self.prep.fcntl, 'flock', side_effect=BlockingIOError), \
             self.assertRaises(BlockingIOError):
            self.prep.apply(ROOT, self.name, self.uid, self.home)
        self.assertFalse((self.home / '.config/systemd/user/dotfiles-herdr.service').exists())
        self.assertFalse((self.home / '.local/share/heeler-trial/authorized_keys').exists())

    def enabled_commands(self, args, **kwargs):
        output = 'yes\n' if 'show-user' in args else 'enabled\n'
        if any(unit in args for unit in ['ssh.service', 'ssh.socket']):
            output = 'masked\n'
        return subprocess.CompletedProcess(args, 0, output, '')

    def test_failed_managed_service_is_an_error_not_pending_cutover(self):
        self.published_fixture()
        with patch.object(self.prep, 'command', side_effect=self.enabled_commands), \
             patch.object(self.prep, 'unit_state', return_value={
                 'ActiveState': 'failed', 'SubState': 'failed', 'Result': 'exit-code', 'MainPID': '0'}), \
             self.assertRaisesRegex(ValueError, 'dotfiles-herdr.service.*failed'):
            self.prep.inspect(ROOT, self.name, self.uid, self.home)

    def restarting_fixture(self, failed_unit, network):
        self.published_fixture()
        def metadata(args, **kwargs):
            if args == ['/usr/bin/tailscale', 'status', '--json']:
                return subprocess.CompletedProcess(args, 0, json.dumps(network), '')
            return self.enabled_commands(args, **kwargs)
        def state(unit, user=False):
            if unit == failed_unit:
                return {'ActiveState': 'activating', 'SubState': 'auto-restart',
                        'Result': 'exit-code', 'MainPID': '0'}
            return {'ActiveState': 'active', 'SubState': 'running', 'Result': 'success', 'MainPID': '1234'}
        self.enterContext(patch.object(self.prep, 'command', side_effect=metadata))
        self.enterContext(patch.object(self.prep, 'unit_state', side_effect=state))

    def test_restarting_herdr_failure_is_not_pending_even_when_tailnet_offline(self):
        self.restarting_fixture('dotfiles-herdr.service', {'BackendState': 'Stopped'})
        with self.assertRaisesRegex(ValueError, 'dotfiles-herdr.service.*failed'):
            self.prep.inspect(ROOT, self.name, self.uid, self.home)

    def test_restarting_ssh_failure_on_online_tailnet_is_not_pending(self):
        self.restarting_fixture('dotfiles-heeler-sshd.service', {
            'BackendState': 'Running', 'Self': {'Online': True, 'TailscaleIPs': ['100.84.88.33']}})
        with self.assertRaisesRegex(ValueError, 'dotfiles-heeler-sshd.service.*failed'):
            self.prep.inspect(ROOT, self.name, self.uid, self.home)

    def test_restarting_ssh_waits_explicitly_for_offline_tailnet(self):
        for network in [{'BackendState': 'Stopped'},
                        {'BackendState': 'Running', 'Self': {'Online': False}}]:
            with self.subTest(network=network):
                # Reuse the prepared publication while varying external state.
                if not (self.home / 'published-entry').exists():
                    self.restarting_fixture('dotfiles-heeler-sshd.service', network)
                with patch.object(self.prep, 'command', side_effect=lambda args, network=network, **kwargs:
                                  subprocess.CompletedProcess(args, 0, json.dumps(network), '')
                                  if 'tailscale' in args[0] else self.enabled_commands(args, **kwargs)):
                    self.output.truncate(0)
                    self.output.seek(0)
                    self.assertEqual(self.prep.inspect(ROOT, self.name, self.uid, self.home), 2)
                    self.assertIn('waiting for online Tailscale', self.output.getvalue())

    def test_invalid_online_tailnet_metadata_is_not_expected_offline_waiting(self):
        self.restarting_fixture('dotfiles-heeler-sshd.service', {
            'BackendState': 'Running', 'Self': {'Online': True, 'TailscaleIPs': ['127.0.0.1']}})
        with self.assertRaisesRegex(ValueError, 'Tailscale IPv4'):
            self.prep.inspect(ROOT, self.name, self.uid, self.home)

    def test_service_inspection_failure_is_not_silently_an_inactive_unit(self):
        def unavailable(args, check=False, **kwargs):
            if check:
                raise subprocess.CalledProcessError(1, args, stderr='bus unavailable')
            return subprocess.CompletedProcess(args, 1, '', 'bus unavailable')
        with patch.object(self.prep, 'command', side_effect=unavailable), \
             self.assertRaises(subprocess.CalledProcessError):
            self.prep.unit_state('dotfiles-herdr.service', user=True)

    def test_reapply_warns_when_phone_key_was_lost(self):
        self.apply()
        key = self.public_key()
        key.unlink()
        self.output.truncate(0)
        self.output.seek(0)
        with patch.object(self.prep, 'preflight'), \
             patch.object(self.prep, 'command', side_effect=self.enabled_commands):
            self.prep.apply(ROOT, self.name, self.uid, self.home)
        self.assertEqual(key.read_bytes(), b'')
        self.assertIn('Phone enrollment required', self.output.getvalue())

    def test_key_bootstrap_does_not_replace_concurrently_enrolled_key(self):
        self.apply()
        key = self.public_key()
        expected = key.read_bytes()
        key.unlink()
        exists = Path.exists
        calls = 0
        def enrolling(path):
            nonlocal calls
            if path == key:
                calls += 1
                if calls == 3:
                    key.write_bytes(expected)
                    key.chmod(0o600)
                    return False
            return exists(path)
        with patch.object(self.prep, 'preflight'), \
             patch.object(self.prep, 'command', side_effect=self.enabled_commands), \
             patch.object(Path, 'exists', enrolling):
            self.prep.apply(ROOT, self.name, self.uid, self.home)
        self.assertEqual(key.read_bytes(), expected)

    @unittest.skipUnless(Path('/usr/bin/systemctl').exists(), 'systemd unit-file tool not installed')
    def test_enabling_listener_installs_tailscale_start_dependency(self):
        _, system = self.prep.render_units(ROOT, self.name, self.uid, self.home)
        unit_dir = self.home / 'unit-root/etc/systemd/system'
        unit_dir.mkdir(parents=True)
        (unit_dir / 'dotfiles-heeler-sshd.service').write_text(system)
        result = subprocess.run(['/usr/bin/systemctl', '--root', str(self.home / 'unit-root'),
                                 'enable', 'dotfiles-heeler-sshd.service'],
                                capture_output=True, text=True, check=True)
        link = unit_dir / 'tailscaled.service.wants/dotfiles-heeler-sshd.service'
        self.assertTrue(link.is_symlink(), result.stderr)

    def test_malformed_ping_replies_have_a_specific_error(self):
        packets = [[], {'id': 'dotfiles-heeler-check', 'result': []},
                   {'id': 'dotfiles-heeler-check', 'result': {'type': 'pong', 'protocol': '19'}}]
        for packet in packets:
            with self.subTest(packet=packet), patch.object(self.prep.socket, 'socket') as constructor:
                connection = constructor.return_value.__enter__.return_value
                connection.getsockopt.return_value = struct.pack('3i', 123, self.uid, self.uid)
                connection.recv.return_value = json.dumps(packet).encode() + b'\n'
                with self.assertRaisesRegex(ValueError, 'supported ping protocol'):
                    self.prep.probe(self.home, self.uid)

    def test_unavailable_enablement_inspection_is_not_pending(self):
        self.published_fixture()
        def unavailable(args, **kwargs):
            return subprocess.CompletedProcess(args, 1, '', 'bus unavailable')
        with patch.object(self.prep, 'command', side_effect=unavailable), \
             self.assertRaisesRegex(ValueError, 'cannot inspect.*enablement'):
            self.prep.inspect(ROOT, self.name, self.uid, self.home)

    def preflight_metadata(self, args, **kwargs):
        if args[0] == '/usr/bin/busctl':
            data = ['HOME=' + str(self.home), 'PATH=/manager/old-path',
                    'MISE_ENV=manager-preference', 'EXAMPLE_CREDENTIAL=synthetic-test-value']
            output = json.dumps({'type': 'as', 'data': data})
        elif 'rev-parse' in args:
            output = '/repo/.git\n/repo/.git\n'
        elif 'show-user' in args:
            output = 'yes\n'
        elif '--version' in args:
            output = 'v26.5.0\n' if args[-2:] == ['node', '--version'] else 'herdr 0.8.0\n'
        else:
            output = 'masked\n'
        return subprocess.CompletedProcess(args, 0, output, '')

    def test_preflight_uses_manager_preferences_and_the_rendered_service_path(self):
        probes = []
        def metadata(args, **kwargs):
            if args[0] == '/usr/bin/mise':
                probes.append(kwargs)
            return self.preflight_metadata(args, **kwargs)
        with patch.object(self.prep, 'command', side_effect=metadata), \
             patch.object(self.prep.os, 'access', return_value=True), \
             patch.dict(os.environ, {'PATH': '/shell-only-node', 'MISE_ENV': 'shell-only-override'}):
            self.prep.preflight(ROOT, self.name, self.uid, self.home)
        expected_path = (f'{self.home}/.pi/agent/bin:{ROOT}/bin:{self.home}/.local/bin:'
                         '/usr/local/bin:/usr/bin:/bin')
        self.assertEqual(len(probes), 2)
        for kwargs in probes:
            self.assertIn('env', kwargs)
            self.assertEqual(kwargs['env'], {'HOME': str(self.home), 'PATH': expected_path,
                             'MISE_ENV': 'manager-preference', 'EXAMPLE_CREDENTIAL': 'synthetic-test-value'})
        user, _ = self.prep.render_units(ROOT, self.name, self.uid, self.home)
        self.assertIn('Environment="PATH=' + expected_path.replace(str(self.home), '%h') + '"', user)
        self.assertNotIn('synthetic-test-value', self.output.getvalue())

    def test_shell_only_node_cannot_satisfy_boot_service_preflight(self):
        def metadata(args, **kwargs):
            if args[-2:] == ['node', '--version']:
                environment = kwargs.get('env', os.environ)
                if environment.get('PATH') != '/shell-only-node':
                    raise subprocess.CalledProcessError(1, args)
            return self.preflight_metadata(args, **kwargs)
        with patch.object(self.prep, 'command', side_effect=metadata), \
             patch.object(self.prep.os, 'access', return_value=True), \
             patch.dict(os.environ, {'PATH': '/shell-only-node'}), \
             self.assertRaisesRegex(ValueError, 'Node.*mise'):
            self.prep.preflight(ROOT, self.name, self.uid, self.home)

    def test_manager_environment_shape_errors_do_not_echo_values(self):
        for response in [{'type': 's', 'data': 'synthetic-private-marker'},
                         {'type': 'as', 'data': ['synthetic-private-marker']},
                         {'type': 'as', 'data': ['HOME=/other-home']}]:
            with self.subTest(response=response), \
                 patch.object(self.prep, 'command', return_value=subprocess.CompletedProcess(
                     [], 0, json.dumps(response), '')):
                with self.assertRaises(ValueError) as caught:
                    self.prep.service_environment(ROOT, self.home)
                self.assertNotIn('synthetic-private-marker', str(caught.exception))

    def test_preflight_checks_node_through_mise_before_writing(self):
        def metadata(args, **kwargs):
            if args[-2:] == ['node', '--version']:
                raise subprocess.CalledProcessError(1, args)
            return self.preflight_metadata(args, **kwargs)
        with patch.object(self.prep, 'command', side_effect=metadata), \
             patch.object(self.prep.os, 'access', return_value=True), \
             self.assertRaisesRegex(ValueError, 'Node.*mise'):
            self.prep.preflight(ROOT, self.name, self.uid, self.home)
        self.assertFalse((self.home / '.local/share/heeler').exists())

    def live_inspection_fixture(self):
        self.published_fixture()
        cgroup = Path('/proc/self/cgroup').read_text().split('::', 1)[1].strip()
        def metadata(args, **kwargs):
            if args[0] == '/usr/bin/ss':
                return subprocess.CompletedProcess(args, 0, self.listener_output, '')
            if args[0] == '/usr/bin/tailscale':
                return subprocess.CompletedProcess(args, 0, json.dumps({
                    'BackendState': 'Running', 'Self': {
                        'Online': True, 'TailscaleIPs': ['100.84.88.33']}}), '')
            return self.enabled_commands(args, **kwargs)
        def states(unit, user=False):
            return {'ActiveState': 'active', 'SubState': 'running', 'Result': 'success',
                    'MainPID': str(os.getpid()), 'ControlGroup': cgroup,
                    'FragmentPath': str(self.prep.paths(self.home)[0] if user else self.prep.PUBLISHED_UNIT)}
        self.enterContext(patch.object(self.prep, 'command', side_effect=metadata))
        self.enterContext(patch.object(self.prep, 'unit_state', side_effect=states))
        self.enterContext(patch.object(self.prep, 'probe', return_value=os.getpid()))
        self.enterContext(patch.object(self.prep, 'sshd_process_matches', return_value=True))

    def test_listener_inspection_accepts_only_one_current_tailnet_listener(self):
        self.live_inspection_fixture()
        self.listener_output = 'LISTEN 0 128 100.84.88.33:2222 0.0.0.0:*\n'
        self.assertEqual(self.prep.inspect(ROOT, self.name, self.uid, self.home), 0)

    def test_listener_inspection_bounds_fields_and_rejects_wrong_or_extra_bindings(self):
        self.live_inspection_fixture()
        valid = 'LISTEN 0 128 100.84.88.33:2222 0.0.0.0:*\n'
        for output in ['', 'LISTEN\n', 'LISTEN 0 128\n', valid + valid,
                       'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n']:
            with self.subTest(output=output):
                self.listener_output = output
                with self.assertRaisesRegex(ValueError, 'SSH listener'):
                    self.prep.inspect(ROOT, self.name, self.uid, self.home)

    def test_root_publication_rejects_writable_or_symlinked_paths(self):
        directory = self.home / 'root-publish'
        directory.mkdir(mode=0o777)
        directory.chmod(0o777)
        entry = directory / 'entrypoint'
        entry.write_text('not a trusted root entrypoint')
        self.assertFalse(self.prep.trusted_root_path(entry))
        alias = self.home / 'alias'
        alias.symlink_to(entry)
        self.assertFalse(self.prep.trusted_root_path(alias))


if __name__ == '__main__':
    unittest.main()
