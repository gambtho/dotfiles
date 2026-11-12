#!/usr/bin/env python3
"""Project visibility from stock Herdr snapshots; remote navigation stays stock."""
import argparse
import curses
import json
import os
import re
import signal
import subprocess
import tempfile
import time
import unicodedata
from collections import Counter

SECTIONS = ('Needs you', 'Ready for review', 'Working', 'Idle', 'Offline (cached)')
INTERVAL = 3
TIMEOUT = 8


def validate_snapshot(snapshot):
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get('workspaces'), list):
        raise ValueError('Missing workspace snapshot')
    for row in snapshot['workspaces']:
        if not isinstance(row, dict) or any(not isinstance(row.get(k), str) for k in ('workspace_id', 'label', 'agent_status')):
            raise ValueError('Invalid workspace')
        tokens = row.get('tokens', {})
        if not isinstance(tokens, dict) or any(not isinstance(v, str) for v in tokens.values()):
            raise ValueError('Invalid workspace tokens')
    return snapshot


def project_rows(states):
    rows: list[dict] = []
    for endpoint, state in states.items():
        for workspace in (state['snapshot'] or {}).get('workspaces', []):
            if workspace['label'].startswith('◆ '):
                continue
            match = re.fullmatch(r'(.+)-(coord|[0-9]+)', workspace['label'])
            if not match:
                continue
            project, lane = match.groups()
            status = workspace['agent_status']
            tokens = workspace.get('tokens', {})
            phase = tokens.get('phase', '')
            section = {'working': 'Working', 'blocked': 'Needs you', 'done': 'Ready for review'}.get(status, 'Idle')
            if status == 'idle' and phase in ('needs-decision', 'ready'):
                section = 'Needs you' if phase == 'needs-decision' else 'Ready for review'
            offline = bool(state['error'])
            rows.append(dict(key=(endpoint, workspace['workspace_id']), project=project, lane=lane,
                             label=workspace['label'], host=state['label'], task=tokens.get('task', ''),
                             phase=phase, status=status, offline=offline,
                             section='Offline (cached)' if offline else section))
    return sorted(rows, key=lambda row: (row['project'], -1 if row['lane'] == 'coord' else int(row['lane']), row['key']))


def heading_projects(states):
    return {w['label'][2:] for state in states.values()
            for w in (state['snapshot'] or {}).get('workspaces', [])
            if w['label'].startswith('◆ ') and w['label'][2:].strip()}


def lines_for(rows, mode, headings=()):
    lines = []
    groups = sorted(set(headings) | {r['project'] for r in rows}) if mode == 'projects' else SECTIONS
    for group in groups:
        members = [r for r in rows if r['project' if mode == 'projects' else 'section'] == group]
        if mode == 'projects':
            needs = sum(r['section'] == 'Needs you' for r in members)
            title = f"{group} · {needs} needs you (known) · {sum(r['offline'] for r in members)} offline"
        else:
            title = f'{group} · {len(members)}'
        lines.append((title, None, 'heading'))
        for row in members:
            badge = '◆ coord' if row['lane'] == 'coord' else row['lane']
            lines.append((f"  {badge:<8} {row['host']} · {row['section']}", row['key'], row['section']))
            lines.append((f"    {row['task'] or '(no task reported)'}", row['key'], 'detail'))
            status = ('cached ' if row['offline'] else 'live ') + row['status']
            lines.append((f"    phase: {row['phase'] or '—'} · {status}", row['key'], 'detail'))
        lines.append(('', None, 'detail'))
    return lines


def host_summary(states):
    return ' | '.join(state['label'] + (' OFFLINE: ' + state['error'] if state['error'] else ' online') for state in states.values())


def selection(selected, order):
    return selected if selected in order else next(iter(order), None)


def clip(text, width):
    result, used = [], 0
    for character in text:
        if unicodedata.category(character).startswith('C'):
            character = ' '
        size = 0 if unicodedata.combining(character) else 2 if unicodedata.east_asian_width(character) in ('W', 'F') else 1
        if used + size > width:
            break
        result.append(character)
        used += size
    return ''.join(result)


