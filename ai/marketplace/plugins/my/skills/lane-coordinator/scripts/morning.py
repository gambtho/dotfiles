#!/usr/bin/env python3
"""Read-only configured morning sweep; --check writes advisory STATE drift receipts."""
import argparse
import csv
import datetime as dt
import html
import io
import itertools
import json
import os
import pathlib
import re
import selectors
import signal
import subprocess
import tempfile
import time
import urllib.parse
from typing import BinaryIO, cast

# Configuration is entirely project-owned; these are format defaults only.
REPOS = ()
WATCH = ()
OWN_ONLY = set()
OURS = set()
ALIASES = {}
ROOT = pathlib.Path.cwd()
STAMP = ROOT / '.morning-last-run'
ME = None
NOTIFICATIONS = INTERNAL_TRACKER = False
DECISION_PREFIX, LANE_PREFIX = 'D', 'W'
RECORD_FILES = ()
SHARED_ROOT = ROOT
TRACKED_SERIES = []
CHECK_SETTINGS = {}
INTERNAL_SOURCE = None
LIMITS = {'seconds': 300, 'queries': 600}
BAD_CHECKS = {'FAILURE', 'ERROR', 'TIMED_OUT', 'ACTION_REQUIRED', 'CANCELLED', 'STARTUP_FAILURE'}
BASE_KEYS = {'repos', 'watch', 'own_only', 'ours', 'aliases', 'notifications', 'internal_tracker',
             'me', 'record_files', 'shared_root', 'decision_prefix', 'lane_prefix', 'tracked_series'}
MAX_TEXT = 1024 * 1024
MAX_CAPTURE = 16 * 1024 * 1024


class ObservationError(ValueError):
    """A requested read is incomplete, not an empty healthy observation."""


class BudgetExhausted(ObservationError):
    """No read started; optional reference enrichment may list it as not checked."""


NOT_CHECKED = object()


def read_text(path):
    with pathlib.Path(path).open('rb') as stream:
        data = stream.read(MAX_TEXT + 1)
    if len(data) > MAX_TEXT:
        raise ObservationError('text input exceeds 1 MiB; coverage unknown')
    return data.decode('utf-8')


def safe_text(value):
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(value))
    text = re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', text)
    text = html.escape(text, quote=False)
    return re.sub(r'([\\|\[\]*_`])', r'\\\1', text)


def safe_url(value):
    if not isinstance(value, str) or re.search(r'[\x00-\x20\x7f]', value):
        return 'unknown-url'
    parsed = urllib.parse.urlsplit(value)
    return value if parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password else 'unknown-url'


def repo_alias(repo):
    return next((alias for alias, target in ALIASES.items() if target == repo), repo.split('/')[-1])


def workspace_root(root):
    return pathlib.Path(root if root is not None else pathlib.Path.cwd()).expanduser().resolve()


def configure(root):
    """Validate base and optional supplemental settings before publishing globals."""
    global ROOT, STAMP, REPOS, WATCH, OWN_ONLY, OURS, ALIASES, NOTIFICATIONS, INTERNAL_TRACKER
    global ME, RECORD_FILES, SHARED_ROOT, DECISION_PREFIX, LANE_PREFIX, TRACKED_SERIES
    global CHECK_SETTINGS, INTERNAL_SOURCE, LIMITS
    config = json.loads(read_text(root / 'coordination.json'))
    repo_name = lambda x: isinstance(x, str) and re.fullmatch(r'[\w.-]+/[\w.-]+', x)
    path_name = lambda x: isinstance(x, str) and bool(x.strip())
    if not isinstance(config, dict) or set(config) - BASE_KEYS:
        raise ValueError('coordination.json: expected object with existing project keys')
    repos = config.get('repos')
    if not isinstance(repos, list) or not repos or not all(repo_name(r) for r in repos):
        raise ValueError('repos must be a nonempty owner/name list')
    for key in ('ours', 'own_only'):
        group = config.get(key, [])
        if not isinstance(group, list) or not all(isinstance(r, str) and r in repos for r in group):
            raise ValueError(f'{key} must be a subset of repos')
    watch = config.get('watch', [])
    if not isinstance(watch, list) or not all(isinstance(w, list) and len(w) == 2 and repo_name(w[0])
            and type(w[1]) is int and w[1] > 0 for w in watch):
        raise ValueError('watch must contain [owner/name, positive issue number] pairs')
    aliases = config.get('aliases', {})
    if not isinstance(aliases, dict) or not all(isinstance(a, str) and re.fullmatch(r'[\w.-]+', a)
            and repo_name(r) for a, r in aliases.items()):
        raise ValueError('aliases must map shorthand to owner/name')
    for key in ('notifications', 'internal_tracker'):
        if type(config.get(key, False)) is not bool:
            raise ValueError(f'{key} must be boolean')
    me = config.get('me')
    if me is not None and (not isinstance(me, str) or not re.fullmatch(r'[\w-]+', me)):
        raise ValueError('me must be a GitHub login')
    if not isinstance(config.get('decision_prefix', 'D'), str) or not re.fullmatch(r'[A-Z]', config.get('decision_prefix', 'D')):
        raise ValueError('decision_prefix must be one uppercase letter')
    prefix = config.get('lane_prefix', 'W')
    if not isinstance(prefix, str) or not re.fullmatch(r'W|[a-z]+-w', prefix):
        raise ValueError('lane_prefix must be W or lowercase letters followed by -w')
    series = config.get('tracked_series', [])
    if not isinstance(series, list) or not all(isinstance(s, dict) and set(s) == {'repo', 'title', 'tracker'}
            and repo_name(s['repo']) and all(path_name(s[k]) for k in ('title', 'tracker')) for s in series):
        raise ValueError('tracked_series must contain repo, title and tracker objects')
    files = config.get('record_files', [])
    if not isinstance(files, list) or not all(path_name(p) for p in files):
        raise ValueError('record_files must be a list of file paths')
    resolve = lambda value: (root / pathlib.Path(value).expanduser()).resolve()
    if 'shared_root' in config and not path_name(config['shared_root']):
        raise ValueError('shared_root must be a directory path')
    shared = resolve(config['shared_root']) if 'shared_root' in config else root
    if not shared.is_dir():
        raise ValueError('shared_root is not a directory')
    side = root / 'coordination-checks.json'
    settings = json.loads(read_text(side)) if side.exists() else {}
    if not isinstance(settings, dict) or set(settings) - {'checkouts', 'disk', 'limits', 'internal_tracker_source'}:
        raise ValueError('coordination-checks.json: unknown supplemental setting')
    limits = settings.get('limits', {})
    if not isinstance(limits, dict) or set(limits) - {'seconds', 'queries'}:
        raise ValueError('limits must contain seconds/queries only')
    for key, maximum in (('seconds', 300), ('queries', 600)):
        value = limits.get(key, maximum)
        if type(value) not in ((int, float) if key == 'seconds' else (int,)) or not 0 < value <= maximum:
            raise ValueError(f'limits.{key} must be positive and no greater than {maximum}')
    checkouts = settings.get('checkouts', [])
    if not isinstance(checkouts, list) or not all(isinstance(c, dict) and set(c) == {'repo', 'path'}
            and c['repo'] in repos and path_name(c['path']) for c in checkouts):
        raise ValueError('checkouts must contain configured repo/path objects')
    disk = settings.get('disk', {})
    if not isinstance(disk, dict) or set(disk) - {'filesystem', 'minimum_free_gib', 'output_roots', 'caches', 'cache_check_checkout'}:
        raise ValueError('disk has unknown settings')
    for key in ('filesystem', 'cache_check_checkout'):
        if key in disk and not path_name(disk[key]):
            raise ValueError(f'disk.{key} must be a path')
    if 'minimum_free_gib' in disk and (type(disk['minimum_free_gib']) not in (int, float) or not 0 < disk['minimum_free_gib'] < float('inf')):
        raise ValueError('disk.minimum_free_gib must be positive and finite')
    roots = disk.get('output_roots', [])
    caches = disk.get('caches', {})
    if not isinstance(roots, list) or not all(path_name(p) for p in roots):
        raise ValueError('disk.output_roots must be paths')
    if not isinstance(caches, dict) or set(caches) - {'go', 'uv', 'npm'} or not all(path_name(p) for p in caches.values()):
        raise ValueError('disk.caches must map go/uv/npm to paths')
    source = settings.get('internal_tracker_source')
    if source is not None and (not isinstance(source, dict) or set(source) != {'host', 'repo'}
            or not isinstance(source['host'], str) or not re.fullmatch(r'[A-Za-z0-9.-]+', source['host']) or not repo_name(source['repo'])):
        raise ValueError('internal_tracker_source requires host/repo')
    if config.get('internal_tracker', False) and source is None:
        raise ValueError('internal_tracker=true requires internal_tracker_source in coordination-checks.json')
    ROOT, STAMP = root, root / '.morning-last-run'
    REPOS, WATCH = tuple(repos), tuple(map(tuple, watch))
    OWN_ONLY, OURS, ALIASES = set(config.get('own_only', [])), set(config.get('ours', [])), aliases.copy()
    # Explicit aliases determine display; missing repository basenames remain usable refs.
    ALIASES.update({r.split('/')[-1]: r for r in repos if r.split('/')[-1] not in ALIASES})
    NOTIFICATIONS, INTERNAL_TRACKER = config.get('notifications', False), config.get('internal_tracker', False)
    ME, RECORD_FILES, SHARED_ROOT = me, tuple(resolve(p) for p in files), shared
    DECISION_PREFIX, LANE_PREFIX = config.get('decision_prefix', 'D'), prefix
    TRACKED_SERIES, CHECK_SETTINGS, INTERNAL_SOURCE = series, settings, source
    LIMITS = {'seconds': limits.get('seconds', 300), 'queries': limits.get('queries', 600)}


