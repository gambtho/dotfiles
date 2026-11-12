#!/usr/bin/env python3
"""Project visibility from stock Herdr snapshots; remote navigation stays stock."""
import argparse
import curses
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unicodedata

INTERVAL = 3
TIMEOUT = 8
ICONS = {'needs': '!', 'review': '✓', 'working': '●', 'idle': '○', 'shell': '·'}
RANK = {'needs': 0, 'review': 1, 'working': 2, 'idle': 3, 'shell': 4}
WORDS = {'needs': 'needs you', 'review': 'ready for review', 'working': 'working', 'idle': 'idle', 'shell': 'no agent'}
STRIP_KEYS = '123456789'


def validate_snapshot(snapshot):
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get('workspaces'), list):
        raise ValueError('Missing workspace snapshot')
    for row in snapshot['workspaces']:
        if not isinstance(row, dict) or any(not isinstance(row.get(k), str) for k in ('workspace_id', 'label', 'agent_status')):
            raise ValueError('Invalid workspace')
        tokens = row.get('tokens', {})
        if not isinstance(tokens, dict) or any(not isinstance(v, str) for v in tokens.values()):
            raise ValueError('Invalid workspace tokens')
    panes = snapshot.get('panes', [])
    if not isinstance(panes, list) or any(not isinstance(p, dict) for p in panes):
        raise ValueError('Invalid pane list')
    return snapshot


def heading_projects(states):
    return {w['label'][2:] for state in states.values()
            for w in (state['snapshot'] or {}).get('workspaces', [])
            if w['label'].startswith('◆ ') and w['label'][2:].strip()}


def effective(status, phase, agent):
    """One state per lane: live working/blocked beat a stale phase token."""
    if status == 'blocked' or (status == 'idle' and phase == 'needs-decision'):
        return 'needs'
    if status == 'done' or (status == 'idle' and phase == 'ready'):
        return 'review'
    if status == 'working':
        return 'working'
    return 'idle' if agent else 'shell'


def project_rows(states):
    """Lanes are <project>-<n>; coordinators are <project>-coord, or <project> /
    <project>-local when that project is already known from lanes or a heading."""
    lanes, others = [], []
    for endpoint, state in states.items():
        snapshot = state['snapshot'] or {}
        panes = snapshot.get('panes')
        with_agent = None if panes is None else {p.get('workspace_id') for p in panes if p.get('agent')}
        for workspace in snapshot.get('workspaces', []):
            label = workspace['label']
            if label.startswith('◆ '):
                continue
            status = workspace['agent_status']
            tokens = workspace.get('tokens', {})
            agent = status != 'unknown' if with_agent is None else workspace['workspace_id'] in with_agent
            row = dict(key=(endpoint, workspace['workspace_id']), label=label, host=state['label'],
                       task=tokens.get('task', ''), phase=tokens.get('phase', ''), status=status,
                       offline=bool(state['error']), state=effective(status, tokens.get('phase', ''), agent))
            match = re.fullmatch(r'(.+)-(coord|[0-9]+)', label)
            if match:
                row.update(project=match[1], lane=match[2])
                lanes.append(row)
            else:
                others.append(row)
    known = heading_projects(states) | {r['project'] for r in lanes}
    for row in others:
        project = re.sub(r'-local$', '', row['label'])
        if project in known:
            row.update(project=project, lane='coord')
            lanes.append(row)
    return sorted(lanes, key=lambda r: (r['project'], lane_order(r), r['key']))


def lane_order(row):
    return -1 if row['lane'] == 'coord' else int(row['lane'])


def urgency(row):
    return (row['offline'], RANK[row['state']])


def icon(row):
    return '?' if row['offline'] else ICONS[row['state']]


def tag(row):
    return icon(row) + ('◆' if row['lane'] == 'coord' else row['lane'])


def name(row):
    return row['project'] + '-' + row['lane']


def strip_rows(rows):
    """Attention strip: live lanes that need Tom, plus any lane reporting a task."""
    chosen = [r for r in rows if r['state'] in ('needs', 'review') or r['task']]
    return sorted(chosen, key=lambda r: (urgency(r), r['project'], lane_order(r), r['key']))


def text_width(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)


def pad(text, width):
    text = clip(text, width)
    return text + ' ' * (width - text_width(text))


