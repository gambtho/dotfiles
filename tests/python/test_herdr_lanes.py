"""Fictional boundary tests for the installed project-heading tools."""
import fcntl
import importlib.util
import itertools
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier, BrokenBarrierError, Thread
from unittest.mock import patch

import tomllib

SOURCE = Path(__file__).resolve().parents[2] / 'tools/herdr/lanes'


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SOURCE / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ToolFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {'HOME': str(self.home)}).start()
        self.lane = load('lane', 'lane.py')
        self.spaces = []
        self.calls = []
        self.busy = False
        self.adopt = False
        patch.object(self.lane, 'herdr', side_effect=self.api).start()
        patch.object(self.lane.time, 'sleep').start()
        for project in ('orchard', 'double', 'double-holo'):
            (self.home / f'{project}-local').mkdir()

    def space(self, label, checkout=None):
        wid = f'w{len(self.spaces) + 1}'
        w = {'workspace_id': wid, 'label': label, 'pane_count': 1, 'worktree': None}
        if checkout:
            w['worktree'] = {'checkout_path': str(checkout), 'repo_key': 'orchard-key',
                             'is_linked_worktree': True}
        self.spaces.append(w)
        return w

    def api(self, *args):
        self.calls.append(args)
        if args == ('workspace', 'list'):
            return {'workspaces': list(self.spaces)}
        if args[:2] in (('workspace', 'create'), ('worktree', 'open')):
            w: dict
            if args[:2] == ('worktree', 'open') and '--label' not in args:
                w = self.spaces[0] if self.adopt else self.spaces[-1]
                w = {**w, 'worktree': {'checkout_path': args[args.index('--path') + 1],
                                      'is_linked_worktree': True, 'repo_key': 'orchard-key'}}
            else:
                label = args[args.index('--label') + 1]
                w = self.space(label)
            result = {'workspace': w, 'root_pane': {'pane_id': w['workspace_id'] + ':p1',
                      'workspace_id': w['workspace_id'], 'terminal_id': 'term-example'}}
            if args[:2] == ('worktree', 'open'):
                result['already_open'] = True if '--label' not in args else self.adopt
            return result
        if args[:2] == ('pane', 'process-info'):
            return {'process_info': {'pane_id': args[-1], 'shell_pid': 100,
                    'foreground_process_group_id': 100,
                    'foreground_processes': [{'pid': 101 if self.busy else 100,
                                              'name': 'python3' if self.busy else 'zsh'}]}}
        if args[:2] in (('pane', 'run'), ('workspace', 'focus')):
            return {}
        raise AssertionError(f'unexpected call: {args}')

    def sends(self):
        return [c for c in self.calls if c[:2] == ('pane', 'run')]