class Budget:
    def __init__(self, seconds=300, queries=600, clock=time.monotonic):
        self.clock, self.deadline = clock, clock() + seconds
        self.queries, self.request_count = queries, 0

    def remaining(self):
        return max(0, self.deadline - self.clock() - 5)

    def request(self):
        if self.request_count >= self.queries or self.remaining() <= 0:
            return False
        self.request_count += 1
        return True


def command_failure(stderr, fallback, forced=None):
    """Keep one bounded reason, never URLs, credential assignments or token strings."""
    lines = stderr.decode('utf-8', errors='replace').splitlines()
    text = lines[0] if lines else ''
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', text)
    text = re.sub(r'(?i)\b(?:https?|ssh)://\S+', '[URL omitted]', text)
    text = re.sub(r'(?i)\b(?:bearer|basic)\s+\S+', '[credential redacted]', text)
    keys = r'(?:[\w-]*(?:token|api[ _-]?key|password|passwd|secret|credential|cookie|session|signature)[\w-]*|authorization)'
    credential = re.search(r'''(?i)\b''' + keys + r'''\b[\\"']*\s*[:=]''', text)
    if credential:
        # Fail closed on quoted/escaped/multivalue credentials: omit the whole tail.
        text = text[:credential.start()] + '[credential values omitted]'
    text = re.sub(r'\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+', '[token redacted]', text)
    text = re.sub(r'\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]*)?\b|\b[A-Za-z0-9_-]{32,}\b', '[token redacted]', text)
    text = re.sub(r'\S+:\S+@\S+', '[credentials redacted]', text)
    lower = text.lower()
    kind = forced or ('rate limit' if re.search(r'rate.?limit|too many requests|\b429\b', lower) else
                      'authentication' if re.search(r'authenticat|bad credentials|keyring|\b40[13]\b', lower) else
                      'not found' if re.search(r'not found|no such file|\b404\b', lower) else
                      'timeout' if re.search(r'time.?out|timed out|deadline exceeded', lower) else 'command failure')
    if re.fullmatch(r'[\w.-]{12,}', text):
        text = '[opaque stderr omitted]'
    return f'{kind}: {(text or fallback)[:240]}; coverage unknown'


def run_read(argv, *, timeout, budget, environment=None):
    timeout = min(timeout, budget.remaining())
    if timeout <= 0:
        raise BudgetExhausted('time budget exhausted; coverage unknown')
    env = os.environ.copy()
    env.update(GH_NO_UPDATE_NOTIFIER='1', GIT_OPTIONAL_LOCKS='0')
    if environment:
        env.update(environment)
    try:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, start_new_session=True)
    except OSError as error:
        raise ObservationError(f'cannot start read command: {type(error).__name__}') from error
    stdout, stderr = cast(BinaryIO, process.stdout), cast(BinaryIO, process.stderr)
    streams = selectors.DefaultSelector()
    streams.register(stdout, selectors.EVENT_READ, 'stdout')
    streams.register(stderr, selectors.EVENT_READ, 'stderr')
    output, total, error_bytes = [], 0, bytearray()
    deadline = time.monotonic() + timeout
    try:
        while streams.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ObservationError(command_failure(error_bytes, 'read timed out', 'timeout'))
            for key, _ in streams.select(remaining):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    streams.unregister(key.fileobj)
                    continue
                total += len(chunk)
                if total > MAX_CAPTURE:
                    raise ObservationError('read output exceeds 16 MiB; coverage unknown; narrow --since')
                if key.data == 'stdout':
                    output.append(chunk)
                elif len(error_bytes) < 4096 and b'\n' not in error_bytes:
                    error_bytes.extend(chunk[:4096-len(error_bytes)])
        process.wait(timeout=max(.001, deadline - time.monotonic()))
        if process.returncode:
            raise ObservationError(command_failure(error_bytes, f'read command exited {process.returncode}'))
        return b''.join(output).decode('utf-8')
    except subprocess.TimeoutExpired as error:
        raise ObservationError(command_failure(error_bytes, 'read timed out', 'timeout')) from error
    except UnicodeError as error:
        raise ObservationError('read returned invalid UTF-8; coverage unknown') from error
    finally:
        # Also terminate descendants retaining pipe handles after the parent exits.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        streams.close()
        stdout.close()
        stderr.close()


def atomic_write(path, text):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def lane_pattern(legacy=True):
    """Tracking includes imported W IDs; allocation uses only the project's prefix."""
    prefixes = ("W|" if legacy and LANE_PREFIX != "W" else "") + re.escape(LANE_PREFIX)
    return rf"(?:{prefixes})\d+"


def lane_number(lane):
    return int(lane.removeprefix(LANE_PREFIX).removeprefix("W"))


def parse_pr_refs(text):
    """Qualified shorthand and GitHub PR URLs; inherit only adjacent /#N lists."""
    pattern = re.compile(r"https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)"
                         r"|\b([\w.-]+(?:/[\w.-]+)?)#(\d+)((?:/#\d+)*)")
    refs = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in pattern.finditer(line):
            repo = match[1] or (match[3] if "/" in match[3] else ALIASES.get(match[3]))
            numbers = [int(match[2] or match[4])]
            numbers += [int(n) for n in re.findall(r"#(\d+)", match[5] or "")]
            for number in numbers:
                refs.append(dict(repo=repo, number=number, alias=match[3] or repo,
                                 line=line, lineno=lineno, start=match.start(), end=match.end()))
    return refs


def parse_issue_refs(text, repo):
    """Issue shorthand is local to the PR; issue URLs keep their repository."""
    text = re.sub(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)", " ", text, flags=re.DOTALL)
    # Link destinations, not their labels, determine the target repository and kind.
    text = text.replace("https://redirect.github.com/", "https://github.com/")
    text = re.sub(r'<a\b[^>]*href="(https://github\.com/[^"]+)"[^>]*>.*?</a>', r"\1", text, flags=re.DOTALL)
    text = re.sub(r"\[[^\]\n]*\]\((https://github\.com/[^)\s]+)\)", r"\1", text)
    pattern = r"https://github\.com/([\w.-]+/[\w.-]+)/issues/(\d+)\b|(?<![\w/#])#(\d+)\b"
    refs = []
    for match in re.finditer(pattern, text):
        keyword = re.search(r"\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?|references?|part of)\s*:?\s*$",
                            text[:match.start()], re.IGNORECASE)
        kind = ("Closes" if keyword and re.match(r"close|fix|resolve", keyword[1], re.IGNORECASE)
                else "Refs" if keyword else "mention")
        refs.append((match[1] or repo, int(match[2] or match[3]), kind))
    return refs


def referenced_open_issues(activity, merged, limit=25):
    lines, refs = [], {}
    tracked = {repo.lower(): repo for repo in REPOS}
    for (repo, number), data in merged.items():
        if data is None:
            lines.append(f"- {repo} PR #{number}: issue references unknown (query failed).")
            continue
        for target, issue, kind in parse_issue_refs(f"{data.get('title', '')}\n{data.get('body') or ''}", repo):
            if target.lower() not in tracked:
                continue
            key = (tracked[target.lower()], issue)
            sources = refs.setdefault(key, {})
            source = (repo, number)
            if source not in sources or kind == "Closes" or (kind == "Refs" and sources[source] == "mention"):
                sources[source] = kind
    # Reference enrichment may defer named items; real reads still fail normally.
    skipped = []
    for index, ((target, issue), sources) in enumerate(refs.items()):
        budget = activity.client.budget
        if index >= limit or budget.request_count >= budget.queries or budget.remaining() <= 0:
            skipped.append(f'{target}#{issue}')
            continue
        item = activity.client.gh("api", f"repos/{target}/issues/{issue}", budget_optional=True)
        if item is NOT_CHECKED:
            skipped.append(f'{target}#{issue}')
            continue
        labels = []
        for (repo, number), kind in sources.items():
            source = f"PR #{number}" + (f" ({repo})" if target.lower() != repo.lower() else "")
            labels.append(source + (f' "{kind}"' if kind != "mention" else " mention"))
        source = "; ".join(labels)
        label = f"{target}#{issue}"
        if item is None:
            lines.append(f"- {label}: unknown (query failed) — {source}")
        elif item["state"] == "open" and "pull_request" not in item:
            lines.append(f"- {label} {safe_text(item['title'])} — {source}")
    activity.referenced_not_checked = len(skipped)
    if skipped:
        lines.append(f"- {len(skipped)} references not checked (lookup budget): " + ', '.join(skipped))
    return lines


