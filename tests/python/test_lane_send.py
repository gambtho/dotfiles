"""Guarded sends use real receipts/files and a fixture Herdr, never live pane input."""
import copy
import importlib.util
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
SKILL = ROOT / 'ai/marketplace/plugins/my/skills/lane-coordinator'
SCRIPT = SKILL / 'scripts/send.py'
PI = 'GPT | think:med | dir sample\n── smart ───────────────────\n\n───────────────────────────\n ↳ last request\n'
CLAUDE = 'Claude Code\n───────────────────────────\n❯\n───────────────────────────\n  auto mode on\n'
FAKE = r'''#!/usr/bin/env python3
import fcntl,json,os,signal,sys
from pathlib import Path
root=Path(os.environ['FAKE_ROOT']); a=sys.argv[1:]; mode=os.environ.get('MODE','')
lock=(root/'live.lock').open('a'); fcntl.flock(lock,fcntl.LOCK_EX)
s=json.loads((root/'live.json').read_text())
with (root/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
def reply(kind, **fields): print(json.dumps({'result':dict(type=kind,**fields)}))
if a==['api','snapshot']:
    n=s.get('snapshots',0)+1; s['snapshots']=n
    if n==2 and mode=='race-busy': s['agents'][1]['agent_status']='working'
    if n==2 and mode=='race-session': s['agents'][1]['agent_session']['value']='replaced'
    (root/'live.json').write_text(json.dumps(s)); reply('session_snapshot',snapshot=s)
elif a[:2]==['agent','get']:
    reply('agent_info',agent=next(x for x in s['agents'] if x['pane_id']==a[2]))
elif a[:2]==['agent','read']:
    assert a[3:] in (['--source','visible','--lines','80','--format','text'],
                     ['--source','visible','--format','text'])
    if mode=='change-note':
        p=root/'reports/inbox/m1.json'; p.write_text(p.read_text()+' ')
    screen=os.environ['SCREEN']
    if '--lines' in a: screen='\n'.join(screen.splitlines()[-80:])
    print(screen)
elif a[:2]==['agent','prompt']:
    record=json.loads((root/'reports/inbox/delivery/m1.json').read_text())
    assert record['stage']=='submitting' and record['attempts']==1
    assert a[2]==s['agents'][1]['pane_id']
    assert 'body secret' not in a[3] and 'm1' in a[3]
    (root/'delivered').write_text(a[3])
    if mode=='crash': os.kill(os.getppid(),signal.SIGKILL); sys.exit(0)
    if mode=='error':
        print(json.dumps({'error':{'code':'agent_prompt_failed','message':'DO NOT LOG'}}),file=sys.stderr); sys.exit(1)
    if mode=='malformed': print('{}')
    else: reply('agent_prompted',agent=s['agents'][1])
else: raise AssertionError(a)
'''


class SendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(str(self.root / 'herdr.sock'))
        self.addCleanup(self.sock.close)
        (self.root / 'lanes').mkdir()
        (self.root / 'reports/inbox').mkdir(parents=True)
        self.prompt = self.root / 'lanes/W7.md'
        self.prompt.write_text('current approved prompt')
        self.state = self.root / 'STATE.md'
        self.state.write_text('| W7 | Work | Active | None | receipt |\n')
        self.ownership = self.root / 'lanes/W7-launch.json'
        self.note = self.root / 'reports/inbox/m1.json'
        self.receipt = self.root / 'reports/inbox/delivery/m1.json'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'herdr').write_text(FAKE)
        (self.bin / 'herdr').chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        FAKE_ROOT=str(self.root), HERDR_ENV='1', HERDR_SESSION='default',
                        HERDR_SOCKET_PATH=str(self.root/'herdr.sock'))
        self.configure()

    def configure(self, target_kind='pi', direction='forward', manual=False):
        def agent(kind, role):
            return dict(agent=kind, agent_session=dict(agent=kind, source='herdr:'+kind, kind='id', value=role),
                        pane_id=role, workspace_id='ws-'+role, terminal_id='term-'+role,
                        foreground_cwd=str(self.root), agent_status='idle')
        caller = agent('claude', 'coord')
        child = agent('pi' if direction=='reverse' else target_kind, 'lane')
        if direction=='reverse':
            caller['agent'] = target_kind
            caller['agent_session']['agent'] = target_kind
            caller['agent_session']['source'] = 'herdr:'+target_kind
        caller_pin = dict(caller, label='sample-coord')
        record = dict(version=2, project='sample', lane='W7', name='sample-7', repo=str(self.root),
                      state=str(self.state), prompt=str(self.prompt), prompt_sha256='historical',
                      workspace=child['workspace_id'], pane=child['pane_id'], terminal=child['terminal_id'],
                      agent_session=child['agent_session'], caller_agent=caller_pin,
                      context=dict(session='default', socket=str(self.root/'herdr.sock'),
                                   socket_device=(self.root/'herdr.sock').stat().st_dev,
                                   socket_inode=(self.root/'herdr.sock').stat().st_ino,
                                   caller='coord', workspace='ws-coord', terminal='term-coord'))
        self.ownership.write_text(json.dumps(record))
        source, target = (child, caller) if direction=='reverse' else (caller, child)
        if not manual:
            target['interactive_ready'] = True
        self.env.update(HERDR_PANE_ID=source['pane_id'], HERDR_WORKSPACE_ID=source['workspace_id'],
                        SCREEN=PI if target['agent']=='pi' else CLAUDE)
        self.live: dict = dict(protocol=22, version='0.9.5',
                         agents=[source, target],
                         panes=[dict(pane_id=a['pane_id'], workspace_id=a['workspace_id'], terminal_id=a['terminal_id'])
                                for a in (caller, child)],
                         workspaces=[dict(workspace_id='ws-coord', label='sample-coord'),
                                     dict(workspace_id='ws-lane', label='sample-7')])
        self.save_live()
        import hashlib
        value = dict(version=1, id='m1', created_at='2026-11-15T12:00:00Z', category='fyi',
                     sender=dict(project='sample', role='lane' if direction=='reverse' else 'coordinator',
                                 name='sample-7' if direction=='reverse' else 'sample-coord', host='local'),
                     recipient=dict(project='sample', role='coordinator' if direction=='reverse' else 'lane',
                                    name='sample-coord' if direction=='reverse' else 'sample-7', host='local'),
                     body='body secret', decision=None, supersedes=None,
                     prompt_sha256=None if direction=='reverse' else hashlib.sha256(self.prompt.read_bytes()).hexdigest())
        self.note.write_text(json.dumps(value))

    def save_live(self):
        (self.root/'live.json').write_text(json.dumps(self.live))

    def command(self, inspect=False):
        return [sys.executable, str(SCRIPT), '--root', str(self.root), '--project', 'sample',
                '--host', 'local', '--session', 'default', '--ownership', str(self.ownership),
                '--note', str(self.note), *(['--inspect'] if inspect else [])]

    def run_send(self, mode='', inspect=False):
        return subprocess.run(self.command(inspect),
                              capture_output=True, text=True, timeout=15,
                              env=dict(self.env, MODE=mode), check=False)

    def prompts(self):
        p = self.root/'calls'
        return [json.loads(line) for line in p.read_text().splitlines() if json.loads(line)[:2]==['agent','prompt']] if p.exists() else []

    def assert_no_send(self, result, reason=None):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('Send stopped:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        if reason:
            self.assertIn(reason, result.stderr)
        self.assertEqual(self.prompts(), [])

    def test_both_target_types_and_directions_send_one_pointer(self):
        for kind, direction in [('pi','forward'), ('claude','forward'), ('pi','reverse'), ('claude','reverse')]:
            with self.subTest(kind=kind, direction=direction):
                self.configure(kind,direction,manual=True)
                result = self.run_send()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'submitted')
                self.assertNotIn('body secret', (self.root/'delivered').read_text())
                self.assertIn(str(self.note), (self.root/'delivered').read_text())
                self.assertEqual(self.state.read_text(), '| W7 | Work | Active | None | receipt |\n')
                self.receipt.unlink()
                (self.root/'calls').unlink()

    def test_busy_blocked_unknown_or_explicitly_unready_never_claim(self):
        for status in ('working','blocked','unknown'):
            self.live['agents'][1]['agent_status'] = status
            self.save_live()
            self.assert_no_send(self.run_send(), 'Target busy')
            self.assertFalse(self.receipt.exists())
        self.live['agents'][1].update(agent_status='idle', interactive_ready=False)
        self.save_live()
        self.assert_no_send(self.run_send(), 'Target busy')
        self.live['agents'][1].update(interactive_ready=True, launch_pending=True)
        self.save_live()
        self.assert_no_send(self.run_send(), 'Target busy')

    def test_dialog_welcome_unknown_or_nonempty_editor_never_send(self):
        for screen in ('Permission Required', PI+'\nWelcome back!', 'ordinary shell $', '',
                       PI.replace('\n\n','\npartially typed\n'), CLAUDE.replace('❯','❯ 1. Yes')):
            with self.subTest(screen=screen):
                self.env['SCREEN'] = screen
                self.assert_no_send(self.run_send(), 'unknown visible idle screen')

    def test_tall_viewport_does_not_hide_dialog_above_last_eighty_lines(self):
        self.env['SCREEN'] = 'Permission Required' + '\n'*100 + PI
        self.assert_no_send(self.run_send(), 'unknown visible idle screen')

    def test_wrong_live_identity_never_sends(self):
        original = copy.deepcopy(self.live)
        for key in ('pane_id','workspace_id','terminal_id','agent','agent_session','foreground_cwd'):
            self.live = copy.deepcopy(original)
            self.live['agents'][1][key] = 'wrong'
            self.save_live()
            with self.subTest(key=key):
                self.assert_no_send(self.run_send())
        self.live = original

    def test_wrong_inherited_source_and_foreign_note_never_send(self):
        self.env['HERDR_PANE_ID'] = 'foreign'
        self.assert_no_send(self.run_send())
        self.env['HERDR_PANE_ID'] = 'coord'
        value = json.loads(self.note.read_text())
        for field in ('project','host','name'):
            wrong = copy.deepcopy(value)
            wrong['recipient'][field] = 'foreign'
            self.note.write_text(json.dumps(wrong))
            self.assert_no_send(self.run_send())
        self.assertFalse(self.receipt.exists())

    def test_missing_caller_and_stale_prompt_never_send(self):
        record = json.loads(self.ownership.read_text())
        record.pop('caller_agent')
        self.ownership.write_text(json.dumps(record))
        self.assert_no_send(self.run_send())
        self.configure()
        self.prompt.write_text('amended after note publication')
        self.assert_no_send(self.run_send())

    def test_race_busy_session_or_note_recheck_prevents_mutation(self):
        for mode in ('race-busy','race-session','change-note'):
            with self.subTest(mode=mode):
                self.configure()
                self.assert_no_send(self.run_send(mode))
                if self.receipt.exists(): self.receipt.unlink()

    def test_concurrent_claims_dispatch_at_most_once(self):
        processes = [subprocess.Popen(self.command(), env=dict(self.env, MODE=''),
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(2)]
        for process in processes:
            process.communicate(timeout=15)
        self.assertIn(0, [process.returncode for process in processes])
        self.assertEqual(len(self.prompts()), 1)
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'submitted')

    def test_crash_after_submitting_inspects_without_resending(self):
        self.assertNotEqual(self.run_send('crash').returncode, 0)
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'submitting')
        self.run_send()
        self.assertEqual(len(self.prompts()), 1)

    def test_timeout_after_admission_is_durable_and_never_resends(self):
        sys.path.insert(0, str(SKILL/'scripts'))
        self.addCleanup(sys.path.remove, str(SKILL/'scripts'))
        spec = importlib.util.spec_from_file_location('lane_send_timeout', SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = module.launch.call
        attempts = []
        def timeout(*argv, **kwargs):
            if argv[:2] == ('agent','prompt'):
                self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'submitting')
                attempts.append(argv)
                (self.root/'delivered').write_text('possible delivery')
                raise module.launch.LaunchError('agent prompt timed out; effects uncertain')
            return original(*argv, **kwargs)
        args = module.argparse.Namespace(root=self.root, project='sample', host='local', session='default',
                                         ownership=self.ownership, note=self.note, inspect=False)
        with (mock.patch.dict(os.environ, self.env, clear=True),
              mock.patch.object(module.launch, 'call', side_effect=timeout),
              self.assertRaisesRegex(ValueError, 'timed out')):
            module.send(args)
        self.assertEqual(json.loads(self.receipt.read_text())['stage'], 'uncertain')
        self.run_send()
        self.assertEqual(len(attempts), 1)
        self.assertEqual(self.prompts(), [])

    def test_missing_lane_or_changed_server_session_cannot_send(self):
        self.state.write_text('no active lanes')
        self.assert_no_send(self.run_send())
        self.state.write_text('| W7 | Work | Active | None | receipt |\n')
        self.env['HERDR_SESSION'] = 'another-session'
        self.assert_no_send(self.run_send())

    def test_duplicate_and_uncertain_outcomes_only_inspect_even_after_receipt_checkpoint_changes(self):
        for mode in ('','malformed','error'):
            with self.subTest(mode=mode):
                self.configure()
                first = self.run_send(mode)
                self.assertEqual(first.returncode, 0 if not mode else 2, first.stderr)
                record = json.loads(self.receipt.read_text())
                self.assertEqual(record['stage'], 'submitted' if not mode else 'uncertain')
                ownership = json.loads(self.ownership.read_text())
                ownership['observation'] = 'done'
                self.ownership.write_text(json.dumps(ownership))
                self.run_send(inspect=True)
                self.run_send()
                self.assertEqual(len(self.prompts()), 1)
                self.assertNotIn('DO NOT LOG', self.receipt.read_text())
                self.receipt.unlink()
                (self.root/'calls').unlink()


if __name__ == '__main__':
    unittest.main()
