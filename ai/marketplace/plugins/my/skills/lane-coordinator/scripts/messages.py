#!/usr/bin/env python3
"""Local immutable notes and read-only attention; never executes a note or sends input."""
import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


class MessageError(ValueError):
    pass


def token(value, label):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}', value):
        raise MessageError(f'Invalid {label}')
    return value


def text(value, label):
    if not isinstance(value, str) or not value.strip():
        raise MessageError(f'Missing {label}')
    return value


def timestamp(value):
    try:
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            raise ValueError()
    except (TypeError, ValueError):
        raise MessageError('Invalid timestamp; include a timezone') from None


def party(value):
    if not isinstance(value, dict) or set(value) != {'project', 'role', 'name', 'host'}:
        raise MessageError('Invalid sender/recipient')
    for key in ('project', 'name', 'host'):
        token(value[key], key)
    if value['role'] not in ('lane', 'coordinator'):
        raise MessageError('Invalid role')


def validate(note):
    fields = {'version', 'id', 'created_at', 'sender', 'recipient', 'category', 'body',
              'prompt_sha256', 'supersedes', 'decision'}
    if not isinstance(note, dict) or set(note) != fields:
        raise MessageError('Invalid note fields')
    if type(note['version']) is not int or note['version'] != 1:
        raise MessageError('Unsupported note version')
    token(note['id'], 'id')
    timestamp(note['created_at'])
    party(note['sender'])
    party(note['recipient'])
    category = note['category']
    if category not in ('tom-decision', 'coordinator-instruction', 'fyi'):
        raise MessageError('Invalid category')
    if category == 'coordinator-instruction' and note['sender']['role'] != 'coordinator':
        raise MessageError('coordinator-instruction requires coordinator sender')
    if note['sender']['project'] != note['recipient']['project'] and not (
            category == 'fyi' and note['sender']['role'] == note['recipient']['role'] == 'coordinator'):
        raise MessageError('Only advisory coordinator-to-coordinator cross-project notes are allowed')
    text(note['body'], 'body')
    prompt_hash = note['prompt_sha256']
    if note['recipient']['role'] == 'lane':
        if not isinstance(prompt_hash, str) or not re.fullmatch('[a-f0-9]{64}', prompt_hash):
            raise MessageError('Lane note requires prompt_sha256')
    elif prompt_hash is not None:
        raise MessageError('Coordinator prompt_sha256 must be null')
    if note['supersedes'] is not None:
        token(note['supersedes'], 'supersedes')
    decision = note['decision']
    if category == 'tom-decision':
        if not isinstance(decision, dict) or set(decision) != {'verbatim', 'timestamp', 'source'}:
            raise MessageError('decision requires verbatim, timestamp and source')
        text(decision['verbatim'], 'verbatim')
        text(decision['source'], 'source')
        timestamp(decision['timestamp'])
    elif decision is not None:
        raise MessageError('Only tom-decision may contain decision provenance')


def read_note(path):
    # Refuse symlinks/non-regular files and bound reads before parsing local input.
    if path.is_symlink():
        raise MessageError('Note must be a regular file, not a symlink')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise MessageError('Note must be a regular file')
        data = stream.read(65537)
    if len(data) > 65536:
        raise MessageError('Note exceeds 64 KiB')
    try:
        note = json.loads(data)
    except (ValueError, UnicodeError, RecursionError):
        raise MessageError('Invalid note JSON') from None
    validate(note)
    return note, data


def inbox_path(root, create=False):
    if not root.is_dir():
        raise MessageError('Project root must exist')
    path = root
    for part in ('reports', 'inbox'):
        path = path / part
        if path.is_symlink():
            raise MessageError('Inbox directory must not be a symlink')
        if create:
            path.mkdir(mode=0o700, exist_ok=True)
        if path.exists() and not path.is_dir():
            raise MessageError('Inbox path is not a directory')
    return path


def predecessor(directory, note):
    prior = note['supersedes']
    if prior is None:
        return
    path = directory / f'{prior}.json'
    if not path.exists():
        raise MessageError('Missing supersession predecessor')
    previous, _ = read_note(path)
    if previous['id'] != prior or previous['recipient'] != note['recipient']:
        raise MessageError('Supersession predecessor recipient differs')
    if previous['sender'] != note['sender'] or previous['category'] != note['category']:
        raise MessageError('Supersession predecessor sender/category differs')