def reads_as_waiting(line, ref=None):
    waiting = re.compile(r"\b(wait\w*|open|parked|next|await\w*)\b", re.IGNORECASE)
    if not waiting.search(line):
        return False
    if ref is None:
        return not re.search(r"\b(merged|closed)\b", line, re.IGNORECASE)
    boundaries = list(re.finditer(r"[;|]|\.(?=\s)", line))
    start = max((m.end() for m in boundaries if m.end() <= ref["start"]), default=0)
    end = min((m.start() for m in boundaries if m.start() >= ref["end"]), default=len(line))
    # A shared trailing 'merged' completes a PR list. An unrelated PR's status must not
    # hide an open claim, so stop at clause boundaries and intervening waiting text.
    for completed in re.finditer(r"\b(merged|closed)\b", line[start:end], re.IGNORECASE):
        left, right = start + completed.start(), start + completed.end()
        if left >= ref["end"]:
            if not waiting.search(line[ref["end"]:left]):
                return False
        elif right <= ref["start"]:
            between = line[right:ref["start"]]
            if not parse_pr_refs(line[start:left]) and not parse_pr_refs(between) and not waiting.search(between):
                return False
    return True


def closed_lane_owners(state, archive):
    # Only declaration positions, not other lanes mentioned in a closure's history.
    pattern = lane_pattern()
    declarations = re.compile(rf"(?:^\s*(?:[-|] |\\1- )?|\\n- )({pattern})\b", re.MULTILINE)
    closed = set(declarations.findall(archive))
    closed.update(re.findall(rf"\b({pattern})\s*\([^)]*\)\s*(?:is\s+)?(?:closed|stopped)\b", archive, re.IGNORECASE))
    in_closed = False
    for line in state.splitlines():
        if line.startswith("## "):
            in_closed = bool(re.search(r"\b(closed|completed|stopped)\b", line, re.IGNORECASE))
        if in_closed:
            closed.update(declarations.findall(line))
        label = re.match(r"\*\*(Stopped|Closed|Completed)(?: lanes)?[^*]*\*\*\s*", line, re.IGNORECASE)
        if label:
            closed.update(re.findall(rf"(?:^|[,;]\s*)({pattern})\b", line[label.end():]))
    findings, in_closed = [], False
    for number, line in enumerate(state.splitlines(), 1):
        if line.startswith("## "):
            in_closed = bool(re.search(r"\b(closed|completed|stopped)\b", line, re.IGNORECASE))
        if in_closed or re.match(r"\*\*(Stopped|Closed|Completed)", line, re.IGNORECASE):
            continue
        # A table's third column is next actor; prose needs explicit ownership language.
        columns = line.split("|")
        actor = columns[3] if len(columns) >= 5 else line
        for lane in sorted(set(re.findall(rf"\b{pattern}\b", actor)) & closed):
            if len(columns) >= 5 or re.search(
                rf"(?:owner|actor|by|→|nudge|ask|after|until)\s*[:—-]?\s*{lane}\b"
                rf"|\b{lane}\s*(?::|owns\b|to\s+\w+|finishes\b)", actor, re.IGNORECASE
            ):
                findings.append((number, lane, line.strip()))
    return findings


def budget_counts(documents, prompts):
    limits = {"AGENTS": 900, "COORDINATION": 1500, "PEOPLE": 700, "STATE": 1600}
    return [(name, len(text.split()), limits.get(name, 800), len(text.split()) > limits.get(name, 800))
            for name, text in {**documents, **prompts}.items()]


def state_dates(state):
    header = re.search(r"Last updated:\s*(\d{4}-\d{2}-\d{2})", state)
    dates = []
    for line in state.splitlines():
        if not line.startswith("|"):
            continue
        for match in re.finditer(r"(?<![\d-])(?:(20\d{2})-)?(\d{2}-\d{2})(?![\d-])", line):
            year = match[1] or (header[1][:4] if header else None)
            if year:
                try:
                    dates.append(dt.date.fromisoformat(f"{year}-{match[2]}").isoformat())
                except ValueError:
                    continue
    return header[1] if header else "unknown", max(dates) if dates else "unknown"


def since_stamp(timestamp, since):
    times = [dt.datetime.fromisoformat(value.replace("Z", "+00:00")) for value in (timestamp, since)]
    times = [value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc) for value in times]
    return times[0] >= times[1]


def written_head(ref):
    tail = ref["line"][ref["end"]:]
    tail = re.split(r"[;|]|\b[\w.-]+(?:/[\w.-]+)?#\d+|https://", tail, maxsplit=1)[0]
    match = re.search(r"@([0-9a-f]{7,40})\b", tail)
    return match[1] if match else None


def folder_named(state, name):
    return bool(re.search(rf"(?<![\w-]){re.escape(name)}(?![\w-])", state))


def is_human(login, kind=None):
    login = (login or "").lower()
    return bool(login) and kind != "Bot" and not (login.endswith("[bot]") or "coderabbit" in login or "copilot" in login)


def checks_summary(checks):
    states = [c.get('conclusion') or c.get('state') or c.get('status') or 'UNKNOWN' for c in checks]
    pending = {'PENDING', 'IN_PROGRESS', 'QUEUED', 'WAITING', 'REQUESTED', 'EXPECTED'}
    passing = {'SUCCESS', 'NEUTRAL', 'SKIPPED'}
    if any(s not in BAD_CHECKS | pending | passing for s in states):
        return 'unknown'
    if any(s in BAD_CHECKS for s in states):
        return 'red'
    if any(s in pending for s in states):
        return 'running'
    return 'green' if states else 'none'