class LaneTests(ToolFixture):
    def test_unborn_anchor_is_completed_before_worktree_creation(self):
        anchor = self.home / '.lane-anchors/orchard'
        anchor.mkdir(parents=True)
        subprocess.run(['git', '-C', str(anchor), 'init', '-q', '-b', 'main'], check=True)
        checkout = self.home / '.lane-anchors/orchard-lanes/7'
        self.lane.anchor_checkout(anchor, checkout)
        self.assertTrue((checkout / '.git').is_file())
        self.assertEqual(subprocess.run(['git', '-C', str(anchor), 'rev-parse', '--verify', 'HEAD'],
                                       capture_output=True, check=False).returncode, 0)

    def test_concurrent_first_lanes_create_only_one_heading(self):
        barrier, counter = Barrier(2), itertools.count()
        original = self.api
        def api(*args):
            if args == ('workspace', 'list') and next(counter) < 2:
                result = original(*args)
                # Force competing unlocked readers to see the same snapshot.
                # A serialized reader proceeds when no competitor can enter.
                try:
                    barrier.wait(timeout=1)
                except BrokenBarrierError:
                    pass
                return result
            return original(*args)
        with patch.object(self.lane, 'herdr', side_effect=api), ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(self.lane.open_lane, label, '') for label in ('orchard-7', 'orchard-8')]
            for future in futures:
                future.result()
        self.assertEqual(sum(w['label'] == '◆ orchard' for w in self.spaces), 1)
        self.assertEqual(len([c for c in self.calls if c[:2] == ('pane', 'run')]), 3)

    def test_longest_project_and_shorthand(self):
        self.assertEqual(self.lane.resolve('double-holo-12', self.home / 'double-holo-local'),
                         ('double-holo', '12'))
        self.assertEqual(self.lane.resolve('coord', self.home / 'double-holo-local'),
                         ('double-holo', 'coord'))
        self.assertEqual(self.lane.resolve('double-holo', self.home), ('double-holo', ''))
        for label in ('orchard-', 'missing-1', 'orchard-../escape', 'orchard-other'):
            with self.subTest(label=label), self.assertRaises(ValueError):
                self.lane.resolve(label, self.home)

    def test_new_lane_groups_and_quotes_prompt_once(self):
        prompt = "Read 'a file'; $(touch never)\nand follow it."
        self.lane.open_lane('double-holo-12', prompt)
        opening = next(c for c in self.calls if c[:2] == ('worktree', 'open'))
        self.assertIn('--focus', opening)
        self.assertEqual(opening[opening.index('--cwd') + 1], str(self.home / '.lane-anchors/double-holo'))
        self.assertEqual(len(self.sends()), 2)  # heading publisher and one lane command
        command = shlex.split(self.sends()[-1][-1])
        self.assertEqual(command, ['cd', str(self.home / 'double-holo-local'),
                                   '&&', 'pi', '--name', 'double-holo-12', '--', prompt])
        self.assertTrue((self.home / '.lane-anchors/double-holo-lanes/12/.git').is_file())

    def test_lane_opt_out_is_set_before_its_shell_starts_and_group_attachment(self):
        self.space('◆ orchard')
        self.lane.open_lane('orchard-7', '')
        create = next(c for c in self.calls if c[:2] == ('workspace', 'create'))
        opened = next(c for c in self.calls if c[:2] == ('worktree', 'open'))
        self.assertIn('DOTFILES_KEYRING_PROMPT=0', create)
        self.assertIn('--no-focus', create)
        self.assertIn(str(self.home / '.lane-anchors/orchard-lanes/7'), create)
        self.assertLess(self.calls.index(create), self.calls.index(opened))
        self.assertNotIn('--label', opened)  # adoption must never rename another workspace
        self.assertEqual(shlex.split(self.sends()[-1][-1]), ['cd', str(self.home / 'orchard-local')])

    def test_terminal_controls_rejected_without_input_or_creation(self):
        for prompt in ('before\x03after', 'before\x15touch never', 'before\tafter', 'before\x1bafter'):
            with self.subTest(prompt=repr(prompt)), self.assertRaisesRegex(ValueError, 'control'):
                self.lane.open_lane('orchard-7', prompt)
        self.assertEqual(self.calls, [])

    def test_heading_startup_failure_names_publisher_and_returned_pane(self):
        self.busy = True
        with self.assertRaisesRegex(ValueError, 'w1:p1.*needs.py'):
            self.lane.open_lane('orchard-7', '')
        self.assertEqual(self.sends(), [])
        self.assertFalse(any(c[:2] == ('worktree', 'open') for c in self.calls))

    def test_group_attachment_failure_names_owned_pane_without_resending(self):
        self.space('◆ orchard')
        original = self.api
        def fail(*args):
            if args[:2] == ('worktree', 'open'):
                raise ValueError('API unavailable')
            return original(*args)
        with (patch.object(self.lane, 'herdr', side_effect=fail),
              self.assertRaisesRegex(ValueError, 'w2:p1.*do not resend')):
            self.lane.open_lane('orchard-7', 'Never submit this')
        self.assertEqual(self.sends(), [])

    def test_heading_only_preserves_focus_and_sets_pre_shell_opt_out(self):
        self.lane.open_lane('orchard', '')
        create = next(c for c in self.calls if c[:2] == ('workspace', 'create'))
        self.assertIn('--no-focus', create)
        self.assertIn('DOTFILES_KEYRING_PROMPT=0', create)
        self.assertFalse(any(c[:2] == ('workspace', 'focus') for c in self.calls))
        self.assertEqual(len(self.sends()), 1)

    def test_existing_flat_label_gets_focused_without_worktree_or_input(self):
        existing = self.space('orchard-7')
        with self.assertRaisesRegex(ValueError, 'prompt not sent'):
            self.lane.open_lane('orchard-7', 'Never submit this')
        self.assertIn(('workspace', 'focus', existing['workspace_id']), self.calls)
        self.assertEqual(self.sends(), [])
        self.assertFalse((self.home / '.lane-anchors/orchard').exists())
        self.assertFalse(any(c[:2] == ('worktree', 'open') for c in self.calls))

    def test_existing_checkout_other_label_not_renamed_or_typed_into(self):
        checkout = self.home / '.lane-anchors/orchard-lanes/7'
        w = self.space('different-label', checkout)
        self.lane.open_lane('orchard-7', '')
        self.assertIn(('workspace', 'focus', w['workspace_id']), self.calls)
        self.assertEqual(self.sends(), [])
        self.assertFalse(any(c[:2] == ('worktree', 'open') for c in self.calls))

    def test_duplicate_labels_refuse_without_input(self):
        self.space('orchard-7')
        self.space('orchard-7')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.lane.open_lane('orchard-7', '')
        self.assertEqual(self.sends(), [])

    def test_adopted_response_never_gets_input(self):
        self.space('◆ orchard')
        self.adopt = True
        with self.assertRaisesRegex(ValueError, 'identity|adopt'):
            self.lane.open_lane('orchard-7', 'Never submit this')
        self.assertEqual(self.sends(), [])

    def test_busy_foreground_never_gets_input(self):
        self.space('◆ orchard')
        self.busy = True
        with self.assertRaisesRegex(ValueError, 'shell|foreground'):
            self.lane.open_lane('orchard-7', 'Never submit this')
        self.assertEqual(self.sends(), [])


