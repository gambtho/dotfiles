import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'tools/herdr/dashboard/dashboard.py'
SPEC = importlib.util.spec_from_file_location('dashboard', SCRIPT)
assert SPEC is not None and SPEC.loader is not None
dashboard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dashboard)


def workspace(label, status='idle', wid='w1', **tokens):
    return dict(label=label, agent_status=status, workspace_id=wid, tokens=tokens)


def state(rows, error='', label='Local'):
    return dict(label=label, snapshot=dict(workspaces=rows), error=error)


class ProjectionTests(unittest.TestCase):
    def test_group_order_endpoint_identity_and_phase_precedence(self):
        states = {'local': state([
            workspace('orchard-12', phase='ready'),
            workspace('orchard-2', 'working', wid='w2', phase='ready'),
            workspace('orchard-coord', wid='w3', phase='needs-decision'),
            workspace('scratch', wid='w4'),
        ]), 'remote': state([workspace('orchard-12', 'blocked', phase='ready')], label='Other')}
        rows = dashboard.project_rows(states)
        self.assertEqual([r['lane'] for r in rows], ['coord', '2', '12', '12'])
        self.assertEqual([r['section'] for r in rows], ['Needs you', 'Working', 'Ready for review', 'Needs you'])
        self.assertEqual(len({r['key'] for r in rows}), 4)

    def test_attention_headers_identify_projects_before_selection(self):
        rows = dashboard.project_rows({'local': state([workspace('orchard-1', 'blocked'), workspace('banana-1', 'blocked', wid='w2')])})
        headers = [text for text, key, style in dashboard.lines_for(rows, 'attention') if key and style == 'Needs you']
        self.assertEqual(len(set(headers)), 2)
        self.assertTrue(any('orchard' in text for text in headers))
        self.assertTrue(any('banana' in text for text in headers))

    def test_offline_cached_rows_excluded_from_live_sections(self):
        states = {'remote': state([workspace('orchard-1', 'blocked')], error='Timed out', label='Other')}
        rows = dashboard.project_rows(states)
        self.assertEqual(rows[0]['section'], 'Offline (cached)')
        self.assertIn('cached blocked', '\n'.join(t[0] for t in dashboard.lines_for(rows, 'attention')))
        states['empty'] = dict(label='Empty', snapshot=None, error='Unavailable')
        self.assertIn('Empty OFFLINE', dashboard.host_summary(states))

    def test_heading_workspaces_are_groups_not_lane_rows_or_focus_targets(self):
        states = {'local': state([workspace('◆ orchard'), workspace('◆ empty', wid='w2'), workspace('orchard-3', wid='w3')])}
        rows = dashboard.project_rows(states)
        self.assertEqual([r['label'] for r in rows], ['orchard-3'])
        lines = dashboard.lines_for(rows, 'projects', dashboard.heading_projects(states))
        self.assertTrue(any(text.startswith('empty ·') and key is None for text, key, _ in lines))
        self.assertTrue(any(text.startswith('orchard ·') and key is None for text, key, _ in lines))
        self.assertEqual({key for _, key, _ in lines if key}, {('local', 'w3')})

    def test_done_visible_and_unknown_not_claimed_complete(self):
        rows = dashboard.project_rows({'local': state([workspace('orchard-1', 'done'), workspace('orchard-2', 'unknown', wid='w2', phase='ready')])})
        self.assertEqual([r['section'] for r in rows], ['Ready for review', 'Idle'])
        self.assertIn('done', '\n'.join(t[0] for t in dashboard.lines_for(rows, 'attention')))
        self.assertEqual(rows[1]['status'], 'unknown')

    def test_invalid_snapshot_is_rejected_not_silently_empty(self):
        for value in ({}, {'workspaces': [{}]}, {'workspaces': [workspace('orchard-1', tokens=42)]}):
            with self.subTest(value=value), self.assertRaises((ValueError, TypeError)):
                dashboard.validate_snapshot(value)

    def test_focus_only_online_local_returned_id(self):
        rows = dashboard.project_rows({'local': state([workspace('orchard-1')]), 'remote': state([workspace('orchard-2')])})
        with patch.object(dashboard.subprocess, 'run') as run:
            run.return_value.returncode = 0
            run.return_value.stderr = ''
            self.assertIn('Focused', dashboard.focus(rows[0]))
            self.assertEqual(run.call_args.args[0], ['herdr', 'workspace', 'focus', 'w1'])
            self.assertIn('Ctrl-B w', dashboard.focus(rows[1]))
            rows[0]['offline'] = True
            self.assertIn('Offline', dashboard.focus(rows[0]))
            self.assertEqual(run.call_count, 1)

    def test_clipping_and_selection_survive_refresh(self):
        self.assertLessEqual(len(dashboard.clip('a\n\x1b' + '界' * 30, 20)), 20)
        self.assertNotIn('\x1b', dashboard.clip('x\x1by', 20))
        self.assertEqual(dashboard.selection(('remote', 'w2'), [('local', 'w1'), ('remote', 'w2')]), ('remote', 'w2'))
        self.assertEqual(dashboard.selection(('gone', 'w1'), [('local', 'w1')]), ('local', 'w1'))