class GitHub:
    def __init__(self, budget=None):
        self.budget = budget if budget is not None else Budget(**LIMITS)
        self.failures, self.activity_failures = [], []
        self.prs, self.page_cache = {}, {}

    def fail(self, query, error, *, activity=True):
        entry = (safe_text(query), safe_text(str(error).splitlines()[0] or 'unknown error'))
        self.failures.append(entry)
        if activity:
            self.activity_failures.append(entry)

    def _read(self, args, host=None, *, include=False):
        if not self.budget.request():
            raise BudgetExhausted('request/time budget exhausted; coverage unknown; narrow --since')
        environment = {'GH_HOST': host} if host else None
        raw = run_read(['gh', 'api', *args, *(['--include'] if include else [])],
                       timeout=30, budget=self.budget, environment=environment)
        headers = {}
        if include:
            raw = raw.replace('\r\n', '\n')
            while raw.startswith('HTTP/'):
                head, separator, raw = raw.partition('\n\n')
                status = re.match(r'HTTP/\S+\s+(\d{3})', head)
                if not separator or status is None or not 200 <= int(status[1]) < 300:
                    raise ObservationError('malformed or unsuccessful HTTP page; coverage unknown')
                headers = {k.strip().lower(): v.strip() for line in head.splitlines()[1:]
                           if ':' in line for k, v in [line.split(':', 1)]}
            if not headers and not raw.strip():
                raise ObservationError('empty HTTP page; coverage unknown')
        data = json.loads(raw)
        if data is None:
            raise ObservationError('empty JSON value; coverage unknown')
        if isinstance(data, dict) and (data.get('errors') or 'message' in data and 'documentation_url' in data):
            raise ObservationError('GitHub returned errors; coverage unknown')
        return data, headers

    def gh(self, *args, host=None, budget_optional=False):
        try:
            if not args or args[0] != 'api':
                raise ObservationError('unsupported non-API read')
            return self._read(list(args[1:]), host)[0]
        except BudgetExhausted as error:
            if budget_optional:
                return NOT_CHECKED
            self.fail('GitHub read', error)
            return None
        except (OSError, ValueError, TypeError) as error:
            self.fail('GitHub read', error)
            return None

    def pages(self, endpoint, host=None, **params):
        key = (host, endpoint, tuple(sorted(params.items())))
        if key in self.page_cache:
            return self.page_cache[key]
        args = ['-X', 'GET', endpoint, '-f', 'per_page=100']
        for name, value in params.items():
            args += ['-f', f'{name}={value}']
        rows, seen = [], set()
        try:
            while True:
                data, headers = self._read(args, host, include=True)
                if not isinstance(data, list):
                    raise ObservationError('expected a list page; coverage unknown')
                rows.extend(data)
                link = headers.get('link', '')
                links = []
                for entry in re.split(r',\s*(?=<)', link) if link else []:
                    match = re.fullmatch(r'\s*<([^>]+)>\s*;\s*rel="([^"]+)"\s*', entry)
                    if match is None or not set(match[2].split()) <= {'next', 'prev', 'first', 'last'}:
                        raise ObservationError('malformed pagination link; coverage unknown')
                    links.append((match[1], match[2]))
                target = next((url for url, rel in links if 'next' in rel.split()), None)
                if target is None:
                    break
                parsed = urllib.parse.urlsplit(target)
                configured = host or os.environ.get('GH_HOST', 'github.com')
                expected = 'api.github.com' if configured == 'github.com' else configured
                if (parsed.scheme != 'https' or parsed.hostname != expected or parsed.port not in (None, 443)
                        or parsed.username or parsed.password or parsed.fragment or target in seen):
                    raise ObservationError('untrusted or repeated pagination link; coverage unknown')
                seen.add(target)
                # Link already contains the server's query parameters.
                args = ['-X', 'GET', target]
            self.page_cache[key] = rows
        except (OSError, ValueError, TypeError) as error:
            self.fail(endpoint, error)
            self.page_cache[key] = None
        return self.page_cache[key]

    def search(self, query, host=None):
        items = []
        for page in range(1, 11):
            data = self.gh('api', '-X', 'GET', 'search/issues', '-f', f'q={query}',
                           '-f', 'per_page=100', '-f', f'page={page}', host=host)
            if data is None:
                return None
            if (not isinstance(data, dict) or type(data.get('total_count')) is not int
                    or not isinstance(data.get('items'), list) or type(data.get('incomplete_results')) is not bool):
                self.fail('search', 'malformed search result; coverage unknown')
                return None
            if data['incomplete_results'] or data['total_count'] > 1000:
                self.fail('search', 'search incomplete or exceeds 1,000-result limit; coverage unknown')
                return None
            items.extend(data['items'])
            if len(items) >= data['total_count']:
                return items
            if not data['items']:
                self.fail('search', 'search ended before total_count; coverage unknown')
                return None
        self.fail('search', 'search page limit reached; coverage unknown')
        return None

    def pr(self, repo, number):
        key = (repo, number)
        if key in self.prs:
            return self.prs[key]
        owner, name = repo.split('/')
        query = '''query($owner:String!,$name:String!,$number:Int!) {
          repository(owner:$owner,name:$name) { pullRequest(number:$number) {
            state isDraft headRefOid reviewDecision mergeStateStatus url
            commits(last:1) { nodes { commit { oid statusCheckRollup {
              contexts(first:100) { pageInfo { hasNextPage } nodes {
                __typename
                ... on CheckRun { name status conclusion completedAt checkSuite { commit { oid } } }
                ... on StatusContext { context state createdAt commit { oid } }
              } }
            } } } }
          } }
        }'''
        data = self.gh('api', 'graphql', '-f', f'query={query}', '-f', f'owner={owner}',
                       '-f', f'name={name}', '-F', f'number={number}')
        result = None
        if data is not None:
            try:
                result = data['data']['repository']['pullRequest']
                if not isinstance(result, dict) or any(k not in result for k in
                        ('state', 'isDraft', 'headRefOid', 'reviewDecision', 'mergeStateStatus', 'url')):
                    raise ObservationError('missing PR metadata')
                if not isinstance(result['headRefOid'], str) or not re.fullmatch(r'[0-9a-f]{40}', result['headRefOid']):
                    raise ObservationError('missing PR head identity')
                commit = result['commits']['nodes'][-1]['commit']
                if commit['oid'] != result['headRefOid']:
                    raise ObservationError('PR/check revision differs from head')
                rollup = commit['statusCheckRollup']
                contexts = rollup['contexts'] if rollup is not None else None
                if rollup is not None and not isinstance(contexts, dict):
                    raise ObservationError('check context connection unavailable; coverage unknown')
                if contexts is not None and contexts['pageInfo']['hasNextPage'] is not False:
                    raise ObservationError('check contexts truncated; coverage unknown')
                checks = []
                for check in contexts['nodes'] if contexts is not None else []:
                    kind = check['__typename']
                    oid = check['checkSuite']['commit']['oid'] if kind == 'CheckRun' else check['commit']['oid']
                    if oid != result['headRefOid']:
                        raise ObservationError('check commit differs from head')
                    if kind == 'CheckRun':
                        check = dict(check, state=check['conclusion'] or check['status'])
                    elif kind != 'StatusContext':
                        raise ObservationError('unknown check context type')
                    checks.append(check)
                result = dict(result, statusCheckRollup=checks)
                if checks_summary(checks) == 'unknown':
                    raise ObservationError('unknown check state; coverage unknown')
            except (KeyError, TypeError, IndexError, ValueError) as error:
                self.fail(f'{repo}#{number}', f'incomplete PR/check metadata: {type(error).__name__}')
                result = None
        self.prs[key] = result
        return result

    def human_threads(self, repo, number):
        owner, name = repo.split('/')
        cursor, threads, seen = None, [], set()
        query = '''query($owner:String!,$name:String!,$number:Int!,$cursor:String) {
          repository(owner:$owner,name:$name) { pullRequest(number:$number) {
            reviewThreads(first:100,after:$cursor) { nodes {
              isResolved comments(first:1) { nodes { author { __typename login } } }
            } pageInfo { hasNextPage endCursor } }
          } }
        }'''
        while True:
            args = ['api', 'graphql', '-f', f'query={query}', '-f', f'owner={owner}',
                    '-f', f'name={name}', '-F', f'number={number}']
            if cursor:
                args += ['-f', f'cursor={cursor}']
            data = self.gh(*args)
            if data is None:
                return None
            try:
                connection = data['data']['repository']['pullRequest']['reviewThreads']
                threads.extend(connection['nodes'])
                if connection['pageInfo']['hasNextPage'] is False:
                    return sum(not t['isResolved'] and any(is_human((c.get('author') or {}).get('login'),
                        (c.get('author') or {}).get('__typename')) for c in t['comments']['nodes']) for t in threads)
                cursor = connection['pageInfo']['endCursor']
                if not cursor or cursor in seen:
                    raise ObservationError('review cursor missing or repeated')
                seen.add(cursor)
            except (KeyError, TypeError, ValueError) as error:
                self.fail('human review threads', f'incomplete review data: {type(error).__name__}')
                return None


def item_repo(item):
    return item["repository_url"].split("/repos/")[1]


def item_line(item):
    return f"- [{item_repo(item)}#{item['number']}]({safe_url(item['html_url'])}) {safe_text(item['title'])} ({safe_text(item['user']['login'])})"


def section(title, lines):
    return f"## {title}\n" + ("\n".join(lines) if lines else "- Nothing new.") + "\n"


def failure_section(failures):
    return section("Failed queries", [f"- `{query}`: {error}" for query, error in failures]) if failures else ""