MUTATING = (('workspace', 'create'), ('worktree', 'open'), ('pane', 'run'))


class CoordinatorTests(ToolFixture):
    def setUp(self):
        super().setUp()
        for key in [k for k in os.environ if k.startswith('HERDR_')]:
            del os.environ[key]  # the HOME patch restores the original environment
        self.path = str(self.home / 'h.sock')
        self.bind(self.path)
        self.rows = [{'name': 'default', 'default': True, 'running': True, 'socket_path': self.path}]
        self.tweak = self.hook = lambda *args: None
        self.pins, self.moves, self.free, self.rawn, self.focus = [], [], [], 0, 'w1'
        self.move_error = self.move_noop = self.move_focus = self.attach_key = None
        anchors = self.home / '.lane-anchors'
        self.space('sentinel')
        self.space('◆ orchard')
        self.spaces[1]['worktree'] = {'repo_key': 'orchard-key', 'is_linked_worktree': False,
                                      'checkout_path': str(anchors / 'orchard')}
        self.space('orchard-30', anchors / 'orchard-lanes/30')
        self.space('other-8', anchors / 'other-lanes/8')['worktree']['repo_key'] = 'other-key'
        patch.object(self.lane, 'herdr', side_effect=self.cli).start()
        patch.object(self.lane, 'raw', side_effect=self.raw, create=True).start()
        patch.object(self.lane, 'catalog', side_effect=self.catalog, create=True).start()

    def bind(self, path):
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        self.addCleanup(server.close)

    def inside(self):
        os.environ.update(HERDR_ENV='1', HERDR_PANE_ID='w1:p1', HERDR_WORKSPACE_ID='w1',
                          HERDR_SOCKET_PATH=self.path)

    def catalog(self):
        self.calls.append(('catalog',))
        return self.rows

    def snapshot(self, source):
        snap = {'protocol': 22, 'version': '0.9.5', 'focused_workspace_id': self.focus,
                'focused_pane_id': self.focus + ':p1', 'workspaces': [dict(w) for w in self.spaces],
                'panes': [{'pane_id': w['workspace_id'] + ':p1', 'workspace_id': w['workspace_id'],
                           'terminal_id': 'term-example'} for w in self.spaces]}
        self.tweak(source, snap)
        return snap

    def cli(self, *args):
        pin = args[1] if args[:1] == ('--session',) else getattr(self.lane, 'PIN', None)
        args = args[2:] if args[:1] == ('--session',) else args
        self.pins.append((args[:2], pin))
        if args == ('api', 'snapshot'):
            return {'snapshot': self.snapshot('pinned' if pin else 'ambient')}
        self.hook(' '.join(args[:2]), self.rawn)
        result = self.api(*args)
        if args[:2] == ('pane', 'run'):
            with (self.home / '.lane-anchors/.orchard.lock').open('a') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return self.free.append(False) or result
                self.free.append(True)
        if args[:2] == ('workspace', 'create') and result['workspace']['label'].startswith('◆'):
            result['workspace']['worktree'] = self.spaces[1]['worktree']
        if args[:2] == ('worktree', 'open'):
            if self.attach_key:
                result['workspace']['worktree']['repo_key'] = self.attach_key
            self.spaces[-1], self.focus = result['workspace'], result['workspace']['workspace_id']
        return result

    def raw(self, path, method, params, expected):
        self.rawn += 1
        self.calls.append(('raw', method))
        self.hook(method, self.rawn)
        self.assertEqual(path, self.path)
        if method != 'workspace.move_block':
            return {'type': 'session_snapshot', 'snapshot': self.snapshot('raw')}
        self.moves.append(params)
        if self.move_error:
            raise self.move_error
        if not self.move_noop:
            moving = next(w for w in self.spaces if w['workspace_id'] == params['workspace_ids'][0])
            self.spaces.remove(moving)
            before = next(i for i, w in enumerate(self.spaces) if w['workspace_id'] == params['before_workspace_id'])
            self.spaces.insert(before, moving)
        self.focus = 'w2' if self.move_focus else self.focus
        return {'type': 'workspace_list', 'workspaces': [{'workspace_id': w['workspace_id']} for w in self.spaces]}

    def refuse(self, anchored=False):
        with self.assertRaises(ValueError):
            self.lane.open_lane('orchard-coord', 'Task')
        self.assertEqual([c for c in self.calls if c[:2] in MUTATING], [])
        self.assertEqual(anchored, (self.home / '.lane-anchors/orchard-lanes/coord').exists())
        self.assertIsNone(self.lane.PIN)

    def stops(self, **faults):
        self.inside()
        vars(self).update(faults)
        with self.assertRaisesRegex(ValueError, 'uncertain'):
            self.lane.open_lane('orchard-coord', 'Task')
        self.assertEqual(self.sends(), [])
        self.assertLessEqual(len(self.moves), 1)  # never retried
        self.assertIsNone(self.lane.PIN)

    def test_new_coordinator_moves_first_before_typed_startup_with_pinned_session(self):
        self.inside()
        self.lane.open_lane('orchard-coord', 'Task')
        self.assertEqual(self.moves, [{'workspace_ids': ['w5'], 'before_workspace_id': 'w3'}])
        self.assertEqual([w['workspace_id'] for w in self.spaces], ['w1', 'w2', 'w5', 'w3', 'w4'])
        self.assertLess(self.calls.index(('raw', 'workspace.move_block')), self.calls.index(self.sends()[0]))
        self.assertEqual((self.free, self.focus), ([True], 'w5'))  # lock released; focus kept
        self.assertEqual({p for c, p in self.pins if c in MUTATING}, {'default'})
        self.assertEqual(shlex.split(self.sends()[0][-1]), ['cd', str(self.home / 'orchard-local'),
                                                         '&&', 'pi', '--name', 'orchard-coord', '--', 'Task'])
        self.assertIsNone(self.lane.PIN)

    def test_no_sibling_is_not_moved_and_outside_herdr_uses_default(self):
        self.spaces[2]['worktree']['repo_key'] = 'elsewhere'
        self.lane.open_lane('orchard-coord', 'Task')
        self.assertEqual((self.moves, len(self.sends())), ([], 1))

    def test_named_session_is_selected_over_default(self):
        self.inside()
        self.rows = [{**self.rows[0], 'default': False, 'name': 'work'}, {**self.rows[0], 'socket_path': '/elsewhere'}]
        os.environ['HERDR_SESSION'] = 'work'
        self.lane.open_lane('orchard-coord', 'Task')
        self.assertEqual({p for c, p in self.pins if c in MUTATING}, {'work'})

    def test_existing_coordinator_is_focus_only_without_context(self):
        self.space('orchard-coord')
        with self.assertRaisesRegex(ValueError, 'prompt not sent'):
            self.lane.open_lane('orchard-coord', 'Task')
        self.assertEqual([c for c in self.calls if c[0] in ('catalog', 'raw')], [])

    def test_context_mismatches_refuse_before_git_or_workspace_mutation(self):
        good = self.rows[0]
        cases = {'empty session': ({'HERDR_SESSION': ''}, [good]), 'unknown session': ({'HERDR_SESSION': 'x'}, [good]),
                 'stopped': ({}, [{**good, 'running': False}]), 'string running': ({}, [{**good, 'running': 'true'}]),
                 'two defaults': ({}, [good, {**good, 'name': 'b'}]), 'no default': ({}, [{**good, 'default': False}]),
                 'socket differs': ({'HERDR_SOCKET_PATH': '/other.sock'}, [good]),
                 'socket empty': ({'HERDR_SOCKET_PATH': ''}, [good]), 'relative': ({}, [{**good, 'socket_path': 'h.sock'}]),
                 'not a socket': ({}, [{**good, 'socket_path': str(self.home)}])}
        for name, (env, rows) in cases.items():
            with self.subTest(name), patch.dict(os.environ, env):
                self.rows = rows
                self.refuse()

    def test_snapshot_disagreement_and_profile_refuse_before_mutation(self):
        def edit(source, change):
            return lambda src, snap: change(snap) if src == source else None
        cases = {'raw caller terminal': edit('raw', lambda s: s['panes'][0].update(terminal_id='x')),
                 'pinned heading terminal': edit('pinned', lambda s: s['panes'][1].update(terminal_id='x')),
                 'ambient heading pane': edit('ambient', lambda s: s['panes'].pop(1)),
                 'caller absent': lambda src, s: s['panes'].pop(0)}
        for source in ('raw', 'ambient'):
            for bad in (True, 19.0, 22.0, '22', 20):
                cases[f'{source} protocol {bad!r}'] = edit(source, lambda s, bad=bad: s.update(protocol=bad))
            cases[f'{source} version'] = edit(source, lambda s: s.update(version='0.9.4'))
        for name, tweak in cases.items():
            with self.subTest(name):
                self.inside()
                self.tweak = tweak
                self.refuse()

    def test_socket_replacement_before_move_stops_before_startup(self):
        def replace(method, n):
            if (method, n) == ('session.snapshot', 2):
                self.bind(self.path + '2')
                os.replace(self.path + '2', self.path)
        self.stops(hook=replace)
        self.assertEqual(self.moves, [])

    def test_terminal_or_group_disagreement_before_move_stops(self):
        def terminal(src, snap):
            if src == 'raw':
                snap['panes'][-1]['terminal_id'] = 'replacement'
        def group(src, snap):
            snap['workspaces'][-1]['worktree'] = {**snap['workspaces'][-1]['worktree'], 'repo_key': 'x'}
        for fault in (dict(tweak=terminal), dict(tweak=group), dict(attach_key='bogus')):
            with self.subTest(fault):
                self.setUp()
                self.stops(**fault)
                self.assertEqual(self.moves, [])

    def test_move_failure_or_readback_disagreement_stops_without_retry(self):
        for fault in (dict(move_error=OSError('timed out')), dict(move_noop=True), dict(move_focus=True),
                      dict(hook=lambda m, n: setattr(self, 'tweak', lambda _, s: s['panes'][2].update(terminal_id='new')) if m == 'pane process-info' else None)):
            with self.subTest(fault):
                self.setUp()
                self.stops(**fault)
                self.assertEqual(len(self.moves), 1)


