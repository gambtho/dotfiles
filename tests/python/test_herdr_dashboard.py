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


def flat(lines):
    out = []
    for segments in lines:
        text = ''
        for x, part, _, _ in segments:
            text = dashboard.pad(text, x) + part
        out.append(text.rstrip())
    return out


class ProjectionTests(unittest.TestCase):
    def test_one_effective_state_with_live_status_over_stale_phase(self):
        states = {'local': state([
            workspace('orchard-12', phase='ready'),
            workspace('orchard-2', 'working', wid='w2', phase='ready'),
            workspace('orchard-3', wid='w3', phase='needs-decision'),
            workspace('orchard-4', 'done', wid='w4'),
            workspace('orchard-5', 'unknown', wid='w5', phase='ready'),
        ]), 'remote': state([workspace('orchard-12', 'blocked', phase='ready')], label='Other')}
        rows = dashboard.project_rows(states)
        self.assertEqual([(r['lane'], r['state']) for r in rows],
                         [('2', 'working'), ('3', 'needs'), ('4', 'review'), ('5', 'shell'), ('12', 'review'), ('12', 'needs')])
        self.assertEqual(len({r['key'] for r in rows}), 6)

    def test_coordinators_are_recognized_only_for_known_projects(self):
        states = {'local': state([
            workspace('orchard-1', wid='w1'), workspace('orchard', wid='w2'), workspace('◆ banana', wid='w3'),
            workspace('banana-local', wid='w4'), workspace('cherry-coord', wid='w5'),
            workspace('scratch-local', wid='w6'), workspace('Projects', wid='w7'), workspace('~', wid='w8')])}
        rows = dashboard.project_rows(states)
        self.assertEqual(sorted((r['project'], r['lane']) for r in rows),
                         [('banana', 'coord'), ('cherry', 'coord'), ('orchard', '1'), ('orchard', 'coord')])
        self.assertNotIn(('local', 'w3'), {r['key'] for r in rows})

    def test_agent_presence_comes_from_panes(self):
        snapshot = dict(workspaces=[workspace('orchard-1', 'unknown', wid='w1'), workspace('orchard-2', 'unknown', wid='w2')],
                        panes=[dict(workspace_id='w1', agent='pi'), dict(workspace_id='w2')])
        rows = dashboard.project_rows({'local': dict(label='Local', snapshot=snapshot, error='')})
        self.assertEqual([r['state'] for r in rows], ['idle', 'shell'])
        with self.assertRaises(ValueError):
            dashboard.validate_snapshot(dict(workspaces=[], panes='nope'))

    def test_strip_lists_attention_then_reported_tasks(self):
        states = {'local': state([
            workspace('orchard-1', 'working', wid='w1'), workspace('orchard-2', 'working', wid='w2', task='Build it'),
            workspace('banana-7', 'blocked', wid='w3'), workspace('orchard-3', wid='w4', phase='ready'),
            workspace('orchard-4', wid='w5')])}
        rows = dashboard.project_rows(states)
        self.assertEqual([dashboard.name(r) for r in dashboard.strip_rows(rows)], ['banana-7', 'orchard-3', 'orchard-2'])
        text = flat(dashboard.board(rows, states, 60))
        self.assertTrue(text[2].startswith('1 ! banana-7  needs you'))
        self.assertTrue(text[3].startswith('2 ✓ orchard-3  ready for review'))
        self.assertTrue(text[4].startswith('3 ● orchard-2  Build it'))

    def test_grid_orders_cells_by_urgency_and_folds_overflow(self):
        states = {'local': state([workspace(f'orchard-{n}', 'working', wid=f'w{n}') for n in range(1, 9)]
                                 + [workspace('orchard', wid='c'), workspace('orchard-20', 'blocked', wid='b')]),
                  'remote': state([workspace('banana-3', wid='r')], label='Other')}
        rows = dashboard.project_rows(states)
        wide = flat(dashboard.board(rows, states, 120, {'empty'}))
        grid = wide[wide.index(next(t for t in wide if 'Local' in t and 'Other' in t)) + 1:]
        self.assertTrue(grid[0].startswith('orchard'))
        self.assertIn('!20 ●1 ●2', grid[0])
        self.assertIn('○◆', grid[0])
        self.assertTrue(grid[1].startswith('banana') and '○3' in grid[1])
        self.assertTrue(grid[2].startswith('empty') and grid[2].count('—') == 2)
        narrow = flat(dashboard.board(rows, states, 40))
        self.assertTrue(any(t.startswith('orchard') and '+' in t for t in narrow))

    def test_board_fits_width_and_marks_offline(self):
        states = {'local': state([workspace('orchard-1', 'working', task='界' * 40)]),
                  'remote': state([workspace('orchard-2', 'blocked', wid='w2')], error='Timed out', label='Other')}
        rows = dashboard.project_rows(states)
        for width in (30, 40, 60, 172):
            with self.subTest(width=width):
                lines = flat(dashboard.board(rows, states, width))
                self.assertTrue(all(dashboard.text_width(t) <= width for t in lines), lines)
        lines = flat(dashboard.board(rows, states, 80))
        self.assertIn('●1 · 1/2 up · Other offline', lines[0])
        self.assertTrue(any(t.startswith('2 ? orchard-2') and t.endswith('Other?') for t in lines))
        self.assertTrue(any('Other ?' in t for t in lines))
        self.assertIn('Other OFFLINE', dashboard.host_summary(states))
        self.assertIn('offline', dashboard.detail(rows[1]))

    def test_arrow_navigation_and_clicks_map_to_lanes(self):
        states = {'local': state([workspace('orchard-1', 'blocked', wid='a'), workspace('orchard-2', 'working', wid='b')]),
                  'remote': state([workspace('orchard-3', 'working', wid='c')], label='Other')}
        lines = dashboard.board(dashboard.project_rows(states), states, 60)
        a, b, c = ('local', 'a'), ('local', 'b'), ('remote', 'c')
        self.assertEqual(dashboard.move(lines, a, 'up'), a)
        grid_a = dashboard.move(lines, a, 'down')
        self.assertEqual(grid_a, a)
        y = next(y for y, _, key in dashboard.selectable(lines) if key == a and y > 2)
        self.assertEqual(dashboard.move(lines, a, 'right'), a)
        row = [key for line_y, _, key in dashboard.selectable(lines) if line_y == y]
        self.assertEqual(row, [a, b, c])
        x = next(x for line_y, x, key in dashboard.selectable(lines) if line_y == y and key == c)
        self.assertEqual(dashboard.hit(lines, y, x), c)
        self.assertIsNone(dashboard.hit(lines, 0, 0))
        self.assertEqual(dashboard.move([lines[0], lines[y]], c, 'left'), b)

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