class Activity:
    """Extra actor lookups: at most 100 items, up to four paginated endpoints each.

    Existing activity skips retain the old stamp, like failed queries. Only bounded
    referenced-issue enrichment may defer explicitly listed references without holding
    the stamp; actual read failures there still retain it. Use --since for recovery.
    """
    def __init__(self, client, since, me):
        self.client, self.since, self.me = client, since, me.lower()
        self.lookups, self.events, self.items = {}, {}, set()
        self.referenced_not_checked = 0

    def lookup(self, endpoint, paged=True, **params):
        key = (endpoint, paged, tuple(sorted(params.items())))
        if key not in self.lookups:
            parts = endpoint.split("/")
            item = (parts[1], parts[2], parts[4])
            if item not in self.items and len(self.items) >= 100:
                self.client.fail(endpoint, "unknown: lookup limit (100 items) reached; skipped")
                self.lookups[key] = None
            else:
                self.items.add(item)
                self.lookups[key] = (self.client.pages(endpoint, **params) if paged else
                                     self.client.gh("api", endpoint))
        return self.lookups[key]

    def record(self, item, user, action, timestamp, priority, me=None):
        login = (user or {}).get("login", "")
        if (login.lower() == (me or self.me).lower() or not is_human(login, (user or {}).get("type"))
                or not timestamp or not since_stamp(timestamp, self.since)):
            return None
        detail = f"{safe_text(login)}: {action} {timestamp}"
        key = (item_repo(item), item["number"])
        entry = self.events.setdefault(key, dict(item=item, priority=priority, latest={}))
        entry["priority"] = min(priority, entry["priority"])
        actor_action = (login, action)
        previous = entry["latest"].get(actor_action)
        if previous is None or since_stamp(timestamp, previous):
            entry["latest"][actor_action] = timestamp
        return detail

    def comments(self, item):
        repo, number = item_repo(item), item["number"]
        sources = [(f"repos/{repo}/issues/{number}/comments", "commented", dict(since=self.since))]
        if "pull_request" in item:
            sources += [(f"repos/{repo}/pulls/{number}/reviews", "reviewed", {}),
                        (f"repos/{repo}/pulls/{number}/comments", "review comment", dict(since=self.since))]
        details, unknown = [], False
        for endpoint, action, params in sources:
            rows = self.lookup(endpoint, **params)
            unknown |= rows is None
            for row in rows or []:
                timestamp = row.get("submitted_at") if action == "reviewed" else row.get("created_at")
                detail = self.record(item, row.get("user"), action, timestamp, 3 if action == "reviewed" else 2)
                if detail and detail not in details:
                    details.append(detail)
        if unknown:
            details.append("activity unknown (query failed or lookup limit reached)")
        return f"{item_line(item)} — {'; '.join(details)}" if details else None

    def summary(self, counts):
        lines = ["- " + "; ".join(f"{title}: {count}" for title, count in counts),
                 f"- Failed queries: {len(self.client.failures)}" +
                 (" (unknown, not nothing new; see Failed queries)." if self.client.failures else ".")]
        events = sorted(self.events.values(), key=lambda entry: entry["priority"])
        # Keep the heading and summary within ten lines; overflow is explicit, never hidden.
        for entry in events[:6 if len(events) > 7 else 7]:
            item = entry["item"]
            repo = item_repo(item)
            alias = repo_alias(repo)
            details = [f"{safe_text(login)}: {action} {timestamp}"
                       for (login, action), timestamp in entry["latest"].items()]
            lines.append(f"- [{alias}#{item['number']}]({safe_url(item['html_url'])}) " + "; ".join(details))
        if len(events) > 7:
            lines.append(f"- {len(events) - 6} more items with others' activity; see sections below.")
        return section("Summary", lines)


def new_comments(client, items, since, host=None, activity=None, me=None):
    lines = []
    for item in items or []:
        comments = client.pages(f"repos/{item_repo(item)}/issues/{item['number']}/comments", host=host, since=since)
        if comments is None:
            lines.append(f"- {item_repo(item)}#{item['number']}: comments unknown (query failed).")
        for comment in comments or []:
            if is_human(comment["user"]["login"]) and since_stamp(comment["created_at"], since):
                lines.append(f"- {safe_url(comment['html_url'])} ({safe_text(comment['user']['login'])}, {comment['created_at']})")
                if activity:
                    activity.record(item, comment["user"], "commented", comment["created_at"], 2, me=me)
    return lines


def sweep(client, since, me):
    all_repos = " ".join(f"repo:{r}" for r in REPOS)
    wide = " ".join(f"repo:{r}" for r in REPOS if r not in OWN_ONLY)
    own = " ".join(f"repo:{r}" for r in REPOS if r in OWN_ONLY)
    queries = [
        ("Review requested from you", f"{all_repos} is:pr is:open review-requested:{me}"),
        ("New comments or reviews on your PRs/issues", f"{all_repos} involves:{me} updated:>={since} -author:app/dependabot"),
        ("Opened by others", f"{wide} is:pr created:>={since} -author:{me} -author:app/dependabot"),
        ("Merged", f"{wide} is:pr is:merged merged:>={since}"),
        ("Your upstream merges", f"{own} is:pr is:merged merged:>={since} author:{me}"),
        ("New issues", f"{wide} is:issue created:>={since}"),
    ]
    activity = Activity(client, since, me)
    output, counts, merged = [], [], {}

    def add_section(title, lines, count):
        output.append(section(title, lines))
        counts.append((title, count))

    for title, query in queries:
        # An empty group is known-empty, never an unscoped GitHub search.
        items = client.search(query) if "repo:" in query else []
        lines = [item_line(it) for it in items] if items is not None else ["- unknown: query failed."]
        if title == "New comments or reviews on your PRs/issues" and items is not None:
            lines = [line for item in items if (line := activity.comments(item))]
        for index, item in enumerate(items or []):
            if title in {"Opened by others", "New issues"}:
                activity.record(item, item["user"], "opened PR" if "pull_request" in item else "opened issue",
                                item["created_at"], 1 if "pull_request" in item else 0)
            if title in {"Merged", "Your upstream merges"}:
                data = activity.lookup(f"repos/{item_repo(item)}/pulls/{item['number']}", paged=False)
                author = item["user"]
                if is_human(author.get("login"), author.get("type")):
                    merged[item_repo(item), item['number']] = data
                if data is None:
                    lines[index] += ": merger unknown."
                else:
                    merger = (data.get("merged_by") or {}).get("login") or "unknown"
                    lines[index] += f" — merged by {safe_text(merger)} {safe_text(data.get('merged_at') or 'time unknown')}"
                    activity.record(item, data.get("merged_by"), "merged", data.get("merged_at"), 4)
        add_section(title, lines, len(lines) if items is not None else "unknown")
    mine = client.search(f"{all_repos} is:pr is:open author:{me}")
    lines = []
    for item in mine or []:
        repo, number = item_repo(item), item["number"]
        data = client.pr(repo, number)
        if data is None:
            lines.append(f"{item_line(item)}: unknown")
            continue
        threads = client.human_threads(repo, number)
        reviews = activity.lookup(f"repos/{repo}/pulls/{number}/reviews")
        lines.append(f"{item_line(item)}: {checks_summary(data['statusCheckRollup'])}, "
                     f"{data['mergeStateStatus'].lower()}{', draft' if data['isDraft'] else ''}; "
                     f"review={data['reviewDecision'] or 'none'}; unresolved-human-threads="
                     f"{threads if threads is not None else 'unknown'}")
        if reviews is None:
            lines.append("  - New human reviews: unknown.")
        for review in reviews or []:
            if is_human(review["user"]["login"]) and review.get("submitted_at") and since_stamp(review["submitted_at"], since):
                lines.append(f"  - {safe_text(review['user']['login'])}: {review['state']} {review['submitted_at']} {safe_url(review['html_url'])}")
                activity.record(item, review["user"], "reviewed", review["submitted_at"], 3)
    add_section("Your open PRs", lines if mine is not None else ["- unknown: query failed."],
                len(mine) if mine is not None else "unknown")
    our_repos = " ".join(f"repo:{r}" for r in REPOS if r in OURS)
    issues = client.search(our_repos + f" is:issue updated:>={since}") if our_repos else []
    lines = new_comments(client, issues, since, activity=activity) if issues is not None else ["- unknown: query failed."]
    add_section("New human comments on existing issues in our repos", lines, len(lines) if issues is not None else "unknown")
    notifications = client.pages("notifications", all="true", since=since) if NOTIFICATIONS else []
    lines = [
        f"- {safe_text(n['repository']['full_name'])}: {safe_text(n['reason'])}: {safe_text(n['subject']['title'])} ({safe_url(n['subject']['url'])})"
        for n in notifications or [] if n["repository"]["full_name"].lower() not in {r.lower() for r in REPOS}
    ] if notifications is not None else ["- unknown: query failed."]
    if NOTIFICATIONS:
        add_section("Notifications outside the repo list", lines, len(lines) if notifications is not None else "unknown")
    internal_source = INTERNAL_SOURCE or {}
    internal_host = internal_source["host"] if INTERNAL_TRACKER else None
    internal_repo = internal_source["repo"] if INTERNAL_TRACKER else None
    internal = client.search(f"repo:{internal_repo} updated:>={since}", host=internal_host) if INTERNAL_TRACKER else []
    identity = client.gh("api", "user", host=internal_host) if internal else None
    internal_me = identity.get('login') if isinstance(identity, dict) else None
    if internal and (not isinstance(internal_me, str) or not re.fullmatch(r'[\w-]+', internal_me)):
        internal_me = None
        client.fail('internal identity', 'internal actor accounting unknown; identity unavailable')
    for item in internal or []:
        if internal_me:
            activity.record(item, item["user"], "opened PR" if "pull_request" in item else "opened issue",
                            item.get("created_at"), 1 if "pull_request" in item else 0, me=internal_me)
    lines = ([item_line(it) for it in internal] +
             new_comments(client, internal, since, host=internal_host,
                          activity=activity if internal_me else None, me=internal_me)
             if internal is not None else ["- unknown: host unavailable or query failed."])
    if INTERNAL_TRACKER:
        if internal and internal_me is None:
            lines.append('- Actor accounting unknown: internal identity unavailable.')
        add_section(f"Internal tracker ({internal_host})", lines, len(lines) if internal is not None else "unknown")
    # Run last so the new lookups cannot consume existing activity's lookup budget.
    # The upstream-merge section is author-filtered; cover the remaining PRs here too.
    upstream = client.search(f"{own} is:pr is:merged merged:>={since} -author:{me}") if own else []
    for item in upstream or []:
        key = (item_repo(item), item["number"])
        author = item["user"]
        if key not in merged and is_human(author.get("login"), author.get("type")):
            merged[key] = client.gh("api", f"repos/{key[0]}/pulls/{key[1]}")
    lines = referenced_open_issues(activity, merged)
    if upstream is None or any(count == "unknown" for title, count in counts
                               if title in {"Merged", "Your upstream merges"}):
        lines.append("- unknown: merged-PR search failed; issue references may be missing.")
    count = (f'{len(lines)-1} reported; {activity.referenced_not_checked} not checked'
             if activity.referenced_not_checked else len(lines))
    add_section("Open issues referenced by PRs merged since the last run", lines, count)
    lines = []
    # The fixed watchlist has its own budget: exactly one issue read per watched item.
    for repo, number in WATCH:
        item = client.gh("api", f"repos/{repo}/issues/{number}")
        label = f"{repo}#{number}"
        if item is None:
            lines.append(f"- {label}: unknown (query failed).")
            continue
        merged_at = (item.get("pull_request") or {}).get("merged_at")
        status = (f"merged {safe_text(merged_at)}" if merged_at else f"closed {safe_text(item['closed_at'])}"
                  if item["state"] == "closed" else f"open, updated {safe_text(item['updated_at'])}")
        lines.append(f"- {label} {safe_text(item['title'])}: {status}")
    add_section("Watched items", lines, len(WATCH))
    for series in TRACKED_SERIES:
        tracker = ROOT / pathlib.Path(series["tracker"]).expanduser()
        lines, count = ["- unknown: tracker read or issue query failed."], "unknown"
        try:
            with io.StringIO(read_text(tracker), newline='') as handle:
                rows = csv.DictReader(handle, strict=True)
                if "issue" not in (rows.fieldnames or []):
                    raise ValueError("tracker must have an issue column")
                tracked = {int(row["issue"]) for row in rows}
        except (OSError, UnicodeError, csv.Error, ValueError, TypeError) as error:
            client.fail(str(tracker), error)
        else:
            items = client.pages(f"repos/{series['repo']}/issues", state="open")
            if items is not None:
                lines = [f"- [{series['repo']}#{it['number']}]({safe_url(it['html_url'])}) {safe_text(it['title'])} ({safe_text(it['created_at'])})"
                         for it in items if "pull_request" not in it and it["state"] == "open"
                         and it["title"].startswith(series["title"]) and it["number"] not in tracked]
                count = len(lines)
        add_section(f"Untriaged: {safe_text(series['title'])}", lines, count)
    output.append(failure_section(client.failures))
    return "\n".join([f"# Morning sweep since {since}\n", activity.summary(counts), *output])