class RawSocketTests(unittest.TestCase):
    def setUp(self):
        self.lane, self.requests = load('lane', 'lane.py'), []
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def serve(self, name, reply):
        path = str(Path(self.dir.name, name))
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(1)
        self.addCleanup(server.close)
        def run():
            conn, _ = server.accept()
            with conn:
                request = json.loads(conn.makefile().readline())
                self.requests.append(request)
                data = reply(request)
                try:
                    conn.sendall(data) if data is not None else conn.recv(1)
                except OSError:
                    pass
        Thread(target=run, daemon=True).start()
        return path

    def test_framing_identity_type_and_bounds_fail_without_retry(self):
        def answer(request, **changes):
            return json.dumps({'id': request['id'], 'result': {'type': 't'}, **changes}).encode() + b'\n'
        self.assertEqual(self.lane.raw(self.serve('ok', answer), 'm', {'a': 1}, 't'), {'type': 't'})
        self.assertEqual((self.requests[0]['method'], self.requests[0]['params']), ('m', {'a': 1}))
        replies = {'id': lambda r: answer(r, id='other'), 'type': lambda r: answer(r, result={'type': 'u'}),
                   'error': lambda r: answer(r, result=None, error='no'), 'array': lambda r: b'[]\n',
                   'malformed': lambda r: b'{nope\n', 'eof': lambda r: b'{}', 'oversize': lambda r: b'x' * ((1 << 22) + 1),
                   'silent': lambda r: None}
        for name, reply in replies.items():
            with self.subTest(name), patch.object(self.lane, 'RAW_SECONDS', 0.3):
                with self.assertRaises((ValueError, OSError)):
                    self.lane.raw(self.serve(name, reply), 'm', {}, 't')
        self.assertEqual(len(self.requests), 1 + len(replies))

    def test_expired_deadline_rejects_ready_read(self):
        with (patch.object(self.lane.socket, 'socket') as made,
              patch.object(self.lane.time, 'monotonic', side_effect=[0, 0, 0, 11])):
            made.return_value.__enter__.return_value.recv.return_value = b'{}\n'
            with self.assertRaisesRegex(TimeoutError, 'deadline'):
                self.lane.raw('/fictional', 'm', {}, 't')


