"""Remote-lane boundary tests. All hosts/processes/files are fictional or isolated."""
import contextlib
import importlib.util
import io
import json
import os
import pwd
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'tools/herdr/lanes'


def load(name):
    spec = importlib.util.spec_from_file_location(name, SOURCE / f'{name}.py')
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.local = self.home / 'local/orchard-local'
        self.root = self.home / 'remote/orchard-local'
        self.local.mkdir(parents=True)
        self.root.mkdir(parents=True)
        self.user = pwd.getpwuid(os.geteuid()).pw_name
        self.config = dict(machine_id='saved-id', saved_target='saved-alias', target='fictional',
                           session='default', hostname=socket.gethostname(), user=self.user,
                           root=str(self.root), herdr='/bin/true', mise='/bin/true', pi='/bin/true',
                           transport='tailscale', agents='agents.md', rules='rules.md', profile='profile.md')
        for name in ('agents.md', 'rules.md', 'profile.md', 'task.md'):
            (self.local / name).write_text('fresh ' + name)
        self.write_config()
        self.spaces = [{'workspace_id': 'w1', 'label': 'existing'}]
        self.panes: list[dict] = [{'workspace_id': 'w1', 'pane_id': 'w1:p1', 'terminal_id': 'term_original'}]
        self.calls = []
        self.copies = []
        self.busy = False
        self.bad_snapshot = False
        self.failure = None
        self.malformed = False
        self.remote = load('remote')
        self.lane = load('lane')
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {'HOME': str(self.home / 'local'),
                                'XDG_STATE_HOME': str(self.home / 'state')}).start()
        patch.object(self.remote.Remote, 'run', autospec=True, side_effect=self.run_boundary).start()
        patch.object(self.lane.time, 'sleep').start()

    def write_config(self):
        (self.local / 'lane-hosts.json').write_text(json.dumps({'build': self.config}))

    def snapshot(self):
        return {'version': '0.9.5', 'protocol': 22, 'workspaces': self.spaces[:],
                'panes': self.panes[:], 'tabs': [], 'layouts': [], 'agents': []}

    def api(self, args):
        self.calls.append(args)
        if self.failure == tuple(args[:2]):
            raise ValueError('timed out; inspect, do not resend')
        if args == ['machine', 'list', '--json']:
            return [dict(id='saved-id', label='build', target='saved-alias', session='default', enabled=True)]
        self.assertEqual(args[:2], ['--machine', 'saved-id'])
        cmd = args[2:]
        if cmd == ['api', 'snapshot']:
            snap = self.snapshot()
            if self.bad_snapshot:
                snap['panes'] = [dict(self.panes[0], terminal_id='wrong_server')]
            return {'snapshot': snap}
        if cmd == ['workspace', 'list']:
            return {'workspaces': self.spaces[:]}
        if cmd[:2] == ['workspace', 'create']:
            w = {'workspace_id': 'w2', 'label': cmd[cmd.index('--label') + 1]}
            p = {'workspace_id': 'w2', 'pane_id': 'w2:p1', 'terminal_id': 'term_new'}
            self.spaces.append(w)
            self.panes.append(p)
            if self.failure == ('workspace', 'create'):
                raise ValueError('timed out; inspect, do not resend')
            return {'workspace': w, 'root_pane': None if self.malformed else p, 'already_open': False}
        if cmd[:2] == ['pane', 'get']:
            return {'pane': self.panes[-1]}
        if cmd[:2] == ['pane', 'process-info']:
            return {'process_info': {'pane_id': 'w2:p1', 'shell_pid': 1,
                    'foreground_processes': [{'pid': 2 if self.busy else 1, 'name': 'fish'}]}}
        if cmd[:2] in (['workspace', 'focus'], ['pane', 'run']):
            if self.failure == tuple(cmd[:2]):
                raise ValueError('timed out; inspect, do not resend')
            return {}
        self.fail_test(args)

    def fail_test(self, args):
        self.failure = None
        raise AssertionError(f'unexpected boundary call: {args}')

    def run_boundary(self, _owner, argv):
        if argv[0] == 'herdr':
            value = self.api(list(argv[1:]))
            if argv[1:3] != ['machine', 'list']:
                value = {'result': value}
            return json.dumps(value).encode()
        if argv[0] == 'rsync':
            self.assertEqual(argv[1], '-a')
            self.transfer_shell = argv[argv.index('-e') + 1]
            src = Path(argv[-2])
            dst = Path(argv[-1].split(':', 1)[1])
            self.copies.append((src.name, dst.relative_to(self.root).as_posix()))
            if self.failure == ('copy', src.name):
                raise ValueError('copy failed')
            if not (dst.exists() and dst.stat().st_size == src.stat().st_size and
                    int(dst.stat().st_mtime) == int(src.stat().st_mtime)):
                shutil.copy2(src, dst)
            return b''
        if argv[0] == 'ssh':
            self.assertIn('BatchMode=yes', argv)
            self.assertIn('StrictHostKeyChecking=yes', argv)
        else:
            self.assertEqual(argv[:2], ['tailscale', 'ssh'])
        self.assertEqual(argv[-2], f'{self.config["user"]}@fictional')
        script = shlex.split(argv[-1])
        self.assertEqual(script[:2], ['/bin/sh', '-c'])
        if 'api snapshot' in script[-1]:
            self.assertIn('--session default', script[-1])
            self.assertIn('unset HERDR_', script[-1])
            return json.dumps({'result': {'snapshot': self.snapshot()}}).encode()
        env = dict(os.environ, HOME=str(self.root.parent))
        return subprocess.check_output(script, env=env, stderr=subprocess.PIPE)

    def start(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.remote.open_remote('orchard-7', 'task.md', 'build', self.lane)
        return output.getvalue()

    def sends(self):
        return [c for c in self.calls if c[2:4] == ['pane', 'run']]

    def test_flat_start_replaces_four_snapshots_and_submits_named_argv_once(self):
        (self.root / 'AGENTS.md').write_text('old')
        text = self.start()
        self.assertEqual(self.copies, [('agents.md', 'AGENTS.md'), ('rules.md', 'lanes/COMMON-RULES.md'),
                                      ('task.md', 'lanes/task.md'), ('profile.md', 'review-profile/learnings.md')])
        self.assertEqual((self.root / 'AGENTS.md').read_text(), 'fresh agents.md')
        create = next(c for c in self.calls if c[2:4] == ['workspace', 'create'])
        self.assertIn('--no-focus', create)
        self.assertIn('DOTFILES_KEYRING_PROMPT=0', create)
        self.assertIn(str(self.root), create)
        self.assertEqual(len(self.sends()), 1)
        command = shlex.split(self.sends()[0][-1])
        self.assertEqual(command[:2], ['/bin/sh', '-c'])
        self.assertIn('--name orchard-7', command[-1])
        self.assertIn('Read ' + str(self.root / 'lanes/task.md'), command[-1])
        self.assertIn('flat', text)
        self.assertFalse(any('worktree' in c for c in self.calls))
        self.assertFalse((self.home / 'local/.lane-anchors').exists())

    def test_ssh_transport_and_rsync_wrapper_preserve_user_and_server_arguments(self):
        self.config['transport'] = 'ssh'
        self.write_config()
        self.start()
        binary = self.home / 'bin'
        binary.mkdir()
        stub = binary / 'ssh'
        stub.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        stub.chmod(0o700)
        result = subprocess.check_output([*shlex.split(self.transfer_shell), 'fictional',
                                          'rsync', '--server', 'a literal path'],
                                         env=dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH']))
        self.assertEqual(json.loads(result)[-4:], [self.user + '@fictional', 'rsync', '--server', 'a literal path'])

    @unittest.skipUnless(shutil.which('rsync'), 'rsync is not installed')
    def test_real_rsync_shell_handles_remote_paths_with_spaces_and_quotes(self):
        self.root = self.home / "remote's home/orchard-local"
        self.root.mkdir(parents=True)
        self.config['root'] = str(self.root)
        self.write_config()
        binary = self.home / 'rsync-bin'
        binary.mkdir()
        stub = binary / 'tailscale'
        stub.write_text('#!/usr/bin/python3\nimport subprocess,sys\n'
                        'assert sys.argv[1] == "ssh"\n'
                        'sys.exit(subprocess.run(["/bin/sh", "-c", " ".join(sys.argv[3:])]).returncode)\n')
        stub.chmod(0o700)
        original = self.run_boundary
        def real_copy(owner, argv):
            if argv[0] == 'rsync':
                return subprocess.check_output(argv, stderr=subprocess.PIPE,
                    env=dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH']))
            return original(owner, argv)
        with patch.object(self.remote.Remote, 'run', new=real_copy):
            self.start()
        self.assertEqual((self.root / 'AGENTS.md').read_text(), 'fresh agents.md')
        self.assertEqual(len(self.sends()), 1)

    def test_catalog_retarget_during_delivery_cannot_create_workspace(self):
        original = self.api
        def changed(args):
            value = original(args)
            if args[:2] == ['machine', 'list'] and self.copies:
                value[0]['target'] = 'other-host'
            return value
        with (patch.object(self, 'api', side_effect=changed),
              self.assertRaisesRegex(ValueError, 'binding changed')):
            self.start()
        self.assertFalse(any(c[2:4] == ['workspace', 'create'] for c in self.calls))

    def test_malformed_nested_inventory_is_normal_failure_before_mutation(self):
        with patch.object(self, 'panes', [None]), self.assertRaises(ValueError):
            self.start()
        self.assertEqual(self.copies, [])

    def test_existing_label_focus_does_not_replace_snapshots_or_send(self):
        self.spaces[0]['label'] = 'orchard-7'
        with self.assertRaisesRegex(ValueError, 'prompt not sent') as failure:
            self.start()
        self.assertNotIn('uncertain', str(failure.exception))
        self.assertEqual(self.copies, [])
        self.assertEqual(self.sends(), [])
        self.assertIn(['--machine', 'saved-id', 'workspace', 'focus', 'w1'], self.calls)

    def test_distinct_terminal_identity_blocks_wrong_endpoint_before_copy(self):
        self.bad_snapshot = True
        with self.assertRaisesRegex(ValueError, 'endpoint'):
            self.start()
        self.assertEqual(self.copies, [])
        self.assertFalse(any(c[2:4] == ['workspace', 'create'] for c in self.calls))

    def test_empty_inventory_cannot_bind(self):
        self.panes = []
        with self.assertRaisesRegex(ValueError, 'endpoint'):
            self.start()
        self.assertEqual(self.copies, [])

    def test_wrong_catalog_host_user_or_home_stops_before_delivery(self):
        for field in ('saved_target', 'user', 'hostname', 'root'):
            original = self.config[field]
            self.config[field] = '/outside/orchard-local' if field == 'root' else 'wrong'
            self.write_config()
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.start()
            self.assertEqual(self.copies, [])
            self.config[field] = original

    def test_symlink_source_is_refused_before_any_remote_call(self):
        source = self.local / 'profile-link.md'
        source.symlink_to(self.local / 'profile.md')
        self.config['profile'] = str(source)
        self.write_config()
        with self.assertRaisesRegex(ValueError, 'symlink.*source|source.*symlink'):
            self.start()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.copies, [])

    def test_cli_names_missing_host_binding_instead_of_bare_key(self):
        result = subprocess.run([sys.executable, str(SOURCE / 'lane.py'), '--host', 'missing',
                                 'orchard-7', 'task.md'], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn('binding missing', result.stderr)
        self.assertIn('lane-hosts.json', result.stderr)

    def test_symlink_destination_cannot_escape_delivery_root(self):
        outside = self.home / 'outside'
        outside.write_text('keep')
        (self.root / 'AGENTS.md').symlink_to(outside)
        with self.assertRaises(ValueError):
            self.start()
        self.assertEqual(outside.read_text(), 'keep')
        self.assertEqual(self.copies, [])

    def test_equal_size_mtime_mismatch_requires_explicit_source_repair(self):
        src = self.local / 'agents.md'
        dst = self.root / 'AGENTS.md'
        dst.write_bytes(b'X' * src.stat().st_size)
        os.utime(dst, ns=(src.stat().st_atime_ns, src.stat().st_mtime_ns))
        with self.assertRaisesRegex(ValueError, 'read-back.*AGENTS.md'):
            self.start()
        self.assertEqual(self.sends(), [])
        os.utime(src, ns=(src.stat().st_atime_ns, src.stat().st_mtime_ns + 2_000_000_000))
        self.start()
        self.assertEqual(dst.read_bytes(), src.read_bytes())

    def test_busy_or_malformed_created_pane_never_gets_input(self):
        self.busy = True
        with self.assertRaisesRegex(ValueError, 'uncertain.*w2|w2.*uncertain'):
            self.start()
        self.assertEqual(self.sends(), [])
        self.busy = False
        self.spaces = self.spaces[:1]
        self.panes = self.panes[:1]
        self.malformed = True
        with self.assertRaisesRegex(ValueError, 'w2'):
            self.start()
        self.assertEqual(self.sends(), [])

    def test_timeout_after_creation_or_run_never_replays(self):
        for operation in (('workspace', 'create'), ('pane', 'run')):
            self.failure = operation
            with self.subTest(operation=operation), self.assertRaisesRegex(ValueError, 'uncertain'):
                self.start()
            self.assertEqual(sum(c[2:4] == ['workspace', 'create'] for c in self.calls), 1)
            self.failure = None
            with self.assertRaisesRegex(ValueError, 'prompt not sent'):
                self.start()
            self.assertLessEqual(len(self.sends()), 1)
            self.spaces = self.spaces[:1]
            self.panes = self.panes[:1]
            self.calls.clear()

    def test_actual_created_terminal_mismatch_never_gets_input(self):
        original = self.api
        def changed(args):
            value = original(args)
            if args[2:4] == ['pane', 'get']:
                value = {'pane': dict(value['pane'], terminal_id='other-terminal')}
            return value
        with (patch.object(self, 'api', side_effect=changed),
              self.assertRaisesRegex(ValueError, 'identity changed')):
            self.start()
        self.assertEqual(self.sends(), [])

    def test_source_change_after_copy_blocks_start(self):
        original = self.run_boundary
        def changed(owner, argv):
            value = original(owner, argv)
            if argv[0] == 'rsync':
                (self.local / 'profile.md').write_text('changed profile')
            return value
        with patch.object(self.remote.Remote, 'run', new=changed):
            with self.assertRaisesRegex(ValueError, 'source inputs changed|read-back'):
                self.start()
        self.assertEqual(self.sends(), [])

    def test_partial_transfer_does_not_create_workspace(self):
        self.failure = ('copy', 'rules.md')
        with self.assertRaisesRegex(ValueError, 'copy failed'):
            self.start()
        self.assertEqual((self.root / 'AGENTS.md').read_text(), 'fresh agents.md')
        self.assertFalse(any(c[2:4] == ['workspace', 'create'] for c in self.calls))

    def test_absolute_profile_and_prompt_relative_to_project_not_cwd(self):
        self.config['profile'] = str(self.local / 'profile.md')
        self.write_config()
        self.start()
        self.assertEqual((self.root / 'review-profile/learnings.md').read_text(), 'fresh profile.md')

    def test_control_characters_in_interpolated_paths_fail_before_api(self):
        self.config['pi'] += '\u0085'
        self.write_config()
        with self.assertRaises(ValueError):
            self.start()
        self.assertEqual(self.calls, [])

    def test_cli_remote_import_and_missing_prompt_are_normal_errors(self):
        result = subprocess.run([sys.executable, str(SOURCE / 'lane.py'), '--host', 'missing',
                                 'orchard-7', 'task.md'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('Traceback', result.stderr)
        missing = subprocess.run([sys.executable, str(SOURCE / 'lane.py'), '--host', 'build',
                                  'orchard-7'], capture_output=True, text=True)
        self.assertEqual(missing.returncode, 2)

    def test_unsafe_binding_and_non_numbered_aliases_rejected(self):
        for label in ('orchard-coord', 'orchard-', 'orchard-7;false', 'orchard-7' * 8):
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.remote.open_remote(label, 'task.md', 'build', self.lane)
        self.config['root'] += '\\escape'
        self.write_config()
        with self.assertRaises(ValueError):
            self.start()
        self.assertEqual(self.copies, [])


class TransportTests(unittest.TestCase):
    def test_outer_timeout_is_ten_seconds_and_reaps_owned_process_group(self):
        remote = load('remote')
        target = object.__new__(remote.Remote)
        target.stage = 'fictional mutation'
        original = subprocess.Popen.communicate
        timeouts = []
        def short(child, *args, timeout=None, **kwargs):
            timeouts.append(timeout)
            return original(child, *args, timeout=.03 if timeout is not None else None, **kwargs)
        with patch.object(subprocess.Popen, 'communicate', short):
            with self.assertRaisesRegex(ValueError, 'timed out.*10'):
                target.run([sys.executable, '-c', 'import time; time.sleep(60)'])
        self.assertEqual(timeouts, [10, None])


if __name__ == '__main__':
    unittest.main()