def lane_for_ref(state, repo, number):
    for line in state.splitlines():
        # The first cell of an open-lane row identifies the owner, not a lane mentioned later.
        owner = re.match(rf"\|\s*({lane_pattern()})\s*\|", line)
        if owner and any(r["repo"] == repo and r["number"] == number for r in parse_pr_refs(line)):
            return owner[1]
    return "unknown-owner"


def red_age(checks, now):
    dates = [c.get("completedAt") or c.get("createdAt") for c in checks
             if (c.get("conclusion") or c.get("state")) in BAD_CHECKS]
    dates = [dt.datetime.fromisoformat(d.replace("Z", "+00:00")) for d in dates if d]
    return f"{max(0, int((now - min(dates)).total_seconds() / 3600))}h" if dates else "unknown-age"


def old_folders(state, now, budget):
    folders = []
    candidates = list(itertools.islice((path for path in ROOT.glob('w*') if path.is_dir()), 101))
    if len(candidates) > 100:
        raise ObservationError('folder candidates truncated')
    visited = 0
    for folder in sorted(candidates):
        if folder_named(state, folder.name):
            continue
        newest, size = folder.stat().st_mtime, 0
        cutoff = now.timestamp() - 14 * 86400
        if newest >= cutoff or folder.is_symlink():
            continue
        # Do not follow symlinks into other worktrees or count their targets.
        for base, directories, files in os.walk(folder):
            visited += len(directories) + len(files) + 1
            if visited > 10000 or budget.remaining() <= 0:
                raise ObservationError('folder traversal budget exhausted')
            directories[:] = [d for d in directories if not pathlib.Path(base, d).is_symlink()]
            for name in directories + files:
                try:
                    stat = pathlib.Path(base, name).lstat()
                    newest = max(newest, stat.st_mtime)
                    size += stat.st_size
                except OSError as error:
                    raise ObservationError('folder entry unreadable; coverage unknown') from error
            if newest >= cutoff:
                break
        if newest < cutoff:
            folders.append((folder.name, size))
    return folders


def drift(client, state, now, me):
    """Compact receipt: every qualified reference remains visible, even offline."""
    checkout_text = checkout_observations(client)
    try:
        sha = run_read(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'],
                       timeout=10, budget=client.budget).strip()
    except (OSError, ValueError):
        sha = 'unknown'
        client.fail('local STATE commit', 'git read failed; identity unknown', activity=False)
    refs = parse_pr_refs(state)
    claims, flags, seen, kinds = [], [], set(), {}
    issue_count = 0
    for ref in refs:
        repo, number = ref["repo"], ref["number"]
        label = f"{ref['alias']}#{number}"
        if repo and (repo, number) not in kinds:
            # Short issue and PR references look identical in prose. Classify before PR reads.
            kinds[repo, number] = client.gh("api", f"repos/{repo}/issues/{number}")
        item = kinds.get((repo, number))
        is_issue = item is not None and "pull_request" not in item
        data = client.pr(repo, number) if item and not is_issue else None
        key = (repo or ref["alias"], number)
        if key not in seen:
            seen.add(key)
            if data:
                claims.append(f"- {label}: {data['state']} draft={'yes' if data['isDraft'] else 'no'} "
                              f"head={data['headRefOid'][:8]} checks={checks_summary(data['statusCheckRollup'])}")
            elif is_issue:
                issue_count += 1
            else:
                claims.append(f"- {label}: unknown")
        if data:
            if data["state"] in {"MERGED", "CLOSED"} and reads_as_waiting(ref["line"], ref):
                flags.append(f"L{ref['lineno']}:{label}-{data['state'].lower()}-but-waiting")
            written = written_head(ref)
            if written and not data["headRefOid"].startswith(written):
                flags.append(f"L{ref['lineno']}:{label}-head-differs-from-{written}")
    mine = client.search(" ".join(f"repo:{r}" for r in REPOS) + f" is:pr is:open author:{me}") if me is not None else None
    red = []
    for item in mine or []:
        repo, number = item_repo(item), item["number"]
        data = client.pr(repo, number)
        if data is None:
            red.append(f"{repo}#{number}:unknown")
        elif checks_summary(data["statusCheckRollup"]) == "red":
            red.append(f"{lane_for_ref(state, repo, number)}:{repo}#{number}:{red_age(data['statusCheckRollup'], now)}")
    def read_local(name, shared=False):
        path = ROOT / name
        try:
            try:
                return read_text(path)
            except FileNotFoundError:
                if shared and SHARED_ROOT != ROOT:
                    path = SHARED_ROOT / name
                    return read_text(path)
                raise
        except (OSError, ValueError, UnicodeError) as error:
            client.fail(str(path), error, activity=False)
            return ""

    archive = None
    try:
        paths = list(itertools.islice(ROOT.glob('CLOSED-*.md'), 101))
        if not paths and SHARED_ROOT != ROOT:
            paths = list(itertools.islice(SHARED_ROOT.glob('CLOSED-*.md'), 101))
        if not paths or len(paths) > 100:
            raise ObservationError('archive coverage unavailable or truncated')
        archive = '\n'.join(read_text(p) for p in sorted(paths))
    except (OSError, ValueError, UnicodeError):
        client.fail('closed archives', 'archive coverage unknown', activity=False)
    owners = [f"L{line}:{owner}" for line, owner, _ in closed_lane_owners(state, archive)] if archive is not None else None
    header, newest = state_dates(state)
    documents = {name: read_local(f"{name}.md", shared=name in {"AGENTS", "PEOPLE"})
                 for name in ("AGENTS", "COORDINATION", "PEOPLE")}
    documents["STATE"] = state
    open_table = state.split("## Open lanes", 1)[-1].split("\n## ", 1)[0]
    lanes = re.findall(rf"^\|\s*({lane_pattern()})\s*\|", open_table, re.MULTILINE)
    prompts = {}
    for lane in lanes:
        matches = list((ROOT / "lanes").glob(f"{lane}-*.md"))
        if len(matches) == 1:
            prompts[lane] = read_local(str(matches[0].relative_to(ROOT)))
    budgets = budget_counts(documents, prompts)
    budget_text = [f"{name}={count}/{limit}{'!' if over else ''}" for name, count, limit, over in budgets
                   if name in documents or over]
    try:
        folders = old_folders(state, now, client.budget)
    except (OSError, ValueError):
        folders = None
        client.fail('old folders', 'folder coverage unknown', activity=False)
    folder_text = ('\n'.join(f'{name}\t{size} bytes' for name, size in folders) + '\n') if folders is not None else 'unknown: folder coverage incomplete\n'
    disk_text = disk_observations(client)
    lines = ["# STATE drift", f"Observed UTC: {now.isoformat()}; local: {now.astimezone().isoformat()}.",
             f"STATE commit: {sha}", checkout_text]
    lines.append(failure_section(client.failures) if client.failures else "Failed queries: none.")
    lines += ["## STATE PR claims vs GitHub", "\n".join(claims),
              f"{issue_count} issue references omitted (not PRs).",
              "Heads are abbreviated. Checks=none means no reported checks, not a passing CI assertion. "
              "Issue shorthand is classified before looking for PR metadata; unknown aliases are never guessed.",
              "## Drift flags", " ".join(dict.fromkeys(flags)) or "None.",
              "## Red PRs by lane", " ".join(red) if mine is not None else "unknown: authored-PR search failed.",
              "List only; no forwarding. Ages measure hours since failing-check completion (status-context creation if unavailable).",
              "## Closed-lane owners", (" ".join(owners) or "None found outside closed sections.") if owners is not None else "unknown: archive coverage unavailable.",
              "## Dates", f"Header={header}; newest-row-date={newest}." +
              (" Flag: row date is newer (possibly planned work)." if header != "unknown" and newest != "unknown" and newest > header else ""),
              "## Budgets", " ".join(budget_text),
              "Words/upper-limit; ! flags excess. STATE uses the 1,600-word inspection threshold. Lane prompts shown only above 800 words.",
              "## Old folders", (f"{len(folders)} folders; {sum(s for _, s in folders) / 2**20:.1f} MiB; full list: STATE-DRIFT-folders.txt." if folders is not None else "unknown: folder coverage incomplete."),
              disk_text, "## Next actions", "Coordinator reconciles stale waits, heads and owners; checks unknown queries before treating this receipt as current. "
              "Budget flags invite trimming receipts, not deleting unresolved decisions. This check is advisory and does not edit STATE or its last-run stamp."]
    receipt = "\n\n".join(lines) + "\n"
    return receipt, folder_text