def focus(row, binary='herdr'):
    if row['offline']:
        return 'Offline: cached row only; navigation disabled'
    if row['key'][0] != 'local':
        return f"Ctrl-B w → {row['host']} / {row['label']} → Enter"
    try:
        result = subprocess.run([binary, 'workspace', 'focus', row['key'][1]], capture_output=True, text=True, timeout=2, check=False)
        return 'Focused ' + row['label'] if result.returncode == 0 else 'Focus failed: ' + result.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return 'Focus failed: ' + str(error)


class Read:
    """One owned CLI process group; never signal a shared detached SSH master."""
    def __init__(self, command):
        self.output = tempfile.TemporaryFile()
        self.errors = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=self.output,
                                            stderr=self.errors, start_new_session=True)
        except BaseException:
            self.output.close()
            self.errors.close()
            raise
        self.started = time.monotonic()

    def done(self):
        return self.process.poll() is not None

    def result(self):
        self.output.seek(0)
        self.errors.seek(0)
        if self.process.returncode:
            raise ValueError(self.errors.read(500).decode(errors='replace').strip() or f'CLI exit {self.process.returncode}')
        return json.load(self.output)

    def close(self):
        if not self.output.closed:
            # Kill only the newly created reader session. OpenSSH's persistent
            # masters daemonize into separate sessions; existing masters are not
            # descendants in this group. No socket/master shutdown commands.
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait()
            self.output.close()
            self.errors.close()


class Dashboard:
    def __init__(self, binary='herdr'):
        self.binary = binary
        self.states = {'local': self.new_state('Local')}
        self.discovery = None
        self.next_discovery = 0
        self.discovery_error = 'Loading machines'

    @staticmethod
    def new_state(label):
        return dict(label=label, snapshot=None, error='Loading', pending=None, next=0)

    def reconcile(self, profiles):
        if not isinstance(profiles, list) or any(not isinstance(p, dict) or not isinstance(p.get('id'), str)
                or not isinstance(p.get('label'), str) or not isinstance(p.get('enabled'), bool) for p in profiles):
            raise ValueError('Invalid saved-machine list')
        active = {p['id']: p['label'] for p in profiles if p['enabled']}
        for endpoint in list(self.states):
            if endpoint != 'local' and endpoint not in active:
                pending = self.states.pop(endpoint)['pending']
                if pending:
                    pending.close()
        for endpoint, label in active.items():
            self.states.setdefault(endpoint, self.new_state(label))['label'] = label

    def tick(self):
        now = time.monotonic()
        if self.discovery is not None and (self.discovery.done() or now - self.discovery.started >= TIMEOUT):
            try:
                if not self.discovery.done():
                    raise ValueError('Machine discovery timed out')
                self.reconcile(self.discovery.result())
                self.discovery_error = ''
            except (ValueError, KeyError, TypeError, OSError) as error:
                self.discovery_error = str(error)
            finally:
                self.discovery.close()
                self.discovery = None
                self.next_discovery = now + INTERVAL
        if self.discovery is None and now >= self.next_discovery:
            try:
                self.discovery = Read([self.binary, 'machine', 'list', '--json'])
            except OSError as error:
                self.discovery_error = str(error)
                self.next_discovery = now + INTERVAL
        for endpoint, state in self.states.items():
            read = state['pending']
            if read is not None and (read.done() or now - read.started >= TIMEOUT):
                try:
                    if not read.done():
                        raise ValueError('Read timed out')
                    snapshot = validate_snapshot(read.result()['result']['snapshot'])
                    state.update(snapshot=snapshot, error='')
                except (ValueError, KeyError, TypeError, OSError) as error:
                    state['error'] = str(error)
                finally:
                    read.close()
                    state.update(pending=None, next=now + INTERVAL)
            if state['pending'] is None and now >= state['next']:
                command = [self.binary] + ([] if endpoint == 'local' else ['--machine', endpoint]) + ['api', 'snapshot']
                try:
                    state['pending'] = Read(command)
                except OSError as error:
                    state.update(error=str(error), next=now + INTERVAL)
            elif state['pending'] is not None and now - state['pending'].started > 4:
                state['error'] = 'Read pending; cached only'

    def refresh(self):
        self.next_discovery = 0
        for state in self.states.values():
            state['next'] = 0

    def close(self):
        for read in [self.discovery] + [s['pending'] for s in self.states.values()]:
            if read:
                read.close()