class DashboardTests(ToolFixture):
    def setUp(self):
        super().setUp()
        with patch.dict(sys.modules, {'lane': self.lane}):
            self.dashboard = load('dashboard_open', 'dashboard-open.py')
        self.installed = self.home / '.local/share/dotfiles/herdr-dashboard'
        self.installed.mkdir(parents=True)
        (self.installed / 'dashboard.py').touch()

    def test_dashboard_creates_primary_pane_with_installed_cwd(self):
        self.dashboard.open_dashboard()
        create = next(c for c in self.calls if c[:2] == ('workspace', 'create'))
        self.assertIn(str(self.installed), create)
        self.assertIn('DOTFILES_KEYRING_PROMPT=0', create)
        self.assertEqual(self.sends(), [('pane', 'run', 'w1:p1', './dashboard.py')])

    def test_empty_data_home_uses_default_installed_dashboard(self):
        with patch.dict(os.environ, {'XDG_DATA_HOME': ''}):
            self.dashboard.open_dashboard()
        self.assertEqual(self.sends(), [('pane', 'run', 'w1:p1', './dashboard.py')])

    def test_dashboard_existing_focus_sends_nothing_even_without_install(self):
        w = self.space('Projects')
        (self.installed / 'dashboard.py').unlink()
        self.dashboard.open_dashboard()
        self.assertIn(('workspace', 'focus', w['workspace_id']), self.calls)
        self.assertEqual(self.sends(), [])

    def test_dashboard_duplicates_and_missing_install_send_nothing(self):
        (self.installed / 'dashboard.py').unlink()
        with self.assertRaisesRegex(ValueError, 'make herdr-dashboard'):
            self.dashboard.open_dashboard()
        self.space('Projects')
        self.space('Projects')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.dashboard.open_dashboard()
        self.assertEqual(self.sends(), [])


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.needs = load('needs', 'needs.py')
        self.spaces: list[dict] = [
            {'workspace_id': 'w1', 'label': '◆ double-holo', 'agent_status': 'unknown',
             'worktree': {'repo_key': 'repo', 'is_linked_worktree': False}},
            {'workspace_id': 'w2', 'label': 'double-holo-7', 'agent_status': 'blocked',
             'tokens': {'task': 'Fictional decision'},
             'worktree': {'repo_key': 'repo', 'is_linked_worktree': True}},
            {'workspace_id': 'w3', 'label': 'double-holo-8', 'agent_status': 'idle',
             'tokens': {}, 'worktree': None},
        ]

    def test_grouped_count_transitions_exclude_ungrouped_needs(self):
        with patch.object(self.needs.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            last = {}
            self.needs.publish(self.spaces, last)
            self.assertIn('needs=1', run.call_args.args[0])
            self.spaces[1]['agent_status'] = 'idle'
            self.spaces[2]['tokens']['phase'] = 'needs-decision'
            self.needs.publish(self.spaces, last)
            self.assertIn('needs=0', run.call_args.args[0])
            self.spaces[1]['tokens']['phase'] = 'needs-decision'
            self.needs.publish(self.spaces, last)
            self.assertIn('needs=1', run.call_args.args[0])

    def test_published_counts_expire_if_the_reporter_stops(self):
        with patch.object(self.needs.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.needs.publish(self.spaces, {})
            args = run.call_args.args[0]
            self.assertIn('--ttl-ms', args)
            self.assertEqual(args[args.index('--ttl-ms') + 1], '180000')

    def test_missing_provenance_publishes_zero_and_marks_ungrouped(self):
        self.spaces[0]['worktree'] = None
        self.spaces[1]['worktree'] = None
        with patch.object(self.needs.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            self.needs.publish(self.spaces, {})
            self.assertIn('needs=0', run.call_args.args[0])
        with patch.object(self.needs, 'project_for_label', return_value='double-holo'):
            self.assertIn('(not grouped)', '\n'.join(self.needs.draw(self.spaces, 'w1')))

    def test_longer_folder_owns_summary_rows(self):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {'HOME': home}):
            Path(home, 'double-holo-local').mkdir()
            self.assertIn('Fictional decision', '\n'.join(self.needs.draw(self.spaces, 'w1')))
            Path(home, 'double-holo-7-local').mkdir()
            self.assertNotIn('Fictional decision', '\n'.join(self.needs.draw(self.spaces, 'w1')))

    def test_failed_publication_is_not_cached_as_success(self):
        last = {}
        with (patch.object(self.needs.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'herdr')),
              self.assertRaises(subprocess.CalledProcessError)):
            self.needs.publish(self.spaces, last)
        self.assertNotIn('w1', last)


class TransportTests(unittest.TestCase):
    def test_cli_failure_keeps_diagnostic_without_echoing_prompt(self):
        lane = load('lane', 'lane.py')
        error = subprocess.CalledProcessError(1, ['herdr', 'pane', 'run', 'w1:p1', 'PRIVATE PROMPT'],
                                              stderr='pane is not available')
        with patch.object(lane.subprocess, 'run', side_effect=error):
            with self.assertRaisesRegex(ValueError, 'pane is not available') as failure:
                lane.herdr('pane', 'run', 'w1:p1', 'PRIVATE PROMPT')
            self.assertNotIn('PRIVATE PROMPT', str(failure.exception))

    def test_malformed_nested_api_value_fails_without_traceback(self):
        lane = load('lane', 'lane.py')
        with (tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {'HOME': home}),
              patch.object(sys, 'argv', ['lane', 'orchard-7']),
              patch.object(lane, 'herdr', return_value={'workspaces': [
                  {'workspace_id': 'w1', 'label': 'other', 'worktree': 'bad'}]})):
            Path(home, 'orchard-local').mkdir()
            self.assertEqual(lane.main(), 1)

    def test_pinned_session_prefix_and_catalog_command(self):
        lane = load('lane', 'lane.py')
        done = subprocess.CompletedProcess([], 0, stdout='{"result": {}, "sessions": []}')
        with patch.object(lane.subprocess, 'run', return_value=done) as run:
            lane.PIN = 'work'
            lane.herdr('workspace', 'list')
            self.assertEqual(run.call_args.args[0], ['herdr', '--session', 'work', 'workspace', 'list'])
            lane.PIN = None
            self.assertEqual(lane.catalog(), [])
            self.assertEqual(run.call_args.args[0], ['herdr', 'session', 'list', '--json'])

    def test_pane_run_and_focus_can_acknowledge_without_stdout(self):
        lane = load('lane', 'lane.py')
        with patch.object(lane.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')):
            self.assertEqual(lane.herdr('pane', 'run', 'w1:p1', 'true'), {})
            self.assertEqual(lane.herdr('workspace', 'focus', 'w1'), {})
            with self.assertRaises(ValueError):
                lane.herdr('workspace', 'create', '--label', 'orchard-7')


class BindingTests(unittest.TestCase):
    def test_installed_popup_passes_label_and_prompt_without_evaluation(self):
        config = tomllib.loads((SOURCE.parent / 'config.toml.template').read_text())
        command = next(c['command'] for c in config['keys']['command'] if c['key'] == 'prefix+shift+l')
        with tempfile.TemporaryDirectory() as home:
            lane = Path(home, '.local/bin/lane')
            lane.parent.mkdir(parents=True)
            lane.write_text('#!/bin/sh\nprintf "<%s>\\n" "$@"\n')
            lane.chmod(0o700)
            result = subprocess.run(['/bin/sh', '-c', command], input="orchard-7\nRead 'a file'; $(false)\n",
                                    text=True, capture_output=True, env={**os.environ, 'HOME': home}, check=True)
            self.assertIn("<orchard-7>\n<Read 'a file'; $(false)>", result.stdout)

    def test_popup_passes_dash_prefixed_prompt_to_real_argument_parser(self):
        config = tomllib.loads((SOURCE.parent / 'config.toml.template').read_text())
        command = next(c['command'] for c in config['keys']['command'] if c['key'] == 'prefix+shift+l')
        with tempfile.TemporaryDirectory() as home:
            executable = Path(home, '.local/bin/lane')
            executable.parent.mkdir(parents=True)
            executable.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["HOME"],"args.json").write_text(json.dumps(sys.argv[1:]))\n')
            executable.chmod(0o700)
            subprocess.run(['/bin/sh', '-c', command], input='orchard-7\n-review\n', text=True,
                           capture_output=True, env={**os.environ, 'HOME': home}, check=True)
            args = json.loads(Path(home, 'args.json').read_text())
            lane = load('lane', 'lane.py')
            with patch.object(sys, 'argv', ['lane', *args]), patch.object(lane, 'open_lane') as opened:
                self.assertEqual(lane.main(), 0)
                opened.assert_called_once_with('orchard-7', '-review')

    def test_dashboard_binding_runs_installed_opener_from_data_home(self):
        config = tomllib.loads((SOURCE.parent / 'config.toml.template').read_text())
        command = next(c['command'] for c in config['keys']['command'] if c['key'] == 'prefix+shift+o')
        with tempfile.TemporaryDirectory() as home:
            data = Path(home, 'data with spaces')
            opener = data / 'dotfiles/herdr-lanes/dashboard-open.py'
            opener.parent.mkdir(parents=True)
            opener.write_text('print("installed opener ran")\n')
            result = subprocess.run(['/bin/sh', '-c', command], text=True, capture_output=True,
                                    env={**os.environ, 'HOME': home, 'XDG_DATA_HOME': str(data)}, check=True)
            self.assertEqual(result.stdout.strip(), 'installed opener ran')


if __name__ == '__main__':
    unittest.main()
