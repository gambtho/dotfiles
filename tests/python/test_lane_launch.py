"""Launch boundary tests: all Herdr traffic goes to a fixture executable."""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'ai/marketplace/plugins/my/skills/lane-coordinator/scripts/launch.py'


class NameTests(unittest.TestCase):
    def test_short_names_and_overrides(self):
        self.assertTrue(SCRIPT.is_file(), 'the deterministic launch helper is missing')
        spec = importlib.util.spec_from_file_location('lane_launch', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for project, lane, override, expected in [
            ('double-holo', 'W12', None, 'double-holo-12'),
            ('my-project', 'W3', 'custom_lane', 'custom_lane'),
        ]:
            self.assertEqual(module.lane_name(project, lane, override), expected)
        for project, lane, override in [
            ('a' * 31, 'W12', None), ('Project', 'W12', None),
            ('project', 'W0', None), ('project', '12', None),
            ('project', 'W12', 'x;touch bad'), ('project', 'W12', ''),
        ]:
            with self.subTest(project=project, lane=lane, override=override), self.assertRaises(ValueError):
                module.lane_name(project, lane, override)


FAKE = r'''#!/usr/bin/env python3
import json, os, signal, sys
from pathlib import Path
root = Path(os.environ['FAKE_ROOT'])
s = json.loads((root / 'live.json').read_text())
a = sys.argv[1:]
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps(a) + '\n')
mode = os.environ.get('FAKE_MODE', '')
def save():
    (root / 'live.json').write_text(json.dumps(s))
def reply(kind, **data):
    print(json.dumps({'id': 'fixture', 'result': {'type': kind, **data}}))
if a == ['session', 'list', '--json']:
    sessions = [{'default': True, 'name': 'default', 'socket_path': str(root / 'herdr.sock')}]
    if mode == 'default-mismatch':
        sessions[0]['socket_path'] = str(root / 'other.sock')
    elif mode == 'default-not-listed':
        sessions[0]['default'] = False
    elif mode == 'default-malformed':
        sessions = None
    print(json.dumps({'sessions': sessions}))
elif a == ['api', 'snapshot']:
    boundary, _, shape = mode.partition('-')
    if boundary in ('envelope', 'result', 'snapshot') and shape in ('null', 'list', 'string', 'missing'):
        value = {'null': None, 'list': [], 'string': 'invalid', 'missing': None}[shape]
        packet = {'result': {'type': 'session_snapshot', 'snapshot': s}}
        if boundary == 'envelope':
            packet = {} if shape == 'missing' else value
        elif boundary == 'result':
            if shape == 'missing':
                del packet['result']
            else:
                packet['result'] = value
        elif shape == 'missing':
            del packet['result']['snapshot']
        else:
            packet['result']['snapshot'] = value
        print(json.dumps(packet))
        sys.exit(0)
    if mode == 'snapshot-workspace-list':
        s['workspaces'] = [[]]
    followup = os.environ.get('FAKE_FOLLOWUP', '')
    if followup and s['workspaces']:
        w, p = s['workspaces'][-1], s['panes'][-1]
        if followup == 'missing-workspace':
            s['workspaces'] = []
        elif followup == 'duplicate-workspace':
            s['workspaces'].append(dict(w))
        elif followup == 'missing-pane':
            s['panes'].pop()
        elif followup == 'duplicate-pane':
            s['panes'].append(dict(p))
        elif followup == 'caller-terminal':
            s['panes'][0]['terminal_id'] = 'caller-replaced'
        elif followup == 'protocol':
            s['protocol'] = 23
        elif followup == 'malformed':
            print('{}')
            sys.exit(0)
        elif followup == 'failed':
            sys.exit(1)
        else:
            obj, key = followup.split('.')
            (w if obj == 'workspace' else p)[key] = '/unexpected' if key == 'cwd' else 'unexpected'
    reply('session_snapshot', snapshot=s)
elif a[:2] == ['workspace', 'create']:
    assert a == ['workspace', 'create', '--cwd', os.environ.get('FAKE_CWD', os.environ['FAKE_REPO']),
                 '--label', os.environ.get('FAKE_NAME', 'double-holo-12'), '--no-focus',
                 '--env', 'DOTFILES_KEYRING_PROMPT=0']
    # Isolated 0.9.5 capture, with paths/opaque IDs replaced by fixture values.
    w = dict(workspace_id='opaque-workspace', label=a[5], active_tab_id='opaque-tab',
             agent_status='unknown', focused=False, number=1, pane_count=1, tab_count=1)
    p = dict(pane_id=os.environ.get('FAKE_TEMP', 'opaque-root'), terminal_id='terminal-new', workspace_id=w['workspace_id'],
             cwd=a[3], foreground_cwd=a[3], tab_id='opaque-tab', focused=False,
             agent_status='unknown', revision=0,
             scroll=dict(max_offset_from_bottom=0, offset_from_bottom=0, viewport_rows=40))
    s['workspaces'].append(w)
    s['panes'].append(p)
    save()
    if mode == 'create-malformed':
        print('{}')
    else:
        if mode == 'create-label-mismatch':
            w['label'] = 'unexpected-label'
        elif mode == 'create-association-mismatch':
            p['workspace_id'] = 'unexpected-workspace'
        elif mode == 'create-cwd-mismatch':
            p['cwd'] = '/unexpected/cwd'
        elif mode == 'create-cwd-missing':
            del p['cwd']
        elif mode == 'create-cwd-null':
            p['cwd'] = None
        patch = json.loads(os.environ.get('FAKE_CREATE_PATCH', '{}'))
        for field, value in patch.items():
            obj, key = field.split('.')
            (w if obj == 'workspace' else p)[key] = value
        reply('workspace_created', workspace=[] if mode == 'create-workspace-list' else w,
              root_pane=[] if mode == 'create-pane-list' else p, tab={'tab_id': 'opaque-tab'})
elif a[:2] == ['workspace', 'get']:
    reply('workspace_info', workspace=next(w for w in s['workspaces'] if w['workspace_id'] == a[2]))
elif a[:2] == ['worktree', 'open']:
    anchor, checkout = a[3], a[5]
    assert a == ['worktree', 'open', '--cwd', anchor, '--path', checkout, '--no-focus']
    w = s['workspaces'][-1]
    w['worktree'] = {'checkout_path': checkout, 'is_linked_worktree': True,
                     'repo_key': anchor + '/.git', 'repo_root': anchor}
    h = next(x for x in s['workspaces'] if x['label'].startswith('\u25c6'))
    if mode != 'no-provenance':
        h['worktree'] = dict(w['worktree'], checkout_path=anchor, is_linked_worktree=False)
    p = next(x for x in s['panes'] if x['workspace_id'] == w['workspace_id'])
    save()
    reply('worktree_opened', already_open=True, root_pane=dict(p, terminal_id='other') if mode == 'attach-terminal' else p,
          workspace=dict(w, workspace_id='adopted') if mode == 'attach-adopt' else w)
elif a[:2] == ['pane', 'split']:
    assert a == ['pane', 'split', os.environ['FAKE_TEMP'], '--direction', 'right', '--cwd',
                 os.environ['FAKE_REPO'], '--env', 'DOTFILES_KEYRING_PROMPT=0', '--no-focus']
    t = next(x for x in s['panes'] if x['pane_id'] == a[2])
    p = dict(t, pane_id='opaque-root', cwd='/unexpected' if mode == 'split-cwd' else a[6],
             terminal_id=t['terminal_id'] if mode == 'split-terminal' else 'terminal-source')
    s['panes'].append(p)
    save()
    reply('pane_info', pane=p)
elif a[:2] == ['pane', 'process-info']:
    reply('pane_process_info', process_info={'pane_id': a[3], 'shell_pid': 1,
          'foreground_processes': [{'pid': 2 if mode == 'busy' else 1, 'name': 'zsh'}]})
elif a[:2] == ['pane', 'close']:
    if mode == 'close-fail':
        sys.exit(1)
    if mode != 'close-noop':
        s['panes'] = [x for x in s['panes'] if x['pane_id'] != a[2]]
    save()
    reply('ok')
elif a[:2] == ['agent', 'start']:
    if os.environ.get('FAKE_LOCK'):  # the project lock must be free before agent startup
        import fcntl
        fcntl.flock(open(os.environ['FAKE_LOCK'], 'r+'), fcntl.LOCK_EX | fcntl.LOCK_NB)
    assert a == ['agent', 'start', os.environ.get('FAKE_NAME', 'double-holo-12'),
                 '--kind', 'pi', '--pane', 'opaque-root', '--', '--name',
                 os.environ.get('FAKE_NAME', 'double-holo-12')]
    if mode == 'start-fail':
        sys.exit(1)
    p = next(p for p in s['panes'] if p['pane_id'] == 'opaque-root')
    agent = dict(p, agent='pi', name=a[2], agent_status='done', interactive_ready=True,
                 agent_session={'agent':'pi','source':'herdr:pi','kind':'path','value':'session-new'})
    if mode == 'agent-status-list':
        agent['agent_status'] = []
    s['agents'] = [agent]
    save()
    if os.environ.get('FAKE_START_ERROR'):
        print(json.dumps({'id': 'cli:agent:start', 'error': {
            'code': os.environ['FAKE_START_ERROR'], 'message': 'DO NOT RECORD STDERR'}}), file=sys.stderr)
        sys.exit(1)
    reply('agent_started', agent=[] if mode == 'start-agent-list' else agent,
          argv=['pi', '--name', a[2]])
elif a[:2] == ['agent', 'get']:
    assert a[2] == 'opaque-root'
    if not s['agents']:
        sys.exit(1)
    agent = dict(s['agents'][0])
    if mode in ('welcome', 'dialog', 'welcome-dialog', 'read-fail', 'read-empty', 'read-json') and not s.get('read'):
        agent.update(agent_status='blocked', interactive_ready=False)
    reply('agent_info', agent=agent)
elif a[:2] == ['agent', 'read']:
    assert a == ['agent', 'read', 'opaque-root', '--source', 'visible', '--lines', '80', '--format', 'text']
    if mode == 'read-fail':
        print('DO NOT RECORD STDERR', file=sys.stderr)
        sys.exit(1)
    s['read'] = True
    save()
    # Herdr 0.9.5 CLI emits plain text, not the socket API's pane_read envelope.
    text = 'Welcome back!\nPress any key to continue (1s)' if mode == 'welcome' else 'Trust this project? Allow?'
    if mode == 'welcome-dialog':
        text += '\nWelcome back!\nPress any key to continue (1s)'
    if mode == 'read-empty':
        text = ''
    elif mode == 'read-json':
        text = '{"result":{"type":"pane_read","read":{"text":"unknown"}}}'
    print(text)
elif a[:2] == ['agent', 'prompt']:
    assert a == ['agent', 'prompt', 'opaque-root', 'Read ' + os.environ['FAKE_PROMPT'] + ' and follow it.']
    receipt = json.loads((root / 'W12-launch.json').read_text())
    assert receipt['stage'] == 'Submitting', 'intent must be durable before delivery'
    s['delivered'] = s.get('delivered', 0) + 1
    s['agents'][0]['agent_status'] = 'working'
    save()
    if mode == 'crash':
        os.kill(os.getppid(), signal.SIGKILL)
    if mode in ('prompt-malformed', 'crash'):
        print('{}')
    else:
        reply('agent_prompted', agent=[] if mode == 'prompt-agent-list' else s['agents'][0])
else:
    raise AssertionError('Forbidden or unknown Herdr operation: ' + repr(a))
'''


class LaunchFixture:
    PROFILE = (19, '0.8.0')
    EXTRA = set()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.repo = self.root / "repo ' ; $(touch SENTINEL)"
        self.repo.mkdir()
        self.prompt = self.root / "W12 ' ; $(touch SENTINEL).md"
        self.prompt.write_text('Approved assignment; isolate before writes.')
        self.state = self.root / 'STATE.md'
        self.state.write_text('| Lane | What | State | Waiting on | Launch |\n| W12 | task | Active | — | Manual |\n')
        self.receipt = self.root / 'W12-launch.json'
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(str(self.root / 'herdr.sock'))
        self.addCleanup(self.sock.close)
        self.fake = self.root / 'herdr'
        self.fake.write_text(FAKE)
        self.fake.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ['PATH'],
                        HOME=str(self.home), HERDR_ENV='1', HERDR_SESSION='intended',
                        HERDR_SOCKET_PATH=str(self.root / 'herdr.sock'),
                        HERDR_PANE_ID='caller-pane', HERDR_WORKSPACE_ID='caller-workspace',
                        FAKE_ROOT=str(self.root), FAKE_REPO=str(self.repo), FAKE_PROMPT=str(self.prompt))
        self.live = self.root / 'live.json'
        self.live.write_text(json.dumps({'version': self.PROFILE[1], 'protocol': self.PROFILE[0],
            'workspaces': [], 'agents': [], 'tabs': [], 'layouts': [], 'panes': [{
                'pane_id': 'caller-pane', 'workspace_id': 'caller-workspace',
                'terminal_id': 'caller-terminal'}]}))
        self.initial_live = self.live.read_text()
        self.initial_state = self.state.read_bytes()

    def tearDown(self):
        allowed = {('session','list'), ('api','snapshot'), ('workspace','create'), ('workspace','get'),
                   ('agent','start'), ('agent','get'), ('agent','read'), ('agent','prompt')} | self.EXTRA
        for argv in self.calls():
            self.assertIn(tuple(argv[:2]), allowed, 'focus/approval/kill/close operations are forbidden')
            self.assertTrue({'--focus','--force','--wait'}.isdisjoint(argv))
            if argv[:2] == ['workspace','create']:
                self.assertIn('--no-focus', argv)
            if argv[:2] == ['pane','close']:
                self.assertEqual(argv[2], 'opaque-temp', 'only the owned temporary pane may close')

    def run_launch(self, mode='', extra=(), env=None):
        environment = dict(self.env, FAKE_MODE=mode, **(env or {}))
        environment = {key: value for key, value in environment.items() if value is not None}
        return subprocess.run([sys.executable, str(SCRIPT), '--requested', '--project', 'double-holo',
            '--lane', 'W12', '--prompt', str(self.prompt), '--repo', str(self.repo),
            '--state', str(self.state), '--session', 'intended', *extra],
            env=environment, text=True, capture_output=True, cwd=self.root, check=False)

    def calls(self):
        p = self.root / 'calls.jsonl'
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def mutations(self, verb):
        return [a for a in self.calls() if a[:2] == verb]

    def reset_fixture(self, live):
        self.live.write_text(json.dumps(live))
        self.state.write_bytes(self.initial_state)
        self.receipt.unlink(missing_ok=True)
        (self.root / 'calls.jsonl').write_text('')

    def assert_stopped(self, result, reason=None):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('Unsupported Herdr', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        if reason:
            self.assertIn(reason, result.stderr)


class LaunchTests(LaunchFixture, unittest.TestCase):
    def run_launch(self, mode='', extra=(), env=None):
        result = super().run_launch(mode, extra, env)
        # Every workflow case has an accepted profile; failures must reach its boundary.
        self.assertNotIn('Unsupported Herdr', result.stderr)
        return result

    def test_success_exact_targets_names_and_no_focus_then_reconcile(self):
        result = self.run_launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['stage'], 'Submitted')
        self.assertEqual(receipt['observation'], 'working')
        self.assertIn('Submitted', self.state.read_text())
        self.assertEqual(self.calls().count(['api', 'snapshot']), 1)
        self.assertEqual(self.run_launch().returncode, 0)
        for verb in (['workspace', 'create'], ['agent', 'start'], ['agent', 'prompt']):
            self.assertEqual(len(self.mutations(verb)), 1)
        self.assertFalse((self.root / 'SENTINEL').exists())

    def test_override_and_alias_collision(self):
        result = self.run_launch(extra=('--name', 'custom_lane'), env={'FAKE_NAME':'custom_lane'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.receipt.read_text())['name'], 'custom_lane')

    def test_absent_session_verified_default_matches_and_reconciles_once(self):
        for _ in range(2):
            result = self.run_launch(extra=('--session', 'default'), env={'HERDR_SESSION': None})
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.mutations(['workspace', 'create'])), 1)
        self.assertEqual(len(self.mutations(['agent', 'start'])), 1)
        self.assertEqual(len(self.mutations(['agent', 'prompt'])), 1)
        self.assertEqual(json.loads(self.receipt.read_text())['context']['session'], 'default')
        self.assertEqual(self.calls()[0], ['session', 'list', '--json'])

    def test_absent_session_mismatched_or_unlisted_default_never_launches(self):
        for mode in ('default-mismatch', 'default-not-listed', 'default-malformed'):
            with self.subTest(mode=mode):
                self.reset_fixture(json.loads(self.initial_live))
                self.assert_stopped(self.run_launch(mode, extra=('--session', 'default'),
                                                   env={'HERDR_SESSION': None}))
                self.assertEqual(self.calls(), [['session', 'list', '--json']])
                self.assertFalse(self.receipt.exists())

    def test_present_empty_session_refuses_even_when_requested_name_is_empty(self):
        self.assert_stopped(self.run_launch(extra=('--session', ''), env={'HERDR_SESSION': ''}))
        self.assertEqual(self.calls(), [])

    def test_absent_session_default_name_must_match_requested_session(self):
        self.assert_stopped(self.run_launch(env={'HERDR_SESSION': None}))
        self.assertEqual(self.calls(), [['session', 'list', '--json']])

    def test_absent_session_missing_or_regular_socket_path_never_queries_or_launches(self):
        self.sock.close()
        socket_path = self.root / 'herdr.sock'
        socket_path.unlink()
        for regular_file in (False, True):
            with self.subTest(regular_file=regular_file):
                if regular_file:
                    socket_path.write_text('not a socket')
                self.assert_stopped(self.run_launch(extra=('--session', 'default'), env={'HERDR_SESSION': None}))
                self.assertEqual(self.calls(), [])

    def test_missing_or_mismatched_context_and_missing_prompt_prevent_calls(self):
        for env in ({'HERDR_ENV':''}, {'HERDR_SESSION':'wrong'}, {'HERDR_SESSION':''},
                    {'HERDR_PANE_ID':''}, {'HERDR_SOCKET_PATH':''}):
            with self.subTest(env=env):
                self.assertNotEqual(self.run_launch(env=env).returncode, 0)
                self.assertEqual(self.calls(), [])
        self.prompt.unlink()
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_live_collision_or_wrong_caller_prevents_creation(self):
        initial = json.loads(self.live.read_text())
        for field, value, reason in [
            ('workspaces', [{'label':'double-holo-12','workspace_id':'other'}], 'Name collision'),
            ('agents', [{'name':'double-holo-12','pane_id':'other'}], 'Name collision'),
            ('panes', [], 'Inherited caller'),
        ]:
            with self.subTest(field=field):
                self.live.write_text(json.dumps(dict(initial, **{field:value})))
                self.assert_stopped(self.run_launch(), reason)
                self.assertEqual(self.mutations(['workspace', 'create']), [])

    def test_creation_metadata_mismatch_preserves_observed_ids_without_advancing(self):
        initial_live, initial_state = self.live.read_text(), self.state.read_text()
        for mode in ('create-label-mismatch', 'create-association-mismatch'):
            with self.subTest(mode=mode):
                self.live.write_text(initial_live)
                self.state.write_text(initial_state)
                self.receipt.unlink(missing_ok=True)
                (self.root / 'calls.jsonl').write_text('')
                result = self.run_launch(mode)
                self.assertEqual(result.returncode, 2)
                self.assertIn('Creation returned unexpected', result.stderr)
                record = json.loads(self.receipt.read_text())
                self.assertEqual(record.get('created_response'), {
                    'workspace': 'opaque-workspace', 'pane': 'opaque-root', 'terminal': 'terminal-new'})
                self.assertEqual(record['stage'], 'Creating')
                self.assertNotIn('Created', record['checkpoints'])
                self.assertEqual(self.mutations(['agent','start']), [])
                self.assertEqual(self.run_launch().returncode, 2)
                self.assertEqual(len(self.mutations(['workspace','create'])), 1)

    def test_creation_cwd_discrepancy_requires_one_exact_snapshot_before_start(self):
        # Missing/null are schema-permitted mutations, not incident reproductions.
        for mode in ('create-cwd-missing', 'create-cwd-null', 'create-cwd-mismatch'):
            with self.subTest(mode=mode):
                self.reset_fixture(json.loads(self.initial_live))
                result = self.run_launch(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                record = json.loads(self.receipt.read_text())
                self.assertEqual(record['stage'], 'Submitted')
                self.assertEqual(record['creation_cwd_confirmed'], 'snapshot')
                self.assertEqual(record['context']['terminal'], 'caller-terminal')
                calls = self.calls()
                snapshots = [i for i, a in enumerate(calls) if a == ['api', 'snapshot']]
                self.assertEqual(len(snapshots), 2)
                self.assertLess(snapshots[-1], next(i for i, a in enumerate(calls)
                                                  if a[:2] == ['agent', 'start']))
                self.assertEqual(self.run_launch().returncode, 0)
                for verb in (['workspace', 'create'], ['agent', 'start'], ['agent', 'prompt']):
                    self.assertEqual(len(self.mutations(verb)), 1)

    def test_creation_fallback_does_not_rewrite_caller_terminal_fingerprint(self):
        result = self.run_launch('create-cwd-null', env={'FAKE_FOLLOWUP': 'caller-terminal'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.receipt.read_text())['context']['terminal'], 'caller-terminal')

    def test_creation_failure_records_all_three_metadata_comparisons(self):
        result = self.run_launch('create-cwd-null', env={'FAKE_CREATE_PATCH': json.dumps({
            'workspace.label': 'bad-label', 'root_pane.workspace_id': 'bad-workspace'})})
        self.assert_stopped(result)
        record = json.loads(self.receipt.read_text())
        self.assertEqual(record['creation_validation']['create'], {
            'workspace.label': {'expected': 'double-holo-12', 'observed': 'bad-label'},
            'root_pane.workspace_id': {'expected': 'opaque-workspace', 'observed': 'bad-workspace'},
            'root_pane.cwd': {'expected': str(self.repo), 'observed': None}})
        self.assertEqual(record['stage'], 'Creating')
        self.assertEqual(self.calls().count(['api', 'snapshot']), 1)
        self.assertEqual(self.mutations(['agent', 'start']), [])

    def test_creation_fallback_requires_unique_exact_workspace_and_root_pane(self):
        for followup, field, expected, observed in [
            ('missing-workspace', 'workspace_count', 1, 0),
            ('duplicate-workspace', 'workspace_count', 1, 2),
            ('workspace.label', 'workspace.label', 'double-holo-12', 'unexpected'),
            ('missing-pane', 'root_pane_count', 1, 0),
            ('duplicate-pane', 'root_pane_count', 1, 2),
            ('pane.workspace_id', 'root_pane.workspace_id', 'opaque-workspace', 'unexpected'),
            ('pane.terminal_id', 'root_pane.terminal_id', 'terminal-new', 'unexpected'),
            ('pane.cwd', 'root_pane.cwd', str(self.repo), '/unexpected'),
        ]:
            with self.subTest(followup=followup):
                self.reset_fixture(json.loads(self.initial_live))
                result = self.run_launch('create-cwd-null', env={'FAKE_FOLLOWUP': followup})
                self.assert_stopped(result)
                record = json.loads(self.receipt.read_text())
                self.assertEqual(record['creation_validation']['snapshot'][field],
                                 {'expected': expected, 'observed': observed})
                self.assertEqual(record['creation_validation']['create']['root_pane.cwd'],
                                 {'expected': str(self.repo), 'observed': None})
                self.assertEqual(record['stage'], 'Creating')
                self.assertEqual(self.mutations(['agent', 'start']), [])
                self.assertEqual(self.mutations(['agent', 'prompt']), [])
                self.assert_stopped(self.run_launch(), 'Creation uncertain')
                self.assertEqual(len(self.mutations(['workspace', 'create'])), 1)

    def test_creation_failure_receipt_names_each_failed_comparison(self):
        for field, value, expected, observed in [
            ('workspace.label', 'unexpected-label', 'double-holo-12', 'unexpected-label'),
            ('root_pane.workspace_id', 'other-workspace', 'opaque-workspace', 'other-workspace'),
            ('workspace.workspace_id', '', 'nonempty string', ''),
            ('root_pane.pane_id', None, 'nonempty string', None),
            ('root_pane.terminal_id', [], 'nonempty string', {'type': 'list'}),
            ('root_pane.cwd', {'text': 'DO NOT RECORD'}, str(self.repo), {'type': 'dict'}),
            ('root_pane.cwd', str(self.repo) + '\n', str(self.repo), {'type': 'str'}),
            ('workspace.label', 'DO NOT RECORD\n', 'double-holo-12', {'type': 'str'}),
            ('workspace.label', 'DO NOT RECORD' * 400, 'double-holo-12', {'type': 'str'}),
        ]:
            with self.subTest(field=field):
                self.reset_fixture(json.loads(self.initial_live))
                result = self.run_launch(env={'FAKE_CREATE_PATCH': json.dumps({field: value})})
                self.assert_stopped(result)
                record = json.loads(self.receipt.read_text())
                self.assertEqual(record['creation_validation']['create'][field],
                                 {'expected': expected, 'observed': observed})
                self.assertNotIn('DO NOT RECORD', self.receipt.read_text())
                self.assertEqual(record['stage'], 'Creating')
                self.assertEqual(self.calls().count(['api', 'snapshot']), 1)
                self.assertEqual(self.mutations(['agent', 'start']), [])

    def test_creation_fallback_read_errors_keep_first_evidence_and_never_start(self):
        for followup in ('malformed', 'failed', 'protocol'):
            with self.subTest(followup=followup):
                self.reset_fixture(json.loads(self.initial_live))
                # Deliberately reject the second snapshot's protocol, not preflight.
                result = LaunchFixture.run_launch(self, 'create-cwd-null', env={'FAKE_FOLLOWUP': followup})
                self.assertEqual(result.returncode, 2, result.stderr)
                record = json.loads(self.receipt.read_text())
                self.assertEqual(record['creation_validation']['create']['root_pane.cwd'],
                                 {'expected': str(self.repo), 'observed': None})
                self.assertEqual(record['stage'], 'Creating')
                self.assertEqual(self.calls().count(['api', 'snapshot']), 2)
                self.assertEqual(self.mutations(['agent', 'start']), [])
                self.assertEqual(self.mutations(['agent', 'prompt']), [])

    def test_malformed_nested_responses_use_normal_error_path(self):
        initial_live, initial_state = self.live.read_text(), self.state.read_text()
        cases = [
            ('snapshot-workspace-list', None, 'Invalid response collection: workspaces'),
            ('create-workspace-list', 'Creating', 'Invalid response object: workspace'),
            ('create-pane-list', 'Creating', 'Invalid response object: root_pane'),
            ('start-agent-list', 'Starting', 'Invalid response object: agent'),
            ('read-fail', 'Starting', "('agent', 'read') failed (exit 1)"),
            ('read-empty', 'Starting', 'Startup blocked/unknown'),
            ('read-json', 'Starting', 'Startup blocked/unknown'),
            ('agent-status-list', 'Starting', 'Invalid response field: agent_status'),
            ('prompt-agent-list', 'Submitting', 'Invalid response object: agent'),
        ]
        for mode, stage, reason in cases:
            with self.subTest(mode=mode):
                self.live.write_text(initial_live)
                self.state.write_text(initial_state)
                self.receipt.unlink(missing_ok=True)
                (self.root / 'calls.jsonl').write_text('')
                result = self.run_launch(mode)
                self.assertEqual(result.returncode, 2)
                self.assertIn('Launch stopped:', result.stderr)
                self.assertIn(reason, result.stderr)
                self.assertNotIn('Unsupported Herdr', result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                if stage is None:
                    self.assertFalse(self.receipt.exists())
                    self.assertEqual(self.mutations(['workspace','create']), [])
                else:
                    record = json.loads(self.receipt.read_text())
                    self.assertEqual(record['stage'], stage)
                    self.assertIn(reason, record['error'])
                    if mode in ('create-workspace-list', 'create-pane-list'):
                        field = 'workspace' if mode == 'create-workspace-list' else 'root_pane'
                        self.assertEqual(record['creation_validation']['create'][field],
                                         {'expected': 'object', 'observed': {'type': 'list'}})
                    if mode == 'create-pane-list':
                        self.assertNotIn('created_response', record)
                        self.assertNotIn('Created', record['checkpoints'])
                        self.assertEqual(self.mutations(['agent', 'start']), [])
                    self.assertIn('inspect receipt', self.state.read_text())
                    if stage in ('Creating', 'Submitting'):
                        self.assertEqual(self.run_launch().returncode, 2)
                        self.assertEqual(len(self.mutations(['workspace','create'])), 1)
                        self.assertLessEqual(len(self.mutations(['agent','prompt'])), 1)

    def test_malformed_receipt_uses_normal_error_path_without_overwriting_it(self):
        self.receipt.write_text('[]')
        result = self.run_launch()
        self.assertEqual(result.returncode, 2)
        self.assertIn('Launch stopped:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual(self.receipt.read_text(), '[]')
        self.assertEqual(self.mutations(['workspace','create']), [])

    def test_malformed_create_never_duplicates(self):
        self.assertNotEqual(self.run_launch('create-malformed').returncode, 0)
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Creating')
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(len(self.mutations(['workspace', 'create'])), 1)
        self.assertEqual(self.mutations(['agent', 'prompt']), [])

    def test_start_failure_does_not_claim_ready_or_restart(self):
        self.assertNotEqual(self.run_launch('start-fail').returncode, 0)
        self.assertNotEqual(self.run_launch('start-fail').returncode, 0)
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Starting')
        self.assertEqual(len(self.mutations(['agent','start'])), 1)
        self.assertEqual(self.mutations(['agent','prompt']), [])

    def test_possibly_delivered_malformed_prompt_never_resends(self):
        self.assertNotEqual(self.run_launch('prompt-malformed').returncode, 0)
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Submitting')
        self.assertEqual(json.loads(self.live.read_text())['delivered'], 1)
        self.assertEqual(len(self.mutations(['agent','prompt'])), 1)

    def test_process_crash_after_delivery_never_resends(self):
        self.assertNotEqual(self.run_launch('crash').returncode, 0)
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Submitting')
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(json.loads(self.live.read_text())['delivered'], 1)

    def test_welcome_waits_naturally_but_real_dialog_stops(self):
        result = self.run_launch('welcome')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.mutations(['agent','read'])), 1)

    def test_start_exit_one_with_recognized_pi_inspects_without_restart(self):
        for mode, code, submitted in [('welcome', 'agent_not_ready', True),
                                       ('', 'timeout', True), ('dialog', 'agent_not_ready', False)]:
            with self.subTest(mode=mode, code=code):
                self.reset_fixture(json.loads(self.initial_live))
                result = self.run_launch(mode, env={'FAKE_START_ERROR': code})
                self.assertEqual(result.returncode, 0 if submitted else 2, result.stderr)
                record = json.loads(self.receipt.read_text())
                self.assertEqual(record['stage'], 'Submitted' if submitted else 'Starting')
                self.assertIn(f'Herdr code: {code}', record['start_error'])
                self.assertEqual(record['agent_session']['value'], 'session-new')
                self.assertEqual(len(self.mutations(['agent', 'prompt'])), int(submitted))
                for private in ('DO NOT RECORD STDERR', 'Trust this project?', 'Welcome back!'):
                    self.assertNotIn(private, self.receipt.read_text() + self.state.read_text() + result.stderr)
                if submitted:
                    self.assertEqual(self.run_launch().returncode, 0)
                    self.assertEqual(len(self.mutations(['agent', 'prompt'])), 1)
                self.assertEqual(len(self.mutations(['agent', 'start'])), 1)

    def test_unrecognized_start_stderr_is_not_recorded(self):
        result = self.run_launch(env={'FAKE_START_ERROR': 'DO NOT RECORD CODE'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('DO NOT RECORD', self.receipt.read_text() + self.state.read_text() + result.stderr)
        self.assertNotIn('Herdr code:', json.loads(self.receipt.read_text())['start_error'])

    def test_real_dialog_stops(self):
        self.assert_stopped(self.run_launch('dialog'), 'Startup blocked/unknown')
        self.assertEqual(self.mutations(['agent','prompt']), [])

    def test_real_dialog_with_stale_welcome_text_stops(self):
        self.assert_stopped(self.run_launch('welcome-dialog'), 'Startup blocked/unknown')
        self.assertEqual(self.mutations(['agent','prompt']), [])

    def test_state_existing_launch_without_receipt_prevents_creation(self):
        self.state.write_text(self.state.read_text().replace('Manual', 'old-workspace / old-pane; Submitted'))
        self.assert_stopped(self.run_launch(), 'STATE records an existing launch')
        self.assertEqual(self.mutations(['workspace','create']), [])

    def test_blocked_start_pins_session_and_refuses_replacement(self):
        self.assertNotEqual(self.run_launch('dialog').returncode, 0)
        live = json.loads(self.live.read_text())
        live['agents'][0]['agent_session']['value'] = 'replacement-session'
        self.live.write_text(json.dumps(live))
        result = self.run_launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Pi session changed', result.stderr)
        self.assertEqual(self.mutations(['agent','prompt']), [])
        self.assertEqual(len(self.mutations(['agent','start'])), 1)

    def test_blocked_partial_launch_resumes_existing_pi_without_restart(self):
        self.assertNotEqual(self.run_launch('dialog').returncode, 0)
        result = self.run_launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(self.receipt.read_text()).get('error'))
        self.assertNotIn('inspect receipt', self.state.read_text())
        for verb in (['workspace','create'], ['agent','start'], ['agent','prompt']):
            self.assertEqual(len(self.mutations(verb)), 1)

    def test_reconciled_created_receipt_starts_on_existing_root(self):
        self.assertNotEqual(self.run_launch('create-malformed').returncode, 0)
        # Simulate an operator explicitly reconciling the lost response, not an auto retry.
        record = json.loads(self.receipt.read_text())
        record.update(stage='Created', workspace='opaque-workspace', pane='opaque-root', terminal='terminal-new')
        self.receipt.write_text(json.dumps(record))
        result = self.run_launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.mutations(['workspace','create'])), 1)
        self.assertEqual(len(self.mutations(['agent','start'])), 1)

    def test_timeout_after_prompt_delivery_is_durable_and_never_resends(self):
        spec = importlib.util.spec_from_file_location('lane_launch_timeout', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_run = subprocess.run
        def timeout_after_delivery(argv, **kwargs):
            result = real_run(argv, **kwargs)
            if argv[1:3] == ['agent','prompt']:
                raise subprocess.TimeoutExpired(argv, 10)
            return result
        argv = [str(SCRIPT), '--requested', '--project','double-holo', '--lane','W12',
                '--prompt',str(self.prompt), '--repo',str(self.repo), '--state',str(self.state),
                '--session','intended']
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(sys, 'argv', argv), \
                mock.patch.object(module.subprocess, 'run', side_effect=timeout_after_delivery), \
                contextlib.redirect_stderr(stderr):
            self.assertEqual(module.main(), 2)
        self.assertNotIn('Unsupported Herdr', stderr.getvalue())
        self.assertIn('timed out', stderr.getvalue())
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Submitting')
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(json.loads(self.live.read_text())['delivered'], 1)
        self.assertEqual(len(self.mutations(['agent','prompt'])), 1)

    def test_state_write_failure_reports_both_errors_without_resubmission(self):
        spec = importlib.util.spec_from_file_location('lane_launch_state_error', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        argv = [str(SCRIPT), '--requested', '--project','double-holo', '--lane','W12',
                '--prompt',str(self.prompt), '--repo',str(self.repo), '--state',str(self.state),
                '--session','intended']
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, dict(self.env, FAKE_MODE='prompt-malformed'), clear=True), \
                mock.patch.object(sys, 'argv', argv), \
                mock.patch.object(module.Launch, 'update_state', side_effect=AttributeError('state-write-failed')), \
                contextlib.redirect_stderr(stderr):
            self.assertEqual(module.main(), 2)
        self.assertIn('malformed JSON', stderr.getvalue())
        self.assertIn('STATE summary needs updating', stderr.getvalue())
        self.assertIn('state-write-failed', stderr.getvalue())
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Submitting')
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(len(self.mutations(['agent','prompt'])), 1)

    def test_state_write_failure_after_submission_still_returns_failure(self):
        spec = importlib.util.spec_from_file_location('lane_launch_state_only_error', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        argv = [str(SCRIPT), '--requested', '--project','double-holo', '--lane','W12',
                '--prompt',str(self.prompt), '--repo',str(self.repo), '--state',str(self.state),
                '--session','intended']
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(sys, 'argv', argv), \
                mock.patch.object(module.Launch, 'update_state', side_effect=OSError('state-write-failed')), \
                contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(module.main(), 2)
        self.assertIn('STATE summary needs updating', stderr.getvalue())
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Submitted')
        self.assertEqual(self.run_launch().returncode, 0)
        self.assertEqual(len(self.mutations(['agent','prompt'])), 1)

    def test_unrequested_invocation_has_no_herdr_calls(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--project','double-holo',
            '--lane','W12', '--prompt',str(self.prompt), '--repo',str(self.repo),
            '--state',str(self.state), '--session','intended'], env=self.env, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_changed_prompt_or_live_identity_refuses_reuse(self):
        self.assertEqual(self.run_launch().returncode, 0)
        original = self.prompt.read_text()
        self.prompt.write_text('Changed assignment')
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.prompt.write_text(original)
        live = json.loads(self.live.read_text())
        live['agents'][0]['agent_session']['value'] = 'replacement-session'
        self.live.write_text(json.dumps(live))
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(len(self.mutations(['agent','prompt'])), 1)


class Protocol22LaunchTests(LaunchTests):
    PROFILE = (22, '0.9.5')


GIT = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid']
FLAT = {'FAKE_CWD': None, 'FAKE_TEMP': None, 'FAKE_LOCK': None}  # today's flat fixture contract


class GroupedTests(LaunchFixture, unittest.TestCase):
    EXTRA = {('worktree', 'open'), ('pane', 'split'), ('pane', 'process-info'), ('pane', 'close')}
    TOPOLOGY = [['workspace', 'create'], ['worktree', 'open'], ['pane', 'split'], ['pane', 'close'],
                ['agent', 'start'], ['agent', 'prompt']]

    def setUp(self):
        super().setUp()
        self.anchors = self.home / '.lane-anchors'
        self.anchor, self.lock = self.anchors / 'double-holo', self.anchors / '.double-holo.lock'
        self.checkout = self.anchors / 'double-holo-lanes' / '12'
        self.env.update(FAKE_TEMP='opaque-temp', FAKE_CWD=str(self.checkout), FAKE_LOCK=str(self.lock))

    def edit(self, change):
        data = json.loads(self.live.read_text())
        change(data)
        self.live.write_text(json.dumps(data))

    def setup_grouping(self, anchor=True, lock=True, heading='bare'):
        shutil.rmtree(self.anchors, ignore_errors=True)
        self.anchors.mkdir(parents=True)
        if anchor:
            self.anchor.mkdir()
            subprocess.run([*GIT, '-C', str(self.anchor), 'init', '-q', '-b', 'main'], check=True)
            subprocess.run([*GIT, '-C', str(self.anchor), 'commit', '-q', '--allow-empty', '-m', 'a'], check=True)
        if lock:
            self.lock.touch()
        if heading:
            primary = {'repo_root': str(self.anchor), 'checkout_path': str(self.anchor),
                       'is_linked_worktree': False, 'repo_key': f'{self.anchor}/.git'}
            def add(data):
                data['workspaces'].append({'workspace_id': 'heading', 'label': '\u25c6 double-holo',
                                           'worktree': primary if heading == 'primary' else None})
                data['panes'].append({'pane_id': 'heading-pane', 'workspace_id': 'heading',
                                      'terminal_id': 'heading-terminal', 'cwd': str(self.anchor)})
            self.edit(add)

    def prepare(self, **kwargs):
        self.reset_fixture(json.loads(self.initial_live))
        self.setup_grouping(**kwargs)

    def effects(self):
        return [a[:2] for a in self.calls() if a[:2] in self.TOPOLOGY]

    def test_absent_setup_launches_flat_and_says_so(self):
        result = self.run_launch(env=FLAT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('not set up', result.stderr)
        self.assertEqual(json.loads(self.receipt.read_text())['version'], 1)
        self.assertEqual(self.effects(), [['workspace', 'create'], ['agent', 'start'], ['agent', 'prompt']])

    def test_partial_broken_or_ambiguous_setup_stops_before_mutation(self):
        bare = dict(anchor=False, lock=False, heading=None)
        def workspace(**fields):
            return lambda: self.edit(lambda d: d['workspaces'].append({'workspace_id': 'x', **fields}))
        def mutate_heading(change):
            return lambda: self.edit(lambda d: change(next(w for w in d['workspaces'] if w['workspace_id'] == 'heading')))
        def pane(cwd):
            return lambda: self.edit(lambda d: d['panes'][-1].update(cwd=cwd))
        for name, kwargs, change in [
            ('heading only', dict(anchor=False, lock=False), None),
            ('anchor only', dict(heading=None, lock=False), None),
            ('lock only', dict(anchor=False, heading=None), None),
            ('missing lock', dict(lock=False), None),
            ('orphan lanes', bare, lambda: (self.anchors / 'double-holo-lanes').mkdir()),
            ('dangling anchor', bare, lambda: self.anchor.symlink_to(self.root / 'missing')),
            ('related workspace', bare, workspace(label='x', worktree={'checkout_path': str(self.checkout)})),
            ('uncommitted anchor', dict(anchor=False),
             lambda: (self.anchor.mkdir(), subprocess.run(['git', '-C', str(self.anchor), 'init', '-q'], check=True))),
            ('duplicate heading', {}, workspace(label='\u25c6 double-holo')),
            ('wrong heading cwd', {}, pane('/elsewhere')),
            ('wrong provenance', dict(heading='primary'), mutate_heading(lambda w: w['worktree'].update(repo_root='/x'))),
        ]:
            with self.subTest(name):
                self.prepare(**kwargs)
                if change:
                    change()
                self.assert_stopped(self.run_launch(), 'partial, broken or ambiguous')
                self.assertEqual((self.effects(), self.receipt.exists(), self.checkout.exists()), ([], False, False))

    def test_grouped_topology_alias_provenance_and_lock_release(self):
        for heading, alias in (('bare', None), ('primary', 'review_room')):
            with self.subTest(heading=heading, alias=alias):
                self.prepare(heading=heading)
                name = alias or 'double-holo-12'
                result = self.run_launch(extra=('--name', alias) if alias else (), env={'FAKE_NAME': name})
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads(self.receipt.read_text())
                self.assertEqual((receipt['version'], receipt['stage'], receipt['name'], receipt['pane'],
                                  receipt['terminal'], receipt['group']['checkout']),
                                 (2, 'Submitted', name, 'opaque-root', 'terminal-source', str(self.checkout)))
                self.assertEqual(self.effects(), self.TOPOLOGY)
                panes = [p for p in json.loads(self.live.read_text())['panes'] if p['workspace_id'] == 'opaque-workspace']
                self.assertEqual([(p['pane_id'], p['cwd']) for p in panes], [('opaque-root', str(self.repo))])
                listing = subprocess.run(['git', '-C', str(self.anchor), 'worktree', 'list'], capture_output=True, text=True)
                self.assertIn(str(self.checkout), listing.stdout)
                with self.lock.open('r+') as held:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_checkout_collisions_and_held_project_lock_never_mutate(self):
        def registered():
            subprocess.run(['git', '-C', str(self.anchor), 'worktree', 'add', '-q', '--detach', str(self.checkout)], check=True)
            shutil.rmtree(self.checkout)
        for name, change in [
            ('orphan directory', lambda: self.checkout.mkdir(parents=True)),
            ('registered missing directory', registered),
            ('open workspace', lambda: self.edit(lambda d: d['workspaces'].append(
                {'workspace_id': 'x', 'label': 'x', 'worktree': {'checkout_path': str(self.checkout)}}))),
        ]:
            with self.subTest(name):
                self.prepare()
                change()
                self.assert_stopped(self.run_launch(), 'Lane checkout')
                self.assertEqual((self.effects(), self.receipt.exists()), ([], False))
        self.prepare()
        with self.lock.open('r+') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_stopped(self.run_launch())
        self.assertEqual((self.effects(), self.receipt.exists(), self.checkout.exists()), ([], False, False))

    def test_topology_faults_stop_and_reruns_only_inspect(self):
        for mode, stage, closes in [('create-malformed', 'Creating', 0), ('checkout', 'Checkout', 0),
                ('attach-adopt', 'Attaching', 0), ('attach-terminal', 'Attaching', 0),
                ('split-terminal', 'Splitting', 0), ('split-cwd', 'Splitting', 0), ('busy', 'Splitting', 0),
                ('no-provenance', 'Splitting', 0), ('close-fail', 'Closing', 1), ('close-noop', 'Closing', 1)]:
            with self.subTest(mode):
                self.prepare()
                if mode == 'checkout':
                    (self.anchors / 'double-holo-lanes').write_text('not a directory')
                self.assert_stopped(self.run_launch(mode))
                self.assertEqual(json.loads(self.receipt.read_text())['stage'], stage)
                self.assertEqual(len(self.mutations(['pane', 'close'])), closes)
                self.assertEqual(self.mutations(['agent', 'start']) + self.mutations(['agent', 'prompt']), [])
                seen = self.calls()
                self.assert_stopped(self.run_launch())
                self.assertEqual([a for a in self.calls()[len(seen):] if a[:2] != ['api', 'snapshot']], [])

    def test_receipts_never_regroup_or_fall_back_flat_and_revalidate_target(self):
        flat = dict(anchor=False, lock=False, heading=None)
        for mode, outcome in (('', 0), ('dialog', 2)):
            with self.subTest(flat=mode):
                self.prepare(**flat)
                self.assertEqual(self.run_launch(mode, env=FLAT).returncode, 0 if not mode else 2)
                self.setup_grouping()
                before = self.calls()
                result = self.run_launch()
                self.assertEqual(result.returncode, outcome, result.stderr)
                self.assertEqual([a for a in self.calls()[len(before):] if a[:2] != ['api', 'snapshot']],
                                 [['workspace', 'get', 'opaque-workspace'], ['agent', 'get', 'opaque-root']]
                                 if outcome == 0 else [])
        for name, change, expected in [
            ('grouping lost', lambda d: (d['workspaces'].pop(0), d['workspaces'][0].pop('worktree')), 'never regroup'),
            ('source cwd differs', lambda d: d['panes'][-1].update(cwd='/elsewhere'), 'Topology'),
        ]:
            with self.subTest(name):
                self.prepare()
                self.assert_stopped(self.run_launch('dialog'), 'Startup blocked')
                self.edit(change)
                if name == 'grouping lost':
                    shutil.rmtree(self.anchors)
                self.assert_stopped(self.run_launch(), expected)
                self.assertEqual(len(self.mutations(['agent', 'start'])), 1)
                self.assertEqual(self.mutations(['agent', 'prompt']), [])
        self.prepare()
        self.assert_stopped(self.run_launch('prompt-malformed'))
        self.assert_stopped(self.run_launch())
        self.assertEqual(len(self.mutations(['agent', 'prompt'])), 1)


class ProtocolPolicyTests(LaunchFixture, unittest.TestCase):
    def assert_preflight_rejected(self, reason):
        result = self.run_launch()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(self.state.read_bytes(), self.initial_state)
        self.assertEqual(self.calls(), [['api', 'snapshot']])

    def test_legacy19_version_metadata_remains_nonbinding(self):
        for present, version in [(False, None), (True, None), (True, '0.9.5'),
                                 (True, 'unreviewed'), (True, False), (True, []), (True, {})]:
            with self.subTest(present=present, version=version):
                live = dict(json.loads(self.initial_live), protocol=19, version=version)
                if not present:
                    del live['version']
                self.reset_fixture(live)
                result = self.run_launch()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'Submitted')
                for verb in (['workspace', 'create'], ['agent', 'start'], ['agent', 'prompt']):
                    self.assertEqual(len(self.mutations(verb)), 1)

    def test_rejected_protocol_preflight_has_no_effects(self):
        for present, protocol in [(False, None), *((True, value) for value in (
                None, True, False, 19.0, 22.0, '19', '22', [], {}, 20, 21, 23))]:
            with self.subTest(present=present, protocol=protocol):
                live = dict(json.loads(self.initial_live), protocol=protocol, version='0.9.5')
                if not present:
                    del live['protocol']
                self.reset_fixture(live)
                self.assert_preflight_rejected('Unsupported Herdr')

    def test_protocol22_requires_exact_snapshot_version(self):
        for present, version in [(False, None), *((True, value) for value in (
                None, True, 0.95, [], {}, '0.8.0', '0.9.4', '0.9.6', 'v0.9.5',
                '0.9.5+build', ' 0.9.5', '0.9.5 ', '0.9.5\n'))]:
            with self.subTest(present=present, version=version):
                live = dict(json.loads(self.initial_live), protocol=22, version=version)
                if not present:
                    del live['version']
                self.reset_fixture(live)
                self.assert_preflight_rejected('Unsupported Herdr')

    def test_snapshot_consumed_collections_reject_malformed_shapes(self):
        for protocol, version in ((19, '0.8.0'), (22, '0.9.5')):
            for field in ('panes', 'workspaces', 'agents'):
                for present, value in [(False, None), *((True, value) for value in (
                        None, {}, 'invalid', 17, [None], [[]]))]:
                    with self.subTest(protocol=protocol, field=field, present=present, value=value):
                        live = dict(json.loads(self.initial_live), protocol=protocol, version=version)
                        if present:
                            live[field] = value
                        else:
                            del live[field]
                        self.reset_fixture(live)
                        self.assert_preflight_rejected('Invalid response collection: ' + field)

    def test_malformed_snapshot_envelope_and_result_are_preflight_only(self):
        for protocol, version in ((19, '0.8.0'), (22, '0.9.5')):
            for boundary in ('envelope', 'result', 'snapshot'):
                for shape in ('null', 'list', 'string', 'missing'):
                    with self.subTest(protocol=protocol, boundary=boundary, shape=shape):
                        self.reset_fixture(dict(json.loads(self.initial_live), protocol=protocol, version=version))
                        result = self.run_launch(boundary + '-' + shape)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn('Invalid response object: snapshot' if boundary == 'snapshot'
                                      else 'malformed JSON', result.stderr)
                        self.assertNotIn('Unsupported Herdr', result.stderr)
                        self.assertNotIn('Traceback', result.stderr)
                        self.assertFalse(self.receipt.exists())
                        self.assertEqual(self.state.read_bytes(), self.initial_state)
                        self.assertEqual(self.calls(), [['api', 'snapshot']])

    def test_rejected_snapshot_preserves_submitted_receipt(self):
        for protocol, version in ((19, '0.8.0'), (22, '0.9.5')):
            with self.subTest(protocol=protocol):
                self.reset_fixture(dict(json.loads(self.initial_live), protocol=protocol, version=version))
                result = self.run_launch()
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt, state = self.receipt.read_bytes(), self.state.read_bytes()
                for changed in ({'protocol': 23}, {'protocol': 22, 'version': '0.9.6'}, {'agents': {}}):
                    with self.subTest(changed=changed):
                        live = json.loads(self.live.read_text())
                        live.update(protocol=protocol, version=version, agents=[])
                        live.update(changed)
                        self.live.write_text(json.dumps(live))
                        (self.root / 'calls.jsonl').write_text('')
                        result = self.run_launch()
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertNotIn('Traceback', result.stderr)
                        self.assertEqual(self.receipt.read_bytes(), receipt)
                        self.assertEqual(self.state.read_bytes(), state)
                        self.assertEqual(self.calls(), [['api', 'snapshot']])


if __name__ == '__main__':
    unittest.main()
