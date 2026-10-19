"""Launch boundary tests: all Herdr traffic goes to a fixture executable."""
import contextlib
import importlib.util
import io
import json
import os
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
if a == ['api', 'snapshot']:
    reply('session_snapshot', snapshot=s)
elif a[:2] == ['workspace', 'create']:
    assert a == ['workspace', 'create', '--cwd', os.environ['FAKE_REPO'],
                 '--label', os.environ.get('FAKE_NAME', 'double-holo-12'), '--no-focus']
    w = dict(workspace_id='opaque-workspace', label=a[5])
    p = dict(pane_id='opaque-root', terminal_id='terminal-new', workspace_id=w['workspace_id'],
             cwd=a[3], tab_id='opaque-tab', focused=False, agent_status='unknown', revision=1)
    s['workspaces'].append(w)
    s['panes'].append(p)
    save()
    if mode == 'create-malformed':
        print('{}')
    else:
        reply('workspace_created', workspace=w, root_pane=p, tab={'tab_id': 'opaque-tab'})
elif a[:2] == ['workspace', 'get']:
    reply('workspace_info', workspace=next(w for w in s['workspaces'] if w['workspace_id'] == a[2]))
elif a[:2] == ['agent', 'start']:
    assert a == ['agent', 'start', os.environ.get('FAKE_NAME', 'double-holo-12'),
                 '--kind', 'pi', '--pane', 'opaque-root', '--', '--name',
                 os.environ.get('FAKE_NAME', 'double-holo-12')]
    if mode == 'start-fail':
        sys.exit(1)
    p = next(p for p in s['panes'] if p['pane_id'] == 'opaque-root')
    agent = dict(p, agent='pi', name=a[2], agent_status='done', interactive_ready=True,
                 agent_session={'agent':'pi','source':'herdr:pi','kind':'path','value':'session-new'})
    s['agents'] = [agent]
    save()
    reply('agent_started', agent=agent, argv=['pi', '--name', a[2]])
elif a[:2] == ['agent', 'get']:
    assert a[2] == 'opaque-root'
    if not s['agents']:
        sys.exit(1)
    agent = dict(s['agents'][0])
    if mode in ('welcome', 'dialog', 'welcome-dialog') and not s.get('read'):
        agent.update(agent_status='blocked', interactive_ready=False)
    reply('agent_info', agent=agent)
elif a[:2] == ['agent', 'read']:
    assert a == ['agent', 'read', 'opaque-root', '--source', 'visible', '--lines', '80']
    s['read'] = True
    save()
    text = 'Welcome back!\nPress any key to continue (1s)' if mode == 'welcome' else 'Trust this project? Allow?'
    if mode == 'welcome-dialog':
        text += '\nWelcome back!\nPress any key to continue (1s)'
    reply('pane_read', read={'pane_id':'opaque-root','text':text})
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
        reply('agent_prompted', agent=s['agents'][0])
else:
    raise AssertionError('Forbidden or unknown Herdr operation: ' + repr(a))
'''


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
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
                        HERDR_ENV='1', HERDR_SESSION='intended',
                        HERDR_SOCKET_PATH=str(self.root / 'herdr.sock'),
                        HERDR_PANE_ID='caller-pane', HERDR_WORKSPACE_ID='caller-workspace',
                        FAKE_ROOT=str(self.root), FAKE_REPO=str(self.repo), FAKE_PROMPT=str(self.prompt))
        self.live = self.root / 'live.json'
        self.live.write_text(json.dumps({'version': '0.8.0', 'protocol': 19,
            'workspaces': [], 'agents': [], 'tabs': [], 'layouts': [], 'panes': [{
                'pane_id': 'caller-pane', 'workspace_id': 'caller-workspace',
                'terminal_id': 'caller-terminal'}]}))

    def tearDown(self):
        allowed = {('api','snapshot'), ('workspace','create'), ('workspace','get'),
                   ('agent','start'), ('agent','get'), ('agent','read'), ('agent','prompt')}
        for argv in self.calls():
            self.assertIn(tuple(argv[:2]), allowed, 'focus/approval/kill/close operations are forbidden')
            self.assertTrue({'--focus','--force','--wait'}.isdisjoint(argv))
            if argv[:2] == ['workspace','create']:
                self.assertIn('--no-focus', argv)

    def run_launch(self, mode='', extra=(), env=None):
        return subprocess.run([sys.executable, str(SCRIPT), '--requested', '--project', 'double-holo',
            '--lane', 'W12', '--prompt', str(self.prompt), '--repo', str(self.repo),
            '--state', str(self.state), '--session', 'intended', *extra],
            env=dict(self.env, FAKE_MODE=mode, **(env or {})), text=True, capture_output=True, cwd=self.root, check=False)

    def calls(self):
        p = self.root / 'calls.jsonl'
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def mutations(self, verb):
        return [a for a in self.calls() if a[:2] == verb]

    def test_success_exact_targets_names_and_no_focus_then_reconcile(self):
        result = self.run_launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['stage'], 'Submitted')
        self.assertEqual(receipt['observation'], 'working')
        self.assertIn('Submitted', self.state.read_text())
        self.assertEqual(self.run_launch().returncode, 0)
        for verb in (['workspace', 'create'], ['agent', 'start'], ['agent', 'prompt']):
            self.assertEqual(len(self.mutations(verb)), 1)
        self.assertFalse((self.root / 'SENTINEL').exists())

    def test_override_and_alias_collision(self):
        result = self.run_launch(extra=('--name', 'custom_lane'), env={'FAKE_NAME':'custom_lane'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.receipt.read_text())['name'], 'custom_lane')

    def test_missing_or_mismatched_context_and_missing_prompt_prevent_calls(self):
        for env in ({'HERDR_ENV':''}, {'HERDR_SESSION':'wrong'}, {'HERDR_PANE_ID':''}, {'HERDR_SOCKET_PATH':''}):
            with self.subTest(env=env):
                self.assertNotEqual(self.run_launch(env=env).returncode, 0)
                self.assertEqual(self.calls(), [])
        self.prompt.unlink()
        self.assertNotEqual(self.run_launch().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_live_collision_or_wrong_caller_prevents_creation(self):
        initial = json.loads(self.live.read_text())
        for field, value in [('workspaces', [{'label':'double-holo-12','workspace_id':'other'}]),
                             ('agents', [{'name':'double-holo-12','pane_id':'other'}]),
                             ('panes', [])]:
            with self.subTest(field=field):
                self.live.write_text(json.dumps(dict(initial, **{field:value})))
                self.assertNotEqual(self.run_launch().returncode, 0)
                self.assertEqual(self.mutations(['workspace', 'create']), [])

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

    def test_real_dialog_stops(self):
        self.assertNotEqual(self.run_launch('dialog').returncode, 0)
        self.assertEqual(self.mutations(['agent','prompt']), [])

    def test_real_dialog_with_stale_welcome_text_stops(self):
        self.assertNotEqual(self.run_launch('welcome-dialog').returncode, 0)
        self.assertEqual(self.mutations(['agent','prompt']), [])

    def test_state_existing_launch_without_receipt_prevents_creation(self):
        self.state.write_text(self.state.read_text().replace('Manual', 'old-workspace / old-pane; Submitted'))
        self.assertNotEqual(self.run_launch().returncode, 0)
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
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(sys, 'argv', argv), \
                mock.patch.object(module.subprocess, 'run', side_effect=timeout_after_delivery), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(module.main(), 2)
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
                mock.patch.object(module.Launch, 'update_state', side_effect=OSError('state-write-failed')), \
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


if __name__ == '__main__':
    unittest.main()