def configured_path(value):
    try:
        return (ROOT / pathlib.Path(value).expanduser()).resolve()
    except RuntimeError as error:
        raise ObservationError('configured path cannot be resolved') from error


def local_unknown(client, lines, label, error):
    client.fail(label, error, activity=False)
    lines.append(f'- {safe_text(label)}: unknown ({safe_text(error)}).')


def checkout_observations(client):
    """Observe primary checkouts and bounded same-repository PR candidates; never prune."""
    lines, inventories = [], {}
    mapping = GitHub(client.budget)
    query = '''query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
      open:pullRequests(first:100,states:[OPEN],orderBy:{field:UPDATED_AT,direction:DESC}){
        pageInfo{hasNextPage} nodes{number state headRefName headRefOid headRepository{nameWithOwner} url}}
      closed:pullRequests(first:100,states:[CLOSED,MERGED],orderBy:{field:UPDATED_AT,direction:DESC}){
        pageInfo{hasNextPage} nodes{number state headRefName headRefOid headRepository{nameWithOwner} url}}}}'''

    def inventory(repo):
        if repo not in inventories:
            owner, name = repo.split('/')
            data = mapping.gh('api', 'graphql', '-f', 'query='+query, '-f', 'owner='+owner, '-f', 'name='+name)
            if data is None:
                raise ObservationError('PR inventory unavailable')
            connections = data['data']['repository']
            for key, states in (('open', {'OPEN'}), ('closed', {'CLOSED', 'MERGED'})):
                connection = connections[key]
                if (not isinstance(connection['nodes'], list) or len(connection['nodes']) > 100
                        or type(connection['pageInfo']['hasNextPage']) is not bool):
                    raise ObservationError('malformed PR inventory')
                for pr in connection['nodes']:
                    if (type(pr['number']) is not int or pr['number'] <= 0 or pr['state'] not in states
                            or not isinstance(pr['headRefName'], str)
                            or not re.fullmatch(r'[0-9a-f]{40}', pr['headRefOid'])
                            or pr['headRepository'] is not None and not isinstance(pr['headRepository']['nameWithOwner'], str)):
                        raise ObservationError('malformed PR identity')
            inventories[repo] = connections
        return inventories[repo]

    def match(repo, branch):
        connections = inventory(repo)
        incomplete = {key: connection['pageInfo']['hasNextPage'] or any(p['headRepository'] is None for p in connection['nodes'])
                      for key, connection in connections.items()}
        matches = [[p for p in connections[key]['nodes'] if p['headRepository'] is not None
                    and p['headRepository']['nameWithOwner'].casefold() == repo.casefold()
                    and p['headRefName'] == branch] for key in ('open', 'closed')]
        candidates = matches[0] or matches[1]
        if incomplete['open'] or not matches[0] and incomplete['closed']:
            return 'unknown: partial PR inventory; observed ' + ', '.join(f"{p['state']} #{p['number']}" for p in candidates)
        if len(candidates) > 1:
            return 'unknown: ambiguous PR matches'
        if not candidates:
            return 'unknown: no open/recent closed match; not proof of merge/deletion'
        pr = candidates[0]
        return f"{pr['state']} [#{pr['number']}]({safe_url(pr['url'])}) head={pr['headRefOid'][:12]} (observed, not a cleanup decision)"

    for checkout in CHECK_SETTINGS.get('checkouts', []):
        repo = checkout['repo']
        try:
            path = configured_path(checkout['path'])
            status = run_read(['git', '-C', str(path), 'status', '--porcelain=v2', '--branch', '-z'], timeout=10, budget=client.budget)
            if not status.endswith('\0'):
                raise ObservationError('incomplete status output')
            fields = status.rstrip('\0').split('\0')
            headers = {}
            for field in fields:
                if not field.startswith('# '):
                    break  # Rename-source paths are data, even if they look like headers.
                key, value = field[2:].split(' ', 1)
                headers[key] = value
            head, branch = headers['branch.oid'], headers['branch.head']
            if head != '(initial)' and not re.fullmatch(r'[0-9a-f]{40}', head):
                raise ObservationError('unknown primary HEAD')
            tracking = headers.get('branch.upstream', 'not configured') + ' ' + headers.get('branch.ab', 'unknown')
            dirty = any(not field.startswith('# ') for field in fields)
            lines.append(f'- {safe_text(repo)} primary {safe_text(path)}: {safe_text(branch)} HEAD={head[:12]} '
                         f"{'dirty' if dirty else 'clean'}; tracking {safe_text(tracking)} (local ref only; no fetch).")
            raw = run_read(['git', '-C', str(path), 'worktree', 'list', '--porcelain', '-z'], timeout=10, budget=client.budget)
            if not raw.endswith('\0\0'):
                raise ObservationError('incomplete worktree list')
            records = raw[:-2].split('\0\0')
            if len(records) > 100:
                raise ObservationError('worktree list truncated at 100 candidates')
            for record in records:
                entry = {part.partition(' ')[0]: part.partition(' ')[2] for part in record.split('\0')}
                location = pathlib.Path(entry['worktree'])
                flags = [name for name in ('detached', 'bare', 'prunable', 'locked') if name in entry]
                if not location.is_dir():
                    flags.append('missing')
                if flags:
                    detail = 'unknown/not mapped: ' + ', '.join(flags)
                else:
                    ref, oid = entry['branch'], entry['HEAD']
                    if not ref.startswith('refs/heads/') or not re.fullmatch(r'[0-9a-f]{40}', oid):
                        raise ObservationError('malformed worktree identity')
                    detail = safe_text(ref[11:]) + ' local-head=' + oid[:12] + ': ' + match(repo, ref[11:])
                lines.append(f'- Worktree {safe_text(location)}: {detail}')
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            local_unknown(client, lines, repo, error)
    client.failures.extend(mapping.failures)
    return section('Checkout/worktrees', lines or ['- not checked: not configured.'])


