"""Local inbox boundary and one-shot status contracts; no live Herdr mutations."""
import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / 'ai/marketplace/plugins/my/skills/lane-coordinator/scripts/messages.py'


def note(identifier='m1', role='lane', name='sample-7'):
    return {'version': 1, 'id': identifier, 'created_at': '2026-11-15T12:00:00+00:00',
            'sender': {'project': 'sample', 'role': 'coordinator', 'name': 'sample-coord', 'host': 'local'},
            'recipient': {'project': 'sample', 'role': role, 'name': name, 'host': 'local'},
            'category': 'coordinator-instruction', 'body': 'Read the updated scope before publishing.',
            'prompt_sha256': hashlib.sha256(b'approved prompt').hexdigest() if role == 'lane' else None,
            'supersedes': None, 'decision': None}


class MessagesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / 'sample-local'
        self.root.mkdir()
        self.source = self.base / 'input.json'
        self.prompt = self.base / 'prompt.md'
        self.prompt.write_text('approved prompt')
        self.env = os.environ.copy()

    def run_cli(self, command, *args):
        return subprocess.run([sys.executable, str(SCRIPT), command, '--root', str(self.root),
                               '--project', 'sample', *map(str, args)],
                              capture_output=True, text=True, env=self.env, timeout=10, check=False)

    def publish(self, value):
        self.source.write_text(json.dumps(value))
        return self.run_cli('publish', '--note', self.source)

    def inbox(self, *args):
        return self.run_cli('inbox', '--role', 'lane', '--name', 'sample-7', '--host', 'local',
                            '--prompt', self.prompt, *args)

    def assert_rejected(self, result, reason):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stderr + result.stdout)
        self.assertNotIn('Traceback', result.stderr)

    def test_published_bytes_and_content_hash_are_preserved(self):
        result = self.publish(note())
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.source.read_bytes()
        self.assertEqual((self.root / 'reports/inbox/m1.json').read_bytes(), data)
        result = self.inbox()
        self.assertEqual(result.returncode, 0, result.stderr)
        item, = json.loads(result.stdout)['notes']
        self.assertEqual(item['note'], note())
        self.assertEqual(item['sha256'], hashlib.sha256(data).hexdigest())

    def test_existing_id_is_never_overwritten(self):
        self.assertEqual(self.publish(note()).returncode, 0)
        changed = note()
        changed['body'] = 'different'
        self.assert_rejected(self.publish(changed), 'exists')
        self.assertEqual(json.loads((self.root / 'reports/inbox/m1.json').read_text()), note())

    def test_concurrent_publish_has_one_complete_winner(self):
        self.source.write_text(json.dumps(note()))
        argv = [sys.executable, str(SCRIPT), 'publish', '--root', str(self.root),
                '--project', 'sample', '--note', str(self.source)]
        processes = [subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(2)]
        for process in processes:
            process.communicate(timeout=10)
        self.assertEqual(sorted(p.returncode for p in processes), [0, 2])
        self.assertEqual(json.loads((self.root / 'reports/inbox/m1.json').read_text()), note())

    def test_missing_inbox_is_empty_without_creating_directories(self):
        result = self.inbox()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'notes': [], 'rejected': []})
        self.assertFalse((self.root / 'reports').exists())

    def test_bad_note_fields_are_rejected_before_publication(self):
        cases = [('id', '../escape', 'id'), ('category', 'urgent', 'category'),
                 ('created_at', 'yesterday', 'timestamp'), ('version', True, 'version'),
                 ('prompt_sha256', None, 'prompt_sha256'), ('body', '', 'body'),
                 ('decision', {'verbatim': 'yes'}, 'decision')]
        for key, value, reason in cases:
            with self.subTest(key=key):
                value_note = note()
                value_note[key] = value
                self.assert_rejected(self.publish(value_note), reason)
        self.assertFalse((self.root / 'reports/inbox/m1.json').exists())

    def test_decision_requires_verbatim_timestamp_and_source(self):
        value = note()
        value['category'] = 'tom-decision'
        self.assert_rejected(self.publish(value), 'decision')
        for key in ('verbatim', 'timestamp', 'source'):
            value['decision'] = {'verbatim': 'Proceed with the approved scope.',
                                 'timestamp': '2026-11-15T12:00:00Z', 'source': '/private/session.jsonl#entry-123'}
            value['decision'].pop(key)
            self.assert_rejected(self.publish(value), key)
        value['decision'] = {'verbatim': 'Proceed with the approved scope.',
                             'timestamp': '2026-11-15T12:00:00Z', 'source': '/private/session.jsonl#entry-123'}
        self.assertEqual(self.publish(value).returncode, 0)

    def test_cross_coordinator_notes_are_advisory_only(self):
        value = note(role='coordinator', name='sample-coord')
        value['sender']['project'] = 'other'
        self.assert_rejected(self.publish(value), 'cross-project')
        value['category'] = 'fyi'
        self.assertEqual(self.publish(value).returncode, 0)
        lane = note('m2')
        lane['sender']['project'] = 'other'
        lane['category'] = 'fyi'
        self.assert_rejected(self.publish(lane), 'cross-project')

    def test_foreign_project_recipient_cannot_publish(self):
        value = note()
        value['recipient']['project'] = 'other'
        self.assert_rejected(self.publish(value), 'project')
        self.assertFalse((self.root / 'reports/inbox/m1.json').exists())

    def test_wrong_recipient_is_not_returned_and_stale_prompt_is_rejected(self):
        self.assertEqual(self.publish(note()).returncode, 0)
        other = note('m2', name='sample-8')
        self.assertEqual(self.publish(other).returncode, 0)
        self.prompt.write_text('changed')
        result = self.inbox()
        self.assert_rejected(result, 'prompt hash')
        result = json.loads(result.stdout)
        self.assertEqual(result['notes'], [])
        self.assertEqual([r['id'] for r in result['rejected']], ['m1'])

    def test_supersession_requires_existing_same_recipient(self):
        value = note('m2')
        value['supersedes'] = 'm1'
        self.assert_rejected(self.publish(value), 'predecessor')
        self.assertEqual(self.publish(note()).returncode, 0)
        wrong = copy.deepcopy(value)
        wrong['recipient']['name'] = 'sample-8'
        self.assert_rejected(self.publish(wrong), 'recipient')
        self.assertEqual(self.publish(value).returncode, 0)
        result = json.loads(self.inbox().stdout)
        self.assertEqual([n['note']['id'] for n in result['notes']], ['m1', 'm2'])
        self.assertEqual(result['notes'][0]['superseded_by'], ['m2'])

    def test_advisory_or_foreign_sender_cannot_supersede_a_human_decision(self):
        decision = note('d1', role='coordinator', name='sample-coord')
        decision['category'] = 'tom-decision'
        decision['decision'] = {'verbatim': 'Keep the approved scope.',
                                'timestamp': '2026-11-15T12:00:00Z', 'source': '/private/session#entry'}
        self.assertEqual(self.publish(decision).returncode, 0)
        advisory = note('f1', role='coordinator', name='sample-coord')
        advisory.update(category='fyi', supersedes='d1')
        for project in ('other', 'sample'):
            with self.subTest(project=project):
                advisory['sender']['project'] = project
                self.assert_rejected(self.publish(advisory), 'sender/category')
        other_sender = copy.deepcopy(decision)
        other_sender.update(id='d3', supersedes='d1')
        other_sender['sender']['name'] = 'another-coord'
        self.assert_rejected(self.publish(other_sender), 'sender/category')
        replacement = copy.deepcopy(decision)
        replacement.update(id='d2', supersedes='d1')
        self.assertEqual(self.publish(replacement).returncode, 0)

    def test_symlink_and_oversize_inputs_cannot_publish(self):
        self.source.write_text(json.dumps(note()))
        link = self.base / 'link.json'
        link.symlink_to(self.source)
        self.assert_rejected(self.run_cli('publish', '--note', link), 'regular')
        self.source.write_bytes(b' ' * 65537)
        self.assert_rejected(self.run_cli('publish', '--note', self.source), '64 KiB')
        (self.root / 'reports').symlink_to(self.base)
        self.assert_rejected(self.publish(note()), 'symlink')
        self.assertFalse((self.base / 'inbox/m1.json').exists())

    def test_nonregular_note_is_rejected_without_waiting_for_a_writer(self):
        os.mkfifo(self.source)
        self.assert_rejected(self.run_cli('publish', '--note', self.source), 'regular')

    def test_deeply_nested_json_has_normal_error_instead_of_traceback(self):
        self.source.write_text('[' * 2000 + ']' * 2000)
        self.assert_rejected(self.run_cli('publish', '--note', self.source), 'messages:')

    def test_malformed_nested_fields_never_traceback(self):
        for field in ('sender', 'recipient', 'decision', 'created_at'):
            value = note()
            value[field] = []
            self.assert_rejected(self.publish(value), 'messages:')
        self.assertEqual(self.publish(note()).returncode, 0)
        (self.root / 'reports/inbox/broken.json').write_text('null')
        self.assert_rejected(self.inbox(), 'note fields')

    def test_symlinked_note_cannot_be_read(self):
        self.assertEqual(self.publish(note()).returncode, 0)
        path = self.root / 'reports/inbox/m2.json'
        path.symlink_to(self.source)
        self.assert_rejected(self.inbox(), 'regular')

    def status_fixture(self, workspaces, protocol=22, version='0.9.5'):
        fake = self.base / 'herdr'
        fake.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                        'assert sys.argv[1:] == ["api", "snapshot"]\n'
                        f'print({json.dumps(json.dumps({"result": {"type": "session_snapshot", "snapshot": {"protocol": protocol, "version": version, "workspaces": workspaces}}}))})\n')
        fake.chmod(0o700)
        self.env['PATH'] = str(self.base) + os.pathsep + self.env['PATH']

    def test_status_filters_projects_and_live_state_beats_stale_ready(self):
        (self.base / 'sample-extra-local').mkdir()
        rows = [{'workspace_id': f'w{i}', 'label': label, 'agent_status': state,
                 'tokens': {'phase': phase}} for i, (label, state, phase) in enumerate([
                     ('sample-7', 'working', 'ready'), ('sample-8', 'blocked', 'ready'),
                     ('sample-9', 'idle', 'ready'), ('sample-10', 'unknown', 'ready'),
                     ('sample-coord', 'done', None), ('sample-extra-7', 'idle', 'ready'),
                     ('foreign-7', 'blocked', None), ('◆ sample', 'idle', None)])]
        self.status_fixture(rows)
        result = self.run_cli('status')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertIn('observed_at', data)
        self.assertEqual([(r['label'], r['attention']) for r in data['lanes']], [
            ('sample-7', 'working'), ('sample-8', 'needs-decision'), ('sample-9', 'ready'),
            ('sample-10', 'unknown'), ('sample-coord', 'done')])
        self.assertNotIn('foreign', result.stdout)

    def test_status_includes_explicit_receipt_label_not_foreign_receipts(self):
        directory = self.root / 'lanes'
        directory.mkdir()
        receipt = {'project': 'sample', 'lane': 'W7', 'name': 'custom-worker',
                   'state': str(self.root / 'STATE.md'), 'workspace': 'w7'}
        (directory / 'W7-launch.json').write_text(json.dumps(receipt))
        self.status_fixture([{'workspace_id': 'w7', 'label': 'custom-worker', 'agent_status': 'idle'}])
        result = self.run_cli('status')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['lanes'][0]['label'], 'custom-worker')
        receipt['project'] = 'foreign'
        (directory / 'W7-launch.json').write_text(json.dumps(receipt))
        self.assertEqual(json.loads(self.run_cli('status').stdout)['lanes'], [])

    def test_relative_root_retains_custom_labels(self):
        directory = self.root / 'lanes'
        directory.mkdir()
        (directory / 'W7-launch.json').write_text(json.dumps({
            'project': 'sample', 'name': 'custom-worker', 'workspace': 'w7',
            'state': str(self.root / 'STATE.md')}))
        self.status_fixture([{'workspace_id': 'w7', 'label': 'custom-worker', 'agent_status': 'idle'}])
        result = subprocess.run([sys.executable, str(SCRIPT), 'status', '--root', 'sample-local',
                                 '--project', 'sample'], cwd=self.base, env=self.env,
                                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r['label'] for r in json.loads(result.stdout)['lanes']], ['custom-worker'])

    def test_pending_launch_does_not_hide_existing_lane_status(self):
        directory = self.root / 'lanes'
        directory.mkdir()
        (directory / 'W7-launch.json').write_text(json.dumps({
            'project': 'sample', 'name': 'custom-worker', 'stage': 'Creating',
            'state': str(self.root / 'STATE.md')}))
        self.status_fixture([{'workspace_id': 'w8', 'label': 'sample-8', 'agent_status': 'working'}])
        result = self.run_cli('status')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual([r['label'] for r in data['lanes']], ['sample-8'])
        self.assertEqual(data['unresolved_launches'], [{'label': 'custom-worker', 'stage': 'Creating'}])

    def test_status_unknown_protocol_malformed_or_offline_never_means_empty_success(self):
        for protocol, version, rows in [(999, '0.9.5', []), (22, 'future', []),
                                        (22, '0.9.5', None), (22, '0.9.5', [None]),
                                        (22, '0.9.5', [{'label': 'sample-7'}])]:
            with self.subTest(protocol=protocol, version=version, rows=rows):
                self.status_fixture(rows, protocol, version)
                self.assert_rejected(self.run_cli('status'), 'unknown')
        (self.base / 'herdr').write_text('#!/bin/sh\nexit 1\n')
        self.assert_rejected(self.run_cli('status'), 'unknown')

    def test_help_unknown_flag_and_malformed_input_are_noninteractive(self):
        result = self.run_cli('--help')
        self.assertEqual(result.returncode, 0)
        self.assertIn('status', result.stdout)
        self.assert_rejected(self.inbox('--typo'), 'unrecognized arguments')
        self.source.write_text('{')
        self.assert_rejected(self.run_cli('publish', '--note', self.source), 'JSON')


if __name__ == '__main__':
    unittest.main()
