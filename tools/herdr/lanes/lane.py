#!/usr/bin/env python3
"""Open interactive lanes under stock Herdr worktree headings."""
import argparse
import fcntl
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path


def herdr(*args):
    operation = ' '.join(args[:2])
    try:
        completed = subprocess.run(['herdr', *args], capture_output=True, text=True,
                                   timeout=10, check=True)
    except subprocess.CalledProcessError as error:
        raise ValueError(f'herdr {operation} failed: {error.stderr.strip() or error.returncode}') from error
    except subprocess.TimeoutExpired as error:
        raise ValueError(f'herdr {operation} timed out; inspect the target, do not resend') from error
    if not completed.stdout.strip() and args[:2] in (('pane', 'run'), ('workspace', 'focus')):
        return {}
    return json.loads(completed.stdout)['result']


def unique(spaces, label):
    matches = [w for w in spaces if w['label'] == label]
    if len(matches) > 1:
        raise ValueError(f'duplicate workspace label: {label}; inspect without sending input')
    return matches[0] if matches else None


def fresh_pane(result, spaces, label):
    workspace, pane = result['workspace'], result['root_pane']
    wid = workspace['workspace_id']
    if (result.get('already_open', False) is not False
            or wid in {w['workspace_id'] for w in spaces}
            or workspace['label'] != label or pane['workspace_id'] != wid
            or not pane.get('pane_id')):
        raise ValueError(f'workspace {wid}, pane {pane.get("pane_id")}: already open/adopted '
                         'or identity changed; sent nothing; do not resend')
    return pane['pane_id']


def wait_shell(pane, call=None):
    # New shells have the keyring opt-out before startup. Also refuse other jobs.
    # This process check is not a general shell-prompt detector.
    call = herdr if call is None else call
    for _ in range(30):
        info = call('pane', 'process-info', '--pane', pane)['process_info']
        foreground = info.get('foreground_processes') or []
        if (info.get('pane_id') == pane and len(foreground) == 1
                and foreground[0].get('pid') == info.get('shell_pid')
                and foreground[0].get('name', '').lstrip('-') in ('sh', 'bash', 'zsh', 'dash', 'fish')):
            return
        time.sleep(0.1)
    raise ValueError(f'{pane}: shell is not alone in the foreground; sent nothing. '
                     'Finish startup or the running command before running anything manually.')


def resolve(label, cwd=None):
    cwd = Path.cwd() if cwd is None else cwd
    if label == 'coord' or label.isdecimal():
        if not cwd.name.endswith('-local'):
            raise ValueError('shorthand requires a ~/<project>-local directory')
        label = f'{cwd.name[:-6]}-{label}'
    projects = [folder.name[:-6] for folder in Path.home().glob('*-local') if folder.is_dir()]
    project = max((p for p in projects if label == p or label.startswith(p + '-')),
                  key=len, default='')
    if not project:
        raise ValueError(f'no project folder for {label} under ~/*-local')
    suffix = label[len(project) + 1:] if label != project else ''
    if label != project and not (suffix == 'coord' or suffix.isdecimal()):
        raise ValueError('label must look like <project>-<n|coord>, or <project> for its heading')
    return project, suffix


def focus_existing(workspace, prompt):
    herdr('workspace', 'focus', workspace['workspace_id'])
    print(f'{workspace["label"]} already open; focused it, sent nothing')
    if prompt:
        raise ValueError('prompt not sent to an existing workspace; submit it manually')


def anchor_checkout(anchor, checkout):
    if not (anchor / '.git').is_dir():
        anchor.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', '-C', str(anchor), 'init', '-q', '-b', 'main'], check=True)
    if subprocess.run(['git', '-C', str(anchor), 'rev-parse', '--verify', 'HEAD'],
                      capture_output=True, check=False).returncode:
        subprocess.run(['git', '-C', str(anchor), '-c', 'user.name=Lane anchor',
                        '-c', 'user.email=lane-anchor@localhost', 'commit', '-q',
                        '--allow-empty', '-m', 'Project heading anchor'], check=True)
    if checkout is not None and not checkout.exists():
        subprocess.run(['git', '-C', str(anchor), 'worktree', 'add', '-q', '--detach',
                        str(checkout)], check=True)


