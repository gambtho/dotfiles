"""Operator publication and onboarding without real privilege or live services."""
import hashlib
import importlib.util
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
