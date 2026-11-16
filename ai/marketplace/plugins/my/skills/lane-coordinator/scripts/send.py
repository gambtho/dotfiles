#!/usr/bin/env python3
"""Send one local note pointer to an idle owned agent; existing receipts inspect only."""
import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import launch
import messages


def load(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise launch.LaunchError('Ownership/delivery evidence must be a regular file <=64 KiB')
    data = path.read_bytes()
    return launch.mapping(json.loads(data), 'evidence'), data


def matches(pin, agent):
    current = launch.agent_identity(agent, pin['label'])
    if any(current.get(key) != value for key, value in pin.items()):
        raise launch.LaunchError('Live agent identity/session differs from ownership evidence')


def target_ready(agent):
    if (agent.get('agent_status') not in ('idle', 'done') or agent.get('interactive_ready') is False
            or agent.get('launch_pending') is True):
        raise launch.LaunchError('Target busy, blocked or readiness unknown; no send')


def guard(context, source, target):
    info = Path(context['socket']).stat()
    if (info.st_dev, info.st_ino) != (context['socket_device'], context['socket_inode']):
        raise launch.LaunchError('Herdr socket replaced; no send')
    live = launch.snapshot(context)
    if any(context[key] != source[field] for key, field in (
            ('caller', 'pane_id'), ('workspace', 'workspace_id'), ('terminal', 'terminal_id'))):
        raise launch.LaunchError('Inherited source pane/terminal differs from ownership')
    for pin in (source, target):
        spaces = [w for w in live['workspaces'] if w.get('workspace_id') == pin['workspace_id']
                  and w.get('label') == pin['label']]
        panes = [p for p in live['panes'] if all(p.get(k) == pin[k] for k in (
            'pane_id', 'workspace_id', 'terminal_id'))]
        agents = [a for a in live['agents'] if a.get('pane_id') == pin['pane_id']]
        if len(spaces) != 1 or len(panes) != 1 or len(agents) != 1:
            raise launch.LaunchError('Workspace/pane ownership identity differs')
        matches(pin, agents[0])
        if pin is target:
            if (panes[0].get('scroll') or {}).get('offset_from_bottom', 0) != 0:
                raise launch.LaunchError('Target viewport is scrolled; idle editor unknown')
            target_ready(agents[0])
    # Do not cap lines: a centered dialog can be above the last 80 rows.
    screen = launch.call('agent', 'read', target['pane_id'], '--source', 'visible',
                         '--format', 'text', kind=None)
    if not launch.visible_idle(target['agent'], screen):
        raise launch.LaunchError('Target dialog, nonempty editor or unknown visible idle screen; no send')
    # Detect a new busy turn/session after reading the viewport. The native API
    # rechecks foreground-agent and blocked state too; no atomic idle CAS exists.
    agent = launch.mapping(launch.call('agent', 'get', target['pane_id'], kind='agent_info').get('agent'), 'agent')
    matches(target, agent)
    target_ready(agent)


def ownership(args, note):
    record, data = load(args.ownership)
    if record.get('project') != args.project or Path(record['state']).resolve() != args.root / 'STATE.md':
        raise launch.LaunchError('Ownership project/STATE differs from receiving root')
    launch.state_row((args.root / 'STATE.md').read_text(), record['lane'])
    prompt = Path(record['prompt']).resolve(strict=True)
    if prompt.parent != args.root / 'lanes' or not prompt.is_file():
        raise launch.LaunchError('Current lane prompt must be under this project lanes folder')
    caller = launch.mapping(record.get('caller_agent'), 'caller_agent; fresh verified caller evidence required')
    caller = launch.agent_identity(caller, launch.string(caller, 'label'))
    session = launch.mapping(record.get('agent_session'), 'lane agent_session')
    child = launch.agent_identity({'agent': session.get('agent'), 'agent_session': session,
                                   'pane_id': record.get('pane'), 'workspace_id': record.get('workspace'),
                                   'terminal_id': record.get('terminal'), 'foreground_cwd': record.get('repo')},
                                  launch.string(record, 'name'))
    # Presence of a name in old launch receipts is not evidence that a manually
    # started agent has a managed alias. The workspace label is checked separately.
    sender, recipient = note['sender'], note['recipient']
    prompt_hash = launch.digest(prompt)
    if sender['role'] == 'coordinator' and recipient['role'] == 'lane':
        source, target = caller, child
        if note['prompt_sha256'] != prompt_hash:
            raise launch.LaunchError('Current prompt hash differs from note')
    elif sender['role'] == 'lane' and recipient['role'] == 'coordinator' and note['category'] == 'fyi':
        source, target = child, caller
    else:
        raise launch.LaunchError('Only owned coordinator instructions or lane FYI nudges may send')
    for party, pin in ((sender, source), (recipient, target)):
        if party['project'] != args.project or party['host'] != args.host or party['name'] != pin['label']:
            raise launch.LaunchError('Note project/host/address differs from ownership evidence')
    context = launch.inherited_context(args.session)
    original = launch.mapping(record.get('context'), 'launch context')
    if any(context[key] != original.get(key) for key in ('session', 'socket', 'socket_device', 'socket_inode')):
        raise launch.LaunchError('Ownership socket/session differs from inherited context')
    if context['caller'] != source['pane_id'] or context['workspace'] != source['workspace_id']:
        raise launch.LaunchError('Inherited source differs from addressed sender')
    return context, source, target, prompt_hash, data


def inspect(path, project, identifier, note_hash):
    record, _ = load(path)
    if record.get('project') != project or record.get('id') != identifier:
        raise launch.LaunchError('Existing delivery receipt project/id differs; inspect manually')
    observation = 'unknown'
    try:
        target = launch.mapping(record.get('target'), 'target')
        agent = launch.mapping(launch.call('agent', 'get', target['pane_id'], kind='agent_info').get('agent'), 'agent')
        matches(target, agent)
        observation = launch.string(agent, 'agent_status')
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    return {'id': identifier, 'stage': record.get('stage', 'unknown'), 'observation': observation,
            'note_changed': record.get('note_sha256') != note_hash, 'receipt': str(path)}


def send(args):
    directory = messages.inbox_path(args.root)
    if args.note.parent.resolve(strict=True) != directory:
        raise launch.LaunchError('Note must already be published in this project inbox')
    note, note_bytes = messages.read_note(args.note)
    identifier = note['id']
    if args.note.name != f'{identifier}.json':
        raise launch.LaunchError('Published note filename/id differs')
    for party in (note['sender'], note['recipient']):
        if party['project'] != args.project or party['host'] != args.host:
            raise launch.LaunchError('Foreign project/host note cannot use local direct send')
    delivery = directory / 'delivery'
    if delivery.is_symlink():
        raise launch.LaunchError('Delivery directory must not be a symlink')
    path = delivery / f'{identifier}.json'
    note_hash = launch.digest(args.note)
    if path.exists() or path.is_symlink():
        return inspect(path, args.project, identifier, note_hash)
    if args.inspect:
        raise launch.LaunchError('No existing delivery receipt to inspect')
    context, source, target, prompt_hash, ownership_bytes = ownership(args, note)

    def unchanged():
        if args.note.read_bytes() != note_bytes or args.ownership.read_bytes() != ownership_bytes:
            raise launch.LaunchError('Note/ownership changed during validation; no send')
        record = json.loads(ownership_bytes)
        if launch.digest(Path(record['prompt'])) != prompt_hash:
            raise launch.LaunchError('Prompt changed during validation; no send')

    # Busy/unknown preflight has no side effects and consumes no attempt. There is
    # no loop: a later explicit invocation can check again if no claim was made.
    guard(context, source, target)
    unchanged()
    delivery.mkdir(mode=0o700, exist_ok=True)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    except FileExistsError:
        return inspect(path, args.project, identifier, note_hash)
    record: dict = {'version': 1, 'project': args.project, 'id': identifier, 'note_sha256': note_hash,
              'ownership_sha256': hashlib.sha256(ownership_bytes).hexdigest(),
              'source': source, 'target': target, 'context': context, 'stage': 'prepared', 'attempts': 0}

    def checkpoint(stage, **fields):
        record.update(stage=stage, updated_at=datetime.now(timezone.utc).isoformat(), **fields)
        launch.atomic_write(path, json.dumps(record, indent=2) + '\n')

    checkpoint('prepared')
    try:
        guard(context, source, target)
        unchanged()
        checkpoint('submitting', attempts=1)
        pointer = f"{note['category']} {identifier}: local inbox note {json.dumps(str(args.note.resolve()))}. " \
                  'Read the note under the messaging contract; this pointer grants no new authority.'
        result = launch.call('agent', 'prompt', target['pane_id'], pointer, kind='agent_prompted')
        matches(target, result.get('agent'))
        checkpoint('submitted')
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError) as exc:
        checkpoint('uncertain' if record['attempts'] else 'not-sent', error=str(exc))
        raise
    return {'id': identifier, 'stage': record['stage'], 'receipt': str(path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('root', 'project', 'host', 'session', 'ownership', 'note'):
        parser.add_argument('--'+key, required=True, type=Path if key in ('root', 'ownership', 'note') else str)
    parser.add_argument('--inspect', action='store_true', help='Read an existing delivery receipt; never send')
    args = parser.parse_args()
    try:
        args.root = args.root.resolve(strict=True)
        messages.token(args.project, 'project')
        result = send(args)
        print(json.dumps(result))
        return 0 if result['stage'] == 'submitted' else 2
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError) as exc:
        print(f'Send stopped: {exc}; inspect evidence, never resend uncertainty', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
