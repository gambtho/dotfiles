"""Operator publication and onboarding without real privilege or live services."""
import base64
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'tools/herdr/heeler'


def load(name):
    path = SOURCE / (name + '.py')
    spec = importlib.util.spec_from_file_location('heeler_' + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PUBLIC_KEY = b'ssh-ed25519 ' + base64.b64encode(b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20' + b'k' * 32) + b' phone\n'


class OnboardingTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((SOURCE / 'onboard.py').is_file(), 'guided onboarding is missing')
        self.board = load('onboard')
        self.real_discover = self.board.discover
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'home'
        self.home.mkdir()
        self.account = types.SimpleNamespace(pw_name='someone', pw_uid=os.getuid(), pw_dir=str(self.home))
        self.identity = {'InvocationID': 'a' * 32, 'MainPID': '123', 'ActiveState': 'active'}
        self.info = {'name': 'someone', 'uid': os.getuid(), 'home': self.home,
                     'manager': self.identity, 'address': '100.84.88.33'}
        self.output = io.StringIO()
        patches = [patch.dict(os.environ, {'DOTFILES_HEELER_ENABLED': '1', 'HOME': str(self.home)}),
                   patch.object(self.board.pwd, 'getpwuid', return_value=self.account),
                   patch.object(self.board.sys.stdin, 'isatty', return_value=True),
                   patch.object(self.board, 'discover', return_value=self.info),
                   patch.object(self.board.prepare, 'inspect', return_value=2),
                   patch.object(self.board.prepare, 'apply'),
                   patch.object(self.board, 'invoke_publication', return_value=0),
                   patch.object(self.board, 'connection_card', return_value='Host 100.84.88.33 / Port 2222 / default'),
                   patch('sys.stdout', self.output)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.keys = self.board.prepare.paths(self.home)[2]

    def setup_host(self, answers):
        answers = iter(answers)
        return self.board.setup(ROOT, None, input_fn=lambda _: next(answers))

    def test_setup_creates_key_and_invokes_one_privilege_phase_then_existing_apply(self):
        self.assertEqual(self.setup_host([PUBLIC_KEY.decode(), 'publish']), 2)
        self.assertEqual(self.keys.read_bytes(), PUBLIC_KEY)
        self.assertEqual(self.keys.stat().st_mode & 0o777, 0o600)
        self.board.invoke_publication.assert_called_once()
        self.board.prepare.apply.assert_called_once_with(ROOT, 'someone', os.getuid(), self.home)
        argv = self.board.invoke_publication.call_args.args[0]
        self.assertEqual(argv[0], '/usr/bin/sudo')
        self.assertIn('Root phase completed', self.output.getvalue())
        self.assertIn('default', self.output.getvalue())

    def test_cancel_before_root_keeps_missing_enrollment_missing(self):
        self.assertEqual(self.setup_host([PUBLIC_KEY.decode(), 'no']), 2)
        self.assertFalse(self.keys.exists())
        self.board.invoke_publication.assert_not_called()
        self.board.prepare.apply.assert_not_called()

    def test_root_failure_retains_enrollment_but_does_not_apply_or_claim_health(self):
        self.board.invoke_publication.return_value = 1
        self.assertEqual(self.setup_host([PUBLIC_KEY.decode(), 'publish']), 1)
        self.assertEqual(self.keys.read_bytes(), PUBLIC_KEY)
        self.board.prepare.apply.assert_not_called()
        self.assertNotIn('Root phase completed', self.output.getvalue())

    def test_user_phase_failure_reports_root_already_completed_and_preserves_key(self):
        self.board.prepare.apply.side_effect = OSError('user write failed')
        self.assertEqual(self.setup_host([PUBLIC_KEY.decode(), 'publish']), 1)
        self.assertIn('Root phase completed', self.output.getvalue())
        self.assertIn('user write failed', self.output.getvalue())
        self.assertTrue(self.keys.exists())

    def test_already_healthy_preserves_key_and_uses_no_privilege_or_apply(self):
        self.board.enroll_public_key(self.home, PUBLIC_KEY)
        before = self.keys.read_bytes()
        self.board.prepare.inspect.return_value = 0
        self.assertEqual(self.setup_host([]), 0)
        self.assertEqual(self.keys.read_bytes(), before)
        self.board.invoke_publication.assert_not_called()
        self.board.prepare.apply.assert_not_called()

    def test_selector_optout_and_discovery_blockers_have_no_enrollment_or_privilege(self):
        with patch.dict(os.environ, {'DOTFILES_HEELER_ENABLED': '0'}):
            self.assertEqual(self.setup_host([]), 0)
        self.board.discover.assert_not_called()
        self.board.discover.side_effect = self.board.Pending('active user manager required')
        self.assertEqual(self.setup_host([]), 2)
        self.assertFalse(self.keys.exists())
        self.board.invoke_publication.assert_not_called()

    def test_private_keys_and_empty_existing_key_files_never_reach_privilege(self):
        self.assertEqual(self.setup_host(['-----BEGIN OPENSSH PRIVATE KEY-----']), 1)
        self.assertFalse(self.keys.exists())
        self.keys.parent.mkdir(parents=True, mode=0o700)
        self.keys.write_bytes(b'')
        self.keys.chmod(0o600)
        self.assertEqual(self.setup_host([]), 2)
        self.assertEqual(self.keys.read_bytes(), b'')
        self.board.invoke_publication.assert_not_called()

    def test_discovery_rejects_inactive_manager_and_linked_worktree_before_enrollment(self):
        def metadata(args, **kwargs):
            if 'show' in args:
                output = '\n'.join(k + '=' + v for k, v in self.identity.items())
            else:
                output = '/repo/.git/worktrees/feature\n/repo/.git\n'
            return subprocess.CompletedProcess(args, 0, output, '')
        with patch.object(self.board.prepare, 'command', side_effect=metadata):
            with self.assertRaisesRegex(ValueError, 'canonical'):
                self.real_discover(ROOT, 'someone', os.getuid(), self.home)
            self.identity['ActiveState'] = 'inactive'
            with self.assertRaises(self.board.Pending):
                self.real_discover(ROOT, 'someone', os.getuid(), self.home)
        self.assertFalse(self.keys.exists())
        self.board.invoke_publication.assert_not_called()

    def test_unavailable_system_manager_has_actionable_pending_without_privilege(self):
        with patch.object(self.board.prepare, 'command', side_effect=subprocess.CalledProcessError(1, ['/usr/bin/systemctl'])), \
             self.assertRaisesRegex(self.board.Pending, 'manager'):
            self.real_discover(ROOT, 'someone', os.getuid(), self.home)
        self.board.invoke_publication.assert_not_called()

    def test_offline_tailnet_is_pending_without_join_or_privilege(self):
        calls = []
        def metadata(args, **kwargs):
            calls.append(args)
            if 'show' in args:
                output = '\n'.join(k + '=' + v for k, v in self.identity.items())
            elif 'is-enabled' in args:
                output = 'masked\n'
            elif args[0] == '/usr/bin/tailscale':
                output = '{"BackendState":"NeedsLogin"}'
            else:
                output = ''
            return subprocess.CompletedProcess(args, 0, output, '')
        with patch.object(self.board.prepare, 'prerequisites'), \
             patch.object(self.board.prepare, 'command', side_effect=metadata), \
             self.assertRaises(self.board.Pending):
            self.real_discover(ROOT, 'someone', os.getuid(), self.home)
        self.assertEqual([c[1:] for c in calls if c[0] == '/usr/bin/tailscale'], [['status', '--json']])
        self.board.invoke_publication.assert_not_called()

    def test_enrollment_race_never_replaces_the_winner(self):
        original = self.board.os.open
        winner = PUBLIC_KEY.replace(b'phone', b'other-phone')
        def race(path, flags, mode=0o777, **kwargs):
            if Path(path) == self.keys and flags & os.O_EXCL:
                with os.fdopen(original(path, flags, mode), 'wb') as stream:
                    stream.write(winner)
            return original(path, flags, mode, **kwargs)
        with patch.object(self.board.os, 'open', side_effect=race), self.assertRaisesRegex(ValueError, 'concurrent'):
            self.board.enroll_public_key(self.home, PUBLIC_KEY)
        self.assertEqual(self.keys.read_bytes(), winner)

    def test_noninteractive_setup_does_not_enroll_or_invoke_privilege(self):
        with patch.object(self.board.sys.stdin, 'isatty', return_value=False):
            self.assertEqual(self.setup_host([]), 2)
        self.assertFalse(self.keys.exists())
        self.board.invoke_publication.assert_not_called()


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((SOURCE / 'publish.py').is_file(), 'isolated publisher is missing')
        self.pub = load('publish')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.stage = self.root / 'stage'
        self.stage.mkdir(mode=0o700)
        for name in self.pub.PAYLOADS:
            (self.stage / name).write_bytes((SOURCE / name).read_bytes())
        self.identity = {'InvocationID': 'a' * 32, 'MainPID': '123', 'ActiveState': 'active'}
        self.calls = []
        self.enabled = False
        self.account = types.SimpleNamespace(pw_name='someone', pw_uid=os.getuid(), pw_dir=str(self.home))
        self.patches = [
            patch.object(self.pub, 'ROOT_UID', os.getuid()),
            patch.object(self.pub, 'ROOT_ANCHOR', self.root),
            patch.object(self.pub, 'LIB', self.root / 'lib'),
            patch.object(self.pub, 'UNIT', self.root / 'system/dotfiles-heeler-sshd.service'),
            patch.object(self.pub, 'STATE', self.root / 'state'),
            patch.object(self.pub, 'PRIVSEP', self.root / 'run/sshd'),
            patch.object(self.pub, 'STAGE', self.stage),
            patch.object(self.pub.os, 'geteuid', return_value=0),
            patch.object(self.pub.pwd, 'getpwnam', return_value=self.account),
            patch.dict(os.environ, {'SUDO_UID': str(os.getuid()), 'SUDO_USER': 'someone'}),
            patch.object(self.pub, 'run', side_effect=self.run_command),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def run_command(self, args, *, check=True, **kwargs):
        self.calls.append(args)
        if '--check' in args:
            self.assertTrue(self.pub.PRIVSEP.is_dir(), 'privsep must exist before sshd prevalidation')
        if 'show' in args:
            output = '\n'.join(k + '=' + v for k, v in self.identity.items())
        elif 'is-enabled' in args:
            output = 'masked\n' if args[-1] in ('ssh.service', 'ssh.socket') else ('enabled\n' if self.enabled else 'disabled\n')
        elif 'show-user' in args:
            output = 'yes\n'
        elif args[0] == '/usr/bin/tailscale':
            output = json.dumps({'BackendState': 'Running', 'Self': {'Online': True, 'TailscaleIPs': ['100.84.88.33']}})
        else:
            output = ''
        if 'enable' in args:
            self.enabled = True
        if 'disable' in args:
            self.enabled = False
        return subprocess.CompletedProcess(args, 0, output, '')

    def publish(self):
        return self.pub.publish_for_account('someone', self.identity)

    def test_publication_validates_privsep_and_enables_without_start(self):
        self.publish()
        self.assertEqual((self.pub.LIB / 'sshd-entrypoint.py').read_bytes(), (SOURCE / 'sshd-entrypoint.py').read_bytes())
        expected = (SOURCE / 'dotfiles-heeler-sshd.service.in').read_text().replace('@USER@', 'someone')
        self.assertEqual(self.pub.UNIT.read_text(), expected)
        self.assertEqual(self.pub.PRIVSEP.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.pub.STATE.stat().st_mode & 0o777, 0o700)
        self.assertTrue(self.enabled)
        self.assertFalse(any(word in call for call in self.calls for word in ('start', 'stop', 'restart', '--now')))
        receipt = json.loads((self.pub.STATE / 'ownership.json').read_text())
        self.assertEqual(receipt['schema_version'], 1)
        self.assertEqual(receipt['account'], 'someone')
        self.assertEqual(receipt['files'][str(self.pub.UNIT)]['mode'], 0o644)
        self.publish()

    def test_changed_or_inactive_manager_refuses_before_publication(self):
        for changed in [{'MainPID': '124'}, {'InvocationID': 'b' * 32}, {'ActiveState': 'inactive'}]:
            with self.subTest(changed=changed):
                identity = dict(self.identity, **changed)
                with self.assertRaisesRegex(ValueError, 'manager'):
                    self.pub.publish_for_account('someone', identity)
                self.assertFalse(self.pub.UNIT.exists())
                self.assertFalse(any('enable-linger' in c for c in self.calls))

    def test_invoker_mismatch_and_unsafe_root_directories_are_refused(self):
        with patch.dict(os.environ, {'SUDO_UID': '999'}), self.assertRaisesRegex(ValueError, 'account'):
            self.publish()
        self.pub.STATE.mkdir(mode=0o700)
        self.pub.STATE.chmod(0o777)
        with self.assertRaisesRegex(ValueError, 'ownership|mode'):
            self.publish()
        self.assertFalse(self.pub.UNIT.exists())

    def test_foreign_port_2222_listener_blocks_publication(self):
        def foreign(args, **kwargs):
            if args[0] == '/usr/bin/ss' and args[-1] == 'sport = :2222':
                return subprocess.CompletedProcess(args, 0, 'LISTEN 0 128 100.84.88.33:2222 0.0.0.0:*\n', '')
            return self.run_command(args, **kwargs)
        with patch.object(self.pub, 'run', side_effect=foreign), self.assertRaisesRegex(ValueError, 'listener'):
            self.publish()
        self.assertFalse(self.pub.UNIT.exists())
        self.assertFalse(self.pub.STATE.exists())

    def test_foreign_root_policy_is_never_overwritten(self):
        self.pub.LIB.mkdir()
        original = self.pub.LIB / 'sshd-entrypoint.py'
        original.write_bytes(b'foreign policy')
        with self.assertRaisesRegex(ValueError, 'foreign|partial'):
            self.publish()
        self.assertEqual(original.read_bytes(), b'foreign policy')

    def test_failed_enable_rolls_back_new_policy_and_retains_no_false_receipt(self):
        def fail(args, **kwargs):
            if 'enable' in args:
                self.enabled = True
                raise subprocess.CalledProcessError(1, args)
            return self.run_command(args, **kwargs)
        with patch.object(self.pub, 'run', side_effect=fail), self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertFalse(self.pub.UNIT.exists())
        self.assertFalse((self.pub.LIB / 'sshd-entrypoint.py').exists())
        self.assertFalse((self.pub.STATE / 'ownership.json').exists())
        self.assertFalse(self.enabled)

    def test_failed_snapshot_cleanup_preserves_both_errors_and_private_evidence(self):
        original_write = self.pub.write_owned
        def fail(path, data, mode):
            if path.name == 'manifest.json':
                raise OSError('snapshot write failed')
            return original_write(path, data, mode)
        with patch.object(self.pub, 'write_owned', side_effect=fail), \
             patch.object(self.pub.shutil, 'rmtree', side_effect=OSError('cleanup failed')), \
             self.assertRaisesRegex(RuntimeError, 'snapshot write failed.*cleanup failed.*retained'):
            self.publish()
        self.assertFalse(self.pub.UNIT.exists())
        self.assertEqual(len(list(self.pub.STATE.glob('recovery-*'))), 1)

    def test_failure_before_enable_does_not_disable_an_unpublished_unit(self):
        original_write = self.pub.write_owned
        def fail(path, data, mode):
            if path == self.pub.LIB / 'sshd-entrypoint.py':
                raise OSError('entry write failed')
            return original_write(path, data, mode)
        with patch.object(self.pub, 'write_owned', side_effect=fail), self.assertRaisesRegex(OSError, 'entry write'):
            self.publish()
        self.assertFalse(any('disable' in c for c in self.calls))
        self.assertFalse(self.pub.UNIT.exists())

    def test_manager_replacement_after_policy_enable_never_enables_linger(self):
        def replace(args, **kwargs):
            if 'show' in args and self.enabled:
                return subprocess.CompletedProcess(args, 0, 'InvocationID=' + 'b' * 32 + '\nMainPID=124\nActiveState=active\n', '')
            return self.run_command(args, **kwargs)
        with patch.object(self.pub, 'run', side_effect=replace), self.assertRaisesRegex(ValueError, 'manager'):
            self.publish()
        self.assertFalse(any('enable-linger' in c for c in self.calls))
        self.assertFalse(self.pub.UNIT.exists())

    def test_failed_recovery_retains_private_originals_and_reports_both_errors(self):
        def fail(args, **kwargs):
            if 'enable' in args:
                raise OSError('enable failed')
            if 'disable' in args:
                raise OSError('disable failed')
            return self.run_command(args, **kwargs)
        with patch.object(self.pub, 'run', side_effect=fail), self.assertRaisesRegex(RuntimeError, 'enable failed.*disable failed.*retained'):
            self.publish()
        backups = list(self.pub.STATE.glob('recovery-*'))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / 'manifest.json').is_file())
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o700)

    def test_unresolved_root_recovery_blocks_retry_without_overwriting_evidence(self):
        self.pub.STATE.mkdir(mode=0o700)
        recovery = self.pub.STATE / 'recovery-unresolved'
        recovery.mkdir(mode=0o700)
        (recovery / 'manifest.json').write_bytes(b'original recovery evidence')
        with self.assertRaisesRegex(ValueError, 'recovery'):
            self.publish()
        self.assertEqual((recovery / 'manifest.json').read_bytes(), b'original recovery evidence')
        self.assertFalse(self.pub.UNIT.exists())

    def test_failure_after_linger_reports_persisting_lingering_honestly(self):
        original_write = self.pub.write_owned
        def no_linger(args, **kwargs):
            if 'show-user' in args:
                return subprocess.CompletedProcess(args, 0, 'no\n', '')
            return self.run_command(args, **kwargs)
        def fail_receipt(path, data, mode):
            if path.name == 'ownership.json':
                raise OSError('receipt write failed')
            return original_write(path, data, mode)
        errors = io.StringIO()
        with patch.object(self.pub, 'run', side_effect=no_linger), \
             patch.object(self.pub, 'write_owned', side_effect=fail_receipt), \
             patch('sys.stderr', errors), self.assertRaisesRegex(OSError, 'receipt write'):
            self.publish()
        self.assertIn('lingering may now be enabled', errors.getvalue())
        self.assertFalse(self.pub.UNIT.exists())

    def test_lingering_is_enabled_only_after_active_manager_recheck(self):
        def no_linger(args, **kwargs):
            if 'show-user' in args:
                self.calls.append(args)
                return subprocess.CompletedProcess(args, 0, 'no\n', '')
            return self.run_command(args, **kwargs)
        with patch.object(self.pub, 'run', side_effect=no_linger):
            result = self.publish()
        linger_index = next(i for i, c in enumerate(self.calls) if 'enable-linger' in c)
        self.assertIn('show', self.calls[linger_index - 1])
        self.assertIn('user@' + str(os.getuid()) + '.service', self.calls[linger_index - 1])
        self.assertIn('enabled', result['lingering'])
        self.assertFalse(any(word in call for call in self.calls for word in ('start', 'restart', '--now')))

    def test_root_stage_symlink_is_rejected_before_import_or_commands(self):
        runtime = self.stage / 'sshd-entrypoint.py'
        runtime.unlink()
        runtime.symlink_to(SOURCE / 'sshd-entrypoint.py')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.publish()
        self.assertFalse(self.pub.UNIT.exists())

    def test_bootstrap_copies_captured_bytes_not_a_reopened_user_path(self):
        hashes = {n: hashlib.sha256((self.stage / n).read_bytes()).hexdigest() for n in self.pub.PAYLOADS}
        original = (self.stage / 'publish.py').read_bytes()
        namespace = {'__name__': 'bootstrap_test'}
        exec(self.pub.BOOTSTRAP_CODE, namespace)  # noqa: S102 -- fixed reviewed test bootstrap, no untrusted code
        namespace['ROOT_UID'] = os.getuid()
        namespace['ROOT_ANCHOR'] = self.root
        mkdtemp = tempfile.mkdtemp
        def replace(**kwargs):
            (self.stage / 'publish.py').write_bytes(b'changed after verification')
            return mkdtemp(**kwargs)
        with patch.object(namespace['tempfile'], 'mkdtemp', side_effect=replace):
            staged = namespace['stage_bundle'](self.stage, hashes, os.getuid(), self.root / 'protected')
        self.assertEqual((staged / 'publish.py').read_bytes(), original)

    def test_bootstrap_binds_digests_to_one_explicit_isolated_privilege_call(self):
        hashes = {n: hashlib.sha256((self.stage / n).read_bytes()).hexdigest() for n in self.pub.PAYLOADS}
        argv = self.pub.build_bootstrap(self.stage, hashes, 'someone', self.identity)
        self.assertEqual(argv[:5], ['/usr/bin/sudo', '--', '/usr/bin/python3', '-I', '-c'])
        self.assertNotIn(str(SOURCE / 'publish.py'), argv)
        namespace = {'__name__': 'bootstrap_test'}
        exec(self.pub.BOOTSTRAP_CODE, namespace)  # noqa: S102 -- exercise fixed reviewed bootstrap, never caller code
        namespace['ROOT_UID'] = os.getuid()
        namespace['ROOT_ANCHOR'] = self.root
        target = self.root / 'protected'
        staged = namespace['stage_bundle'](self.stage, hashes, os.getuid(), target)
        self.assertEqual((staged / 'publish.py').read_bytes(), (self.stage / 'publish.py').read_bytes())
        (self.stage / 'sshd-entrypoint.py').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'digest'):
            namespace['stage_bundle'](self.stage, hashes, os.getuid(), target)
        (self.stage / 'sshd-entrypoint.py').unlink()
        (self.stage / 'sshd-entrypoint.py').symlink_to(SOURCE / 'sshd-entrypoint.py')
        with self.assertRaises((ValueError, OSError)):
            namespace['stage_bundle'](self.stage, hashes, os.getuid(), target)