class ReaderTests(unittest.TestCase):
    def wait(self, read):
        deadline = time.monotonic() + 3
        while not read.done() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(read.done())

    def test_pane_signals_reap_owned_readers(self):
        for signum in (signal.SIGHUP, signal.SIGTERM):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                log = root / 'pids'
                fake = root / 'herdr'
                fake.write_text('#!/usr/bin/env python3\nimport os,time\nwith open(' + repr(str(log)) + ', "a") as f: f.write(str(os.getpid()) + "\\n"); f.flush()\ntime.sleep(60)\n')
                fake.chmod(0o755)
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'])
                parent = subprocess.Popen([sys.executable, str(SCRIPT), '--once'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                children = []
                try:
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        if log.exists():
                            children = [int(p) for p in log.read_text().splitlines()]
                        if len(children) == 2:
                            break
                        time.sleep(.01)
                    self.assertEqual(len(children), 2)
                    parent.send_signal(signum)
                    parent.wait(timeout=2)
                    for pid in children:
                        with self.assertRaises(ProcessLookupError):
                            os.kill(pid, 0)
                finally:
                    if parent.poll() is None:
                        parent.kill()
                    parent.communicate(timeout=2)
                    for pid in children:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_once_waits_for_slow_discovery_then_initial_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'herdr'
            payload = json.dumps({'result': {'snapshot': {'workspaces': [workspace('orchard-3', task='late snapshot')]}}})
            fake.write_text('#!/usr/bin/env python3\nimport sys,time\n'
                            'if "machine" in sys.argv:\n time.sleep(5); print(\'[{"id":"abc","label":"Other","enabled":true}]\')\n'
                            'else:\n if "--machine" in sys.argv: time.sleep(5)\n print(' + repr(payload) + ')\n')
            fake.chmod(0o755)
            result = subprocess.run([sys.executable, str(SCRIPT), '--once'], env=dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH']), capture_output=True, text=True, timeout=16, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Other online', result.stdout)
            self.assertNotIn('OFFLINE', result.stdout)

    def test_once_sanitizes_remote_control_characters(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'herdr'
            payload = json.dumps({'result': {'snapshot': {'workspaces': [workspace('orchard-3', task='x' + chr(27) + '[2Jy')]}}})
            fake.write_text('#!/usr/bin/env python3\nimport sys\nprint("[]" if "machine" in sys.argv else ' + repr(payload) + ')\n')
            fake.chmod(0o755)
            result = subprocess.run([sys.executable, str(SCRIPT), '--once'], env=dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH']), capture_output=True, text=True, timeout=3, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(chr(27), result.stdout)
            self.assertIn('orchard', result.stdout)

    def test_profile_changes_remove_disabled_hosts_and_preserve_local(self):
        view = dashboard.Dashboard()
        self.addCleanup(view.close)
        view.reconcile([dict(id='abc', label='Other', enabled=True)])
        view.reconcile([dict(id='abc', label='Renamed', enabled=True)])
        self.assertEqual(view.states['abc']['label'], 'Renamed')
        with self.assertRaises(ValueError):
            view.reconcile([dict(id='abc', label=None, enabled=True)])
        self.assertIn('abc', view.states)
        view.reconcile([dict(id='abc', label='Other', enabled=False)])
        self.assertEqual(list(view.states), ['local'])

    def test_real_process_json_error_and_prompt_cancellation(self):
        good = dashboard.Read([sys.executable, '-c', 'print("{\\"ok\\": 1}")'])
        self.addCleanup(good.close)
        self.wait(good)
        self.assertEqual(good.result(), {'ok': 1})
        bad = dashboard.Read([sys.executable, '-c', 'print("not json")'])
        self.addCleanup(bad.close)
        self.wait(bad)
        with self.assertRaises(ValueError):
            bad.result()
        hung = dashboard.Read([sys.executable, '-c', 'import time; time.sleep(60)'])
        self.addCleanup(hung.close)
        other = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
        self.addCleanup(lambda: (other.terminate(), other.wait()))
        started = time.monotonic()
        hung.close()
        self.assertLess(time.monotonic() - started, 1)
        self.assertIsNotNone(hung.process.poll())
        self.assertIsNone(other.poll())

    def test_discovery_polling_cache_failure_and_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'herdr'
            payload = Path(directory) / 'reply'
            payload.write_text(json.dumps({'result': {'snapshot': {'workspaces': [workspace('orchard-3')]}}}))
            fake.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\nif "machine" in sys.argv:\n print(\'[{' + '"id":"abc","label":"Other","enabled":true' + '}]\')\nelse:\n print(Path(' + repr(str(payload)) + ').read_text())\n')
            fake.chmod(0o755)
            view = dashboard.Dashboard(str(fake))
            self.addCleanup(view.close)

            def until(predicate):
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    view.tick()
                    if predicate():
                        return
                    time.sleep(.01)
                self.fail('polling did not converge')

            until(lambda: 'abc' in view.states and view.states['abc']['snapshot'] is not None)
            self.assertEqual(len(dashboard.project_rows(view.states)), 2)
            payload.write_text('broken')
            view.refresh()
            until(lambda: bool(view.states['abc']['error']))
            self.assertEqual(view.states['abc']['snapshot']['workspaces'][0]['label'], 'orchard-3')
            payload.write_text(json.dumps({'result': {'snapshot': {'workspaces': []}}}))
            view.refresh()
            until(lambda: not view.states['abc']['error'])
            self.assertEqual(view.states['abc']['snapshot']['workspaces'], [])


if __name__ == '__main__':
    unittest.main()