def run(screen, view):
    curses.curs_set(0)
    screen.keypad(True)
    screen.timeout(100)
    selected, offset, mode, message = None, 0, 'projects', ''
    while True:
        view.tick()
        rows = project_rows(view.states)
        counts = Counter(r['section'] for r in rows)
        content = lines_for(rows, mode, heading_projects(view.states))
        order = list(dict.fromkeys(line[1] for line in content if line[1]))
        updated = selection(selected, order)
        if selected != updated:
            message = ''
        selected = updated
        screen.erase()
        height, width = screen.getmaxyx()

        def put(y, text, attr=0, height=height, width=width):
            if 0 <= y < height and width > 1:
                try:
                    screen.addstr(y, 0, clip(text, width - 1), attr)
                except curses.error:
                    pass

        put(0, 'PROJECTS · ' + mode.upper(), curses.A_BOLD)
        put(1, f"Needs you {counts['Needs you']} known · Review {counts['Ready for review']} · Working {counts['Working']} · Idle {counts['Idle']}")
        put(2, host_summary(view.states))
        available = max(0, height - 7)
        positions = [i for i, line in enumerate(content) if selected and line[1] == selected]
        if positions and available:
            if positions[0] < offset:
                offset = positions[0]
            elif positions[-1] >= offset + available:
                offset = max(0, positions[-1] - available + 1)
        offset = min(offset, max(0, len(content) - available))
        for y, (text, key, style) in enumerate(content[offset:offset + available], 3):
            attr = curses.A_REVERSE if key and key == selected else 0
            if style == 'heading':
                attr |= curses.A_BOLD
            elif style == 'detail':
                attr |= curses.A_DIM
            put(y, text, attr)
        row = next((r for r in rows if r['key'] == selected), None)
        notice = 'Offline: cached row only; navigation disabled' if row and row['offline'] else message
        put(height - 4, 'Discovery failed: ' + view.discovery_error if view.discovery_error else notice)
        put(height - 3, 'Selected: ' + (row['host'] + ' / ' + row['label'] if row else 'No matching project lanes'))
        put(height - 2, 'Local Enter focuses · Remote: Ctrl-B w, select workspace, Enter')
        put(height - 1, '↑↓/jk select · p/a views · r refresh · Enter go/help · q exit', curses.A_DIM)
        screen.refresh()
        key = screen.getch()
        if key in (ord('q'), 27):
            return
        if key in (ord('p'), ord('a')):
            mode, offset, message = ('projects' if key == ord('p') else 'attention'), 0, ''
        elif key == ord('r'):
            view.refresh()
        elif key in (curses.KEY_DOWN, ord('j'), curses.KEY_UP, ord('k')) and order:
            index = order.index(selected)
            selected = order[max(0, min(len(order) - 1, index + (1 if key in (curses.KEY_DOWN, ord('j')) else -1)))]
            message = ''
        elif key in (10, 13, curses.KEY_ENTER) and row:
            message = focus(row, view.binary)


def interrupted(signum, frame):
    # Pane closure sends HUP/TERM rather than a keypress. Unwind through the
    # same finally block so detached reader groups do not outlive this pane.
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--once', action='store_true', help='print one bounded snapshot per enabled machine')
    args = parser.parse_args()
    view = Dashboard()
    signal.signal(signal.SIGHUP, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.once:
            deadline = time.monotonic() + TIMEOUT + 2
            while time.monotonic() < deadline:
                view.tick()
                if not view.discovery_error and all(s['snapshot'] is not None or s['error'] != 'Loading' for s in view.states.values()):
                    break
                time.sleep(.05)
            output = [host_summary(view.states)]
            if view.discovery_error:
                output.append('Discovery failed: ' + view.discovery_error)
            output.extend(text for text, _, _ in lines_for(project_rows(view.states), 'projects', heading_projects(view.states)))
            for text in output:
                print(clip(text, len(text) * 2))
            return int(bool(view.discovery_error or any(s['error'] for s in view.states.values())))
        curses.wrapper(run, view)
        return 0
    except KeyboardInterrupt:
        return 0
    finally:
        view.close()


if __name__ == '__main__':
    raise SystemExit(main())