def disk_observations(client):
    """Measure only configured resources; inspection completion is not cache health."""
    disk = CHECK_SETTINGS.get('disk', {})
    if not disk:
        return section('Disk', ['- not checked: not configured.'])
    budget = Budget(seconds=min(120, client.budget.remaining()) + 5, queries=0, clock=client.budget.clock)
    lines = []

    def read(argv, timeout):
        return run_read(argv, timeout=timeout, budget=budget, environment={'LC_ALL': 'C'})

    def size(path):
        raw = read(['du', '-sk', str(path)], 20)
        match = re.match(r'^(\d+)\s', raw)
        if match is None:
            raise ObservationError('malformed du measurement')
        return int(match[1])

    if 'filesystem' in disk:
        try:
            path = configured_path(disk['filesystem'])
            rows = read(['df', '-Pk', str(path)], 10).splitlines()
            row = re.fullmatch(r'.+?\s+(\d+)\s+(-?\d+)\s+(-?\d+)\s+\d+%\s+.+', rows[1]) if len(rows) == 2 else None
            if row is None:
                raise ObservationError('malformed df measurement')
            available, floor = int(row[3]), disk.get('minimum_free_gib', 50)
            lines.append(f'- Filesystem {safe_text(path)}: available={available} KiB ({available / 1024**2:.2f} GiB); floor={floor} GiB.'
                         + (' Needs the human: below free-space floor.' if available < floor * 1024**2 else ''))
        except (OSError, ValueError, TypeError) as error:
            local_unknown(client, lines, 'filesystem', error)
    else:
        lines.append('- Filesystem: not checked (not configured).')
    roots, candidates, sizes = disk.get('output_roots', []), set(), []
    partial = False
    for value in dict.fromkeys(roots):
        try:
            with os.scandir(configured_path(value)) as entries:
                for entry in entries:
                    if budget.remaining() <= 0:
                        raise ObservationError('disk time budget exhausted')
                    if entry.is_dir(follow_symlinks=False):
                        candidates.add(pathlib.Path(entry.path))
                        if len(candidates) > 100:
                            raise ObservationError('output candidates exceed 100; coverage partial')
        except (OSError, ValueError) as error:
            partial = True
            local_unknown(client, lines, 'output root', error)
            if len(candidates) > 100:
                break
    # Keep outer candidates, not nested duplicate totals from overlapping roots.
    candidates = {p for p in candidates if not any(parent in candidates for parent in p.parents)}
    for path in sorted(candidates)[:100]:
        try:
            sizes.append((size(path), path))
        except (OSError, ValueError) as error:
            partial = True
            local_unknown(client, lines, 'output folder', error)
    lines.append('- Output folders: ' + ('partial ranking; omissions/failed measurements unknown.' if partial else
                                       'five largest measured immediate directories.' if roots else 'not checked (not configured).'))
    lines += [f'- {safe_text(path)}: {kib} KiB' for kib, path in sorted(sizes, key=lambda x: (-x[0], str(x[1])))[:5]]
    for name in ('go', 'uv', 'npm'):
        if name not in disk.get('caches', {}):
            lines.append(f'- {name} cache: not checked (not configured).')
            continue
        try:
            path = configured_path(disk['caches'][name])
            path.stat()  # exists() suppresses permission errors on newer Python versions.
            if not path.is_dir():
                raise ObservationError('cache path is not a directory')
            lines.append(f'- {name} cache {safe_text(path)}: {size(path)} KiB')
        except FileNotFoundError:
            lines.append(f'- {name} cache: absent (not measured zero).')
        except (OSError, ValueError) as error:
            local_unknown(client, lines, name+' cache', error)
    if 'cache_check_checkout' in disk:
        try:
            output = read(['make', '-s', '--no-print-directory', '-C', str(configured_path(disk['cache_check_checkout'])), 'cache-maintenance-check'], 20)
            if len(output) > MAX_TEXT:
                raise ObservationError('cache inspection output exceeds text bound')
            if 'cache-maintenance: not installed;' in output:
                result = 'not installed (not healthy)'
            elif 'cache-maintenance: service has never run' in output:
                result = 'never run (not healthy)'
            else:
                properties = dict(line.split('=', 1) for line in output.splitlines()
                                  if line.startswith(('Result=', 'ExecMainStatus=', 'ExecMainStartTimestamp=')))
                known = {'success', 'resources', 'timeout', 'exit-code', 'signal', 'core-dump', 'watchdog', 'start-limit-hit', 'oom-kill', 'protocol', 'exec-condition'}
                if (properties.get('Result') not in known or not properties.get('ExecMainStatus', '').isdigit()
                        or not properties.get('ExecMainStartTimestamp')):
                    raise ObservationError('unrecognized cache inspection; health unknown')
                result = 'last run successful; timer health not inferred' if properties['Result'] == 'success' and properties['ExecMainStatus'] == '0' else 'last run failed'
            lines.append('- Cache maintenance: '+result+'.')
            lines += ['  '+safe_text(line) for line in output.splitlines()]
        except (OSError, ValueError) as error:
            local_unknown(client, lines, 'cache maintenance', error)
    else:
        lines.append('- Cache maintenance: not checked (not configured).')
    return section('Disk', lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, help='workspace with coordination.json (default: cwd)')
    parser.add_argument('--since', help='ISO activity boundary; otherwise saved stamp or preceding 24h')
    parser.add_argument('--me', help='GitHub login: CLI > config > authenticated identity')
    parser.add_argument('--no-save', action='store_true', help='do not advance sweep stamp; --check still writes receipts')
    parser.add_argument('--check', action='store_true', help='write STATE-DRIFT.md and folder list; never advance activity stamp')
    args = parser.parse_args(argv)
    try:
        configure(workspace_root(args.root))
        if args.me is not None and not re.fullmatch(r'[\w-]+', args.me):
            raise ValueError('--me must be a GitHub login')
    except (OSError, ValueError, UnicodeError) as error:
        parser.error(f'Cannot load project configuration: {error}')
    now = dt.datetime.now(dt.timezone.utc)
    client = GitHub()
    me = args.me or ME
    if args.check:
        try:
            state = read_text(ROOT / 'STATE.md')
        except (OSError, ValueError, UnicodeError) as error:
            print(f'Cannot read STATE: {type(error).__name__}')
            return 1
    else:
        try:
            since = args.since or (read_text(STAMP).strip() if STAMP.exists() else
                                  (now - dt.timedelta(days=1)).strftime('%Y-%m-%dT%H:%MZ'))
            parsed = dt.datetime.fromisoformat(since.replace('Z', '+00:00'))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            since = parsed.astimezone(dt.timezone.utc).isoformat().replace('+00:00', 'Z')
        except (OSError, ValueError, UnicodeError) as error:
            parser.error(f'Cannot read activity boundary: {type(error).__name__}')
    if me is None:
        identity = client.gh('api', 'user')
        me = identity.get('login') if isinstance(identity, dict) else None
        if not isinstance(me, str) or not re.fullmatch(r'[\w-]+', me):
            client.fail('identity', 'authenticated identity unknown; dependent activity not checked')
            if not args.check:
                print('# Morning observation\n\nActivity unknown: identity lookup failed.\n' + failure_section(client.failures))
                print(disk_observations(client))
                return 0
            # Non-author-specific STATE claims can still be recorded honestly.
            me = None
    try:
        if args.check:
            receipt, folders = drift(client, state, now, me)
            print(receipt)
            try:
                atomic_write(ROOT / 'STATE-DRIFT-folders.txt', folders)
            except OSError:
                receipt += '\nFolder list publication failed: previous sidecar may be stale.\n'
                # Preserve the report's usable current observation and disclose stale sidecar.
                atomic_write(ROOT / 'STATE-DRIFT.md', receipt)
                print('Folder list publication failed; previous file retained.')
                return 1
            atomic_write(ROOT / 'STATE-DRIFT.md', receipt)
            return 0
        report = sweep(client, since, me)
    except (KeyError, TypeError, IndexError, ValueError, OSError, AttributeError) as error:
        client.fail('observation', f'incomplete input/result: {type(error).__name__}')
        print('# Morning observation\n\nActivity unknown.\n' + failure_section(client.failures))
        print(section('Disk', ['- unknown: observation aborted before local checks.'] if CHECK_SETTINGS.get('disk') else ['- not checked: not configured.']))
        return 1 if args.check else 0
    print(report)
    print(section('Checkout/worktrees', ['- not checked: use --check.'] if CHECK_SETTINGS.get('checkouts') else ['- not checked: not configured.']))
    print(disk_observations(client))
    print(f'\nObserved UTC: {now.isoformat()}; queries: {client.budget.request_count}/{client.budget.queries}.')
    if client.activity_failures:
        print('Last-run stamp unchanged: activity incomplete; repair unknown queries or narrow --since for recovery.')
    elif not args.no_save:
        try:
            atomic_write(STAMP, now.strftime('%Y-%m-%dT%H:%MZ'))
        except OSError:
            print('Last-run stamp publication failed; previous boundary retained.')
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