def summary(rows, states):
    live = [r for r in rows if not r['offline']]
    counts = [f"{ICONS[k]}{n}" for k in ('needs', 'review', 'working')
              if (n := sum(r['state'] == k for r in live))]
    quiet = sum(r['state'] in ('idle', 'shell') for r in live)
    if quiet:
        counts.append(f'○{quiet}')
    down = [s['label'] for s in states.values() if s['error']]
    machines = f"{len(states) - len(down)}/{len(states)} up" + (' · ' + ', '.join(down) + ' offline' if down else '')
    return ' '.join(counts + ['·', machines]) if counts else machines


def board(rows, states, width, headings=()):
    """Lines of (x, text, key, style) segments: attention strip, then project × machine grid."""
    width = max(width, 20)
    lines = [[(0, 'PROJECTS', None, 'title')]]
    right = clip(summary(rows, states), width - 9)
    lines[0].append((max(9, width - text_width(right)), right, None, 'muted'))
    lines.append([(0, '─' * width, None, 'muted')])
    for number, row in enumerate(strip_rows(rows)):
        prefix = (STRIP_KEYS[number] if number < len(STRIP_KEYS) else ' ') + ' ' + icon(row) + ' ' + name(row) + '  '
        host = ' ' + row['host'] + ('?' if row['offline'] else '')
        task = row['task'] or WORDS[row['state']]
        body = pad(prefix + task, width - text_width(host))
        lines.append([(0, body, row['key'], row['state']), (text_width(body), host, None, 'muted')])
    lines.append([(0, '─' * width, None, 'muted')])
    hosts = list(states)
    project_width = min(16, max([len(p) for p in {r['project'] for r in rows} | set(headings)] + [8]) + 2)
    cell = max(4, (width - project_width) // max(1, len(hosts)))
    lines.append([(project_width + i * cell, clip(states[h]['label'] + (' ?' if states[h]['error'] else ''), cell - 1), None, 'muted')
                  for i, h in enumerate(hosts)])
    projects = sorted({r['project'] for r in rows} | set(headings), key=lambda p: (
        min([urgency(r) for r in rows if r['project'] == p] or [(True, 9)]), p))
    for project in projects:
        line = [(0, clip(project, project_width - 1), None, 'project')]
        for i, host in enumerate(hosts):
            x = project_width + i * cell
            members = sorted((r for r in rows if r['project'] == project and r['key'][0] == host),
                             key=lambda r: (urgency(r), lane_order(r) >= 0, lane_order(r)))
            if not members:
                line.append((x, '—', None, 'muted'))
                continue
            used = 0
            for n, row in enumerate(members):
                text = tag(row)
                more = f'+{len(members) - n}'
                last = n == len(members) - 1
                if used + text_width(text) + (0 if last else len(more) + 1) > cell - 1:
                    line.append((x + used, more, None, 'muted'))
                    break
                line.append((x + used, text, row['key'], row['state']))
                used += text_width(text) + 1
        lines.append(line)
    return lines


def selectable(lines):
    return [(y, x, key) for y, line in enumerate(lines) for x, _, key, _ in line if key]


def move(lines, selected, direction):
    """Arrows: left/right within a line, up/down to the nearest item on the next line."""
    items = selectable(lines)
    if not items:
        return None
    here = next((i for i in items if i[2] == selected), items[0])
    if direction in ('left', 'right'):
        row = [i for i in items if i[0] == here[0]]
        index = row.index(here) + (1 if direction == 'right' else -1)
        return row[max(0, min(len(row) - 1, index))][2]
    step = 1 if direction == 'down' else -1
    targets = sorted({i[0] for i in items if (i[0] - here[0]) * step > 0}, key=lambda y: abs(y - here[0]))
    if not targets:
        return here[2]
    return min((i for i in items if i[0] == targets[0]), key=lambda i: abs(i[1] - here[1]))[2]


def hit(lines, y, x):
    for sx, text, key, _ in lines[y] if 0 <= y < len(lines) else []:
        if key and sx <= x < sx + text_width(text):
            return key
    return None


def detail(row):
    words = 'offline (cached ' + WORDS[row['state']] + ')' if row['offline'] else WORDS[row['state']]
    return ' · '.join(filter(None, [row['host'] + ' / ' + row['label'], words, row['task']]))


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
    curses.mousemask(curses.BUTTON1_CLICKED | curses.BUTTON1_PRESSED)
    styles = {'title': curses.A_BOLD, 'project': curses.A_BOLD, 'muted': curses.A_DIM, 'idle': curses.A_DIM, 'shell': curses.A_DIM}
    if curses.has_colors():
        curses.use_default_colors()
        for number, (state, color) in enumerate((('needs', curses.COLOR_RED), ('review', curses.COLOR_GREEN), ('working', curses.COLOR_BLUE)), 1):
            curses.init_pair(number, color, -1)
            styles[state] = curses.color_pair(number) | (curses.A_BOLD if state == 'needs' else 0)
    selected, offset, message = None, 0, ''
    while True:
        view.tick()
        rows = project_rows(view.states)
        height, width = screen.getmaxyx()
        lines = board(rows, view.states, width - 1, heading_projects(view.states))
        order = [key for _, _, key in selectable(lines)]
        updated = selection(selected, order)
        if selected != updated:
            message = ''
        selected = updated
        screen.erase()

        def put(y, x, text, attr=0, height=height, width=width):
            if 0 <= y < height and 0 <= x < width - 1:
                try:
                    screen.addstr(y, x, clip(text, width - 1 - x), attr)
                except curses.error:
                    pass

        # Title and rule stay fixed; strip and grid scroll beneath them.
        body = lines[2:]
        available = max(0, height - 5)
        line = next((y for y, _, key in selectable(body) if key == selected), None)
        if line is not None and available:
            if line < offset:
                offset = line
            elif line >= offset + available:
                offset = line - available + 1
        offset = max(0, min(offset, len(body) - available))
        shown = lines[:2] + body[offset:offset + available]
        for y, segments in enumerate(shown):
            for x, text, key, style in segments:
                attr = styles.get(style, 0) | (curses.A_REVERSE if key and key == selected else 0)
                put(y, x, text, attr)
        row = next((r for r in rows if r['key'] == selected), None)
        if view.discovery_error:
            notice = 'Discovery failed: ' + view.discovery_error
        elif row and row['offline']:
            notice = 'Offline: cached row only; navigation disabled'
        else:
            notice = message or (focus_hint(row) if row else '')
        put(height - 3, 0, detail(row) if row else 'No project lanes found', curses.A_BOLD)
        put(height - 2, 0, notice)
        put(height - 1, 0, 'arrows/hjkl move · 1-9 strip · Enter or click go · r refresh · q quit', curses.A_DIM)
        screen.refresh()
        key = screen.getch()
        if key in (ord('q'), 27):
            return
        go = False
        if key == curses.KEY_MOUSE:
            try:
                _, mx, my, _, _ = curses.getmouse()
            except curses.error:
                continue
            target = hit(shown, my, mx)
            if target:
                selected, go = target, True
        elif key == ord('r'):
            view.refresh()
        elif key in DIRECTIONS:
            selected, message = move(lines, selected, DIRECTIONS[key]), ''
        elif 0 <= key < 256 and chr(key) in STRIP_KEYS:
            strip = strip_rows(rows)
            index = STRIP_KEYS.index(chr(key))
            if index < len(strip):
                selected, message = strip[index]['key'], ''
        elif key in (10, 13, curses.KEY_ENTER):
            go = True
        row = next((r for r in rows if r['key'] == selected), None)
        if go and row:
            message = focus(row, view.binary)


DIRECTIONS = {curses.KEY_UP: 'up', ord('k'): 'up', curses.KEY_DOWN: 'down', ord('j'): 'down',
              curses.KEY_LEFT: 'left', ord('h'): 'left', curses.KEY_RIGHT: 'right', ord('l'): 'right'}


def focus_hint(row):
    return 'Enter focuses this lane' if row['key'][0] == 'local' else f"Ctrl-B w → {row['host']} → {row['label']} → Enter"


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
            discovered = False
            while time.monotonic() < deadline:
                view.tick()
                if not discovered and not view.discovery_error:
                    # Snapshot readers start only after discovery. Give that
                    # initial batch its own bound, without repeated discovery
                    # extending the diagnostic indefinitely.
                    discovered = True
                    view.next_discovery = float('inf')
                    deadline = time.monotonic() + TIMEOUT + 2
                if discovered and all(s['snapshot'] is not None or (s['pending'] is None and s['error'] != 'Loading') for s in view.states.values()):
                    break
                time.sleep(.05)
            output = [host_summary(view.states)]
            if view.discovery_error:
                output.append('Discovery failed: ' + view.discovery_error)
            columns = shutil.get_terminal_size((120, 24)).columns
            for segments in board(project_rows(view.states), view.states, columns - 1, heading_projects(view.states)):
                text = ''
                for x, part, _, _ in segments:
                    text = pad(text, x) + part
                output.append(text.rstrip())
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