def publish(root, project, source):
    note, data = read_note(source)
    if note['recipient']['project'] != project:
        raise MessageError('Recipient project differs from explicit project')
    directory = inbox_path(root, create=True)
    predecessor(directory, note)
    destination = directory / f"{note['id']}.json"
    fd, temporary = tempfile.mkstemp(prefix='.note-', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        # Link publishes complete bytes atomically and, unlike replace, cannot clobber an ID.
        try:
            os.link(temporary, destination)
        except FileExistsError:
            raise MessageError('Message ID already exists; inspect it, never overwrite') from None
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        os.unlink(temporary)
    return {'path': str(destination), 'sha256': hashlib.sha256(data).hexdigest()}


def entries(directory):
    try:
        return sorted(directory.iterdir())
    except FileNotFoundError:
        return []


def inbox(root, recipient, prompt):
    directory = inbox_path(root)
    expected_hash = None
    if recipient['role'] == 'lane':
        if prompt is None:
            raise MessageError('Lane inbox requires --prompt')
        expected_hash = hashlib.sha256(prompt.read_bytes()).hexdigest()
    notes, rejected = [], []
    for path in entries(directory):
        if path.suffix != '.json':
            continue
        try:
            note, data = read_note(path)
            if note['id'] != path.stem:
                raise MessageError('Message id differs from filename')
            if note['recipient'] != recipient:
                continue
            predecessor(directory, note)
            if note['prompt_sha256'] != expected_hash:
                raise MessageError('Current prompt hash differs; reject and request a new note')
            notes.append({'note': note, 'sha256': hashlib.sha256(data).hexdigest()})
        except (MessageError, OSError) as exc:
            rejected.append({'id': path.stem, 'error': str(exc)})
    for item in notes:
        item['superseded_by'] = [other['note']['id'] for other in notes
                                 if other['note']['supersedes'] == item['note']['id']]
    return {'notes': notes, 'rejected': rejected}


def status(root, project):
    """One snapshot; no agent input, remote transport or readiness/CI assertion."""
    try:
        completed = subprocess.run(['herdr', 'api', 'snapshot'], capture_output=True,
                                   text=True, timeout=10, check=True)
        result = json.loads(completed.stdout)['result']
        live = result['snapshot']
        if result['type'] != 'session_snapshot' or not (
                type(live['protocol']) is int and (live['protocol'] == 19 or (
                    live['protocol'] == 22 and live['version'] == '0.9.5'))):
            raise ValueError()
        rows = live['workspaces']
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise ValueError()
        # Conventional labels use longest project-prefix ownership, like the dashboard.
        projects = {project} | {p.name[:-6] for p in entries(root.parent)
                                if p.name.endswith('-local') and p.is_dir()}
        owned, unresolved = {}, []
        for path in entries(root / 'lanes'):
            if not path.name.endswith('-launch.json'):
                continue
            record = json.loads(path.read_bytes())
            if record.get('project') == project and record.get('state') == str(root / 'STATE.md'):
                name = token(record['name'], 'name')
                if 'workspace' not in record:
                    unresolved.append({'label': name, 'stage': record.get('stage', 'unknown')})
                else:
                    owned[name] = text(record['workspace'], 'workspace')
        lanes = []
        for row in rows:
            label = row['label']
            owner = max((p for p in projects if label == p or label.startswith(p + '-')),
                        key=len, default=None)
            if not ((owner == project and re.fullmatch(re.escape(project) + r'-(coord|[0-9]+)', label))
                    or owned.get(label) == row.get('workspace_id') and label in owned):
                continue
            state = row['agent_status']
            if state not in ('idle', 'done', 'working', 'blocked', 'unknown'):
                raise ValueError()
            tokens = row.get('tokens') or {}
            phase = tokens.get('phase')
            attention = ('needs-decision' if state == 'blocked' else
                         'working' if state == 'working' else
                         'unknown' if state == 'unknown' else
                         'needs-decision' if phase == 'needs-decision' else
                         'ready' if phase == 'ready' else state)
            lanes.append({'label': label, 'workspace': text(row['workspace_id'], 'workspace'),
                          'agent_status': state, 'phase': phase, 'attention': attention})
            if owned.get(label) == row['workspace_id']:
                del owned[label]
        unresolved.extend({'label': label, 'workspace': workspace, 'stage': 'unobserved'}
                          for label, workspace in owned.items())
        return {'observed_at': datetime.now(timezone.utc).isoformat(),
                'lanes': lanes, 'unresolved_launches': unresolved}
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError,
            subprocess.SubprocessError):
        raise MessageError('Project attention unknown; inspect Herdr snapshot and ownership evidence') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('publish', 'inbox', 'status'):
        sub = commands.add_parser(command)
        sub.add_argument('--root', required=True, type=Path, help='Explicit receiving project folder')
        sub.add_argument('--project', required=True, help='Exact project slug; not inferred from root name')
        if command == 'publish':
            sub.add_argument('--note', required=True, type=Path, help='Complete version-1 JSON note')
        if command == 'inbox':
            sub.add_argument('--role', required=True, choices=('lane', 'coordinator'))
            sub.add_argument('--name', required=True)
            sub.add_argument('--host', required=True)
            sub.add_argument('--prompt', type=Path)
    args = parser.parse_args()
    try:
        token(args.project, 'project')
        args.root = args.root.resolve(strict=True)
        if args.command == 'publish':
            result = publish(args.root, args.project, args.note)
        elif args.command == 'inbox':
            recipient = {'project': args.project, 'role': args.role, 'name': args.name, 'host': args.host}
            party(recipient)
            result = inbox(args.root, recipient, args.prompt)
        else:
            result = status(args.root, args.project)
        print(json.dumps(result))
        return 2 if result.get('rejected') else 0
    except (MessageError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f'messages: {exc}; inspect inputs before continuing', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
