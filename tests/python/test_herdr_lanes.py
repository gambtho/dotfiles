"""Fictional boundary tests for the installed project-heading tools."""
import importlib.util
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
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
        self.assertEqual(command, ['cd', str(self.home / 'double-holo-local'), '&&', 'pi', '--', prompt])
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
        self.assertFalse((self.home / '.lane-anchors').exists())
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