def open_lane(label, prompt=''):
    if (any(ord(c) < 32 or 127 <= ord(c) < 160 for c in label)
            or any((ord(c) < 32 and c != '\n') or 127 <= ord(c) < 160 for c in prompt)):
        raise ValueError('terminal control characters are not supported; sent nothing')
    project, number = resolve(label)
    root = Path.home() / '.lane-anchors'
    root.mkdir(parents=True, exist_ok=True)
    with (root / f'.{project}.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return open_locked(project, number, prompt)


def open_locked(project, number, prompt):
    # Refresh the workspace list below only after taking the project lock.
    label = f'{project}-{number}' if number else project
    anchor = Path.home() / '.lane-anchors' / project
    checkout = Path.home() / '.lane-anchors' / f'{project}-lanes' / number if number else None
    workdir = Path.home() / f'{project}-local'
    spaces = herdr('workspace', 'list')['workspaces']
    # Check before worktree-open: it can adopt AND rename an existing checkout.
    existing = unique(spaces, label) if number else None
    if existing:
        focus_existing(existing, prompt)
        return
    if checkout:
        opened = [w for w in spaces if (w.get('worktree') or {}).get('checkout_path') == str(checkout)]
        if len(opened) > 1:
            raise ValueError('duplicate workspaces at lane checkout; sent nothing')
        if opened:
            focus_existing(opened[0], prompt)
            return
    heading_label = f'◆ {project}'
    heading = unique(spaces, heading_label)
    anchor_checkout(anchor, checkout)
    if not heading:
        result = herdr('workspace', 'create', '--cwd', str(anchor), '--label', heading_label,
                       '--no-focus', '--env', 'DOTFILES_KEYRING_PROMPT=0')
        pane = fresh_pane(result, spaces, heading_label)
        publisher = Path(__file__).resolve().with_name('needs.py')
        command = f'python3 -B {shlex.quote(str(publisher))}'
        try:
            wait_shell(pane)
        except ValueError as error:
            raise ValueError(f'{pane}: heading publisher not started; finish shell startup, '
                             f'then run {command} in this pane; do not resend the lane prompt') from error
        herdr('pane', 'run', pane, command)
        spaces = [*spaces, result['workspace']]
    if not number:
        print(f'heading {heading_label} ready; focus unchanged')
        return
    # Create our own shell with env first, then attach stock grouping to that
    # exact workspace. Worktree-open alone cannot set pre-shell environment.
    created = herdr('workspace', 'create', '--cwd', str(checkout), '--label', label,
                    '--no-focus', '--env', 'DOTFILES_KEYRING_PROMPT=0')
    pane = fresh_pane(created, spaces, label)
    # Omit --label: worktree-open may adopt another actor's checkout, and must
    # never rename it. Only our just-created workspace may receive commands.
    try:
        result = herdr('worktree', 'open', '--cwd', str(anchor), '--path', str(checkout), '--focus')
        if (result.get('already_open') is not True
                or result['workspace']['workspace_id'] != created['workspace']['workspace_id']
                or result['workspace']['label'] != label
                or result['root_pane']['pane_id'] != pane
                or result['root_pane']['terminal_id'] != created['root_pane']['terminal_id']
                or (result['workspace'].get('worktree') or {}).get('checkout_path') != str(checkout)
                or not (result['workspace'].get('worktree') or {}).get('is_linked_worktree')):
            raise ValueError('group attachment adopted another workspace or identity changed')
        wait_shell(pane)
        command = f'cd {shlex.quote(str(workdir))}'
        if prompt:
            command += f' && pi -- {shlex.quote(prompt)}'
        herdr('pane', 'run', pane, command)
    except (ValueError, KeyError, TypeError, AttributeError, OSError) as error:
        raise ValueError(f'{pane}: launch incomplete or uncertain: {error}; inspect this pane, '
                         'do not resend; rerunning lane only focuses it') from error
    print(f'{label} open under {heading_label}' + ('; Pi prompt submitted once' if prompt else ''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lane', help='<project>-<n|coord>, <project> heading, or <n|coord> from its local folder')
    parser.add_argument('prompt', nargs='?', default='', help='optional initial Pi prompt (new lanes only)')
    parser.add_argument('--host', help='saved remote binding in project-local/lane-hosts.json (flat numbered lanes)')
    args = parser.parse_args()
    if args.host is not None and not args.host:
        parser.error('--host must not be empty')
    if args.host is not None and not args.prompt:
        parser.error('--host requires a host-resolved local prompt file')
    try:
        if args.host is not None:
            # Resolve the sibling runtime even when invoked through the installed symlink.
            import importlib.util
            spec = importlib.util.spec_from_file_location('lane_remote', Path(__file__).resolve().with_name('remote.py'))
            assert spec is not None and spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            module.open_remote(args.lane, args.prompt, args.host, sys.modules[__name__])
        else:
            open_lane(args.lane, args.prompt)
    except (ValueError, KeyError, TypeError, AttributeError, OSError, subprocess.SubprocessError) as error:
        print(f'lane: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
