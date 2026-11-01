#!/usr/bin/env python3
"""Run one weekly review: gather evidence, review in a sandbox, publish a PR.

The agent never holds publishing rights. It runs inside bubblewrap with no shell
or network tools, sees only a fresh clone and an evidence snapshot, and has no
access to gh credentials or private folders. This process then applies a path
policy and a secret scan before it commits, pushes and opens the PR. Agent-written
code is never executed on this machine; the PR's own CI is the test gate.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

HOME = Path.home()
DOTFILES = Path(__file__).resolve().parent.parent
PROMPTS = DOTFILES / "tools" / "automations" / "prompts"
GUARD = DOTFILES / "tools" / "automations" / "guard.ts"
STATE_ROOT = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local" / "state")) / "dotfiles-automations"
KNOWLEDGE_CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "dotfiles" / "agent-knowledge.json"
PI_AGENT = HOME / ".pi" / "agent"

AGENT_TIMEOUT_SECONDS = 45 * 60
MAX_REPORT_BYTES = 60_000
MAX_FIX_FILES = 12
MAX_FIX_LINES = 300
MAX_EVIDENCE_FILE_BYTES = 200_000
AGENT_TOOLS = "read,write,edit,grep,find,ls"

# Fixes here change how the machine or this automation is trusted, so they are
# always downgraded to a recommendation in the report.
PROTECTED_PREFIXES = (
    ".github/",
    "bin/",
    "core/git/",
    "config/mise/",
    "ai/pi/extensions/",
    "tools/automations/",
)
PROTECTED_FILES = frozenset(
    {
        "Makefile",
        "config/versions.env",
        "libexec/automation_run.py",
        "ai/pi/install.sh",
        "ai/pi/settings.json",
        "ai/pi/config/permission-system.json",
    }
)

SECRET_PATTERNS = (
    re.compile(r"\bgh[opusr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
)

LANE_SKILLS = ("lane-coordinator", "pr-closeout", "adversarial-review", "second-opinion-core", "polish-core")
# PEOPLE.md stays out: reviewing process does not need notes about individuals,
# and this report leaves the machine.
LANE_FILES = ("AGENTS.md", "STATE.md", "COORDINATION.md", "lanes/COMMON-RULES.md")
LANE_ACTIVITY_DIRS = ("lanes", "process-review", "reports", "agent-notes")
LANE_ACTIVITY_DAYS = 7
LANE_ACTIVITY_FILES = 15
LANE_ACTIVITY_LINES = 80


class AutomationError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Profile:
    name: str
    title: str
    report_path: str
    fixes_allowed: bool
    private_only: bool


PROFILES = {
    "dotfiles-health": Profile(
        "dotfiles-health", "Weekly dotfiles health", "docs/automation-reports/dotfiles-health.md", True, False
    ),
    "tooling-radar": Profile(
        "tooling-radar", "Weekly tooling radar", "docs/automation-reports/tooling-radar.md", True, False
    ),
    "lane-review": Profile("lane-review", "Weekly lane review", "automation-reports/lane-review.md", False, True),
}


# ── Pure policy ──────────────────────────────────────────────────────────────


def repo_slug(url: str) -> str:
    match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", url.strip())
    if not match:
        raise AutomationError(f"not a GitHub remote: {url}")
    return match.group(1)


def is_protected(path: str) -> bool:
    return path in PROTECTED_FILES or path.startswith(PROTECTED_PREFIXES)


def downgrade_reason(
    profile: Profile,
    fix_paths: list[str],
    changed_lines: int,
    has_symlink: bool,
) -> str | None:
    """Return why fixes must be dropped so only the report is published."""
    if not fix_paths:
        return None
    if not profile.fixes_allowed:
        return "this automation publishes reports only"
    protected = sorted(path for path in fix_paths if is_protected(path))
    if protected:
        return "fixes touched protected paths: " + ", ".join(protected)
    if has_symlink:
        return "fixes added a symlink"
    if len(fix_paths) > MAX_FIX_FILES:
        return f"fixes touched {len(fix_paths)} files (limit {MAX_FIX_FILES})"
    if changed_lines > MAX_FIX_LINES:
        return f"fixes changed {changed_lines} lines (limit {MAX_FIX_LINES})"
    return None


def collect_secret_literals(value: object) -> set[str]:
    if isinstance(value, str):
        return {value} if len(value) >= 16 else set()
    if isinstance(value, dict):
        return set().union(*(collect_secret_literals(item) for item in value.values()), set())
    if isinstance(value, list):
        return set().union(*(collect_secret_literals(item) for item in value), set())
    return set()


def secret_hit(text: str, literals: set[str]) -> str | None:
    """Name what matched without echoing the secret into the logs."""
    for pattern in SECRET_PATTERNS:
        if pattern.search(text):
            return f"pattern {pattern.pattern[:24]}"
    if any(literal in text for literal in literals):
        return "a credential value from auth.json"
    return None


def filter_automation_prs(prs: list[dict], name: str) -> list[dict]:
    prefix = f"automation/{name}/"
    return [pr for pr in prs if pr.get("headRefName", "").startswith(prefix)]


def pr_body(report: str, note: str | None, fix_paths: list[str]) -> str:
    footer = ["---", "Generated by `tools/automations`. Close without merging to reject; comments are read next run."]
    if note:
        footer.insert(1, f"Fixes were dropped: {note}.")
    elif fix_paths:
        footer.insert(1, "Applied fixes: " + ", ".join(f"`{path}`" for path in fix_paths) + ".")
    return report.strip()[:MAX_REPORT_BYTES] + "\n\n" + "\n".join(footer) + "\n"


def sandbox_args(
    *,
    home: Path,
    repo: Path,
    evidence: Path,
    agent_dir: Path,
    guard: Path,
    node_root: Path,
    resolv: Path,
    pi_agent: Path,
) -> list[str]:
    """Build a bubblewrap allowlist. Everything unlisted, including $HOME, is absent."""
    args = ["bwrap", "--die-with-parent", "--unshare-pid", "--unshare-ipc"]
    for path in ("/usr", "/bin", "/lib", "/etc"):
        args += ["--ro-bind", path, path]
    args += ["--ro-bind-try", "/lib64", "/lib64"]
    args += ["--ro-bind", str(resolv), str(resolv)]
    args += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/run", "--tmpfs", str(home)]
    args += ["--ro-bind", str(pi_agent / "bin"), str(pi_agent / "bin")]
    args += ["--ro-bind", str(pi_agent / "install"), str(pi_agent / "install")]
    args += ["--ro-bind", str(node_root), str(node_root)]
    args += ["--bind", str(agent_dir), str(agent_dir)]
    args += ["--bind", str(repo), str(repo)]
    # Read-only: a writable .git would let the agent plant hooks or config that
    # the publishing step, which runs outside the sandbox, would then execute.
    args += ["--ro-bind", str(repo / ".git"), str(repo / ".git")]
    args += ["--ro-bind", str(evidence), str(evidence)]
    args += ["--ro-bind", str(guard), str(guard)]
    return args


def render_prompt(template: str, *, report: str, evidence: Path, repo: Path, date: str) -> str:
    return (
        template.replace("{{REPORT}}", report)
        .replace("{{EVIDENCE}}", str(evidence))
        .replace("{{REPO}}", str(repo))
        .replace("{{DATE}}", date)
    )


# ── Process helpers ──────────────────────────────────────────────────────────


def run(cmd: list[str], *, cwd: Path | None = None, timeout: int = 120) -> str:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode != 0:
        raise AutomationError(f"{cmd[0]} {cmd[1] if len(cmd) > 1 else ''} failed: {result.stderr.strip()[:500]}")
    return result.stdout


def observe(cmd: list[str], *, cwd: Path | None = None, timeout: int = 60) -> str:
    """Capture evidence. A failure becomes visible text, never an invented result."""
    try:
        result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"UNKNOWN: {' '.join(cmd)} did not complete: {type(error).__name__}\n"
    if result.returncode != 0:
        return f"UNKNOWN: {' '.join(cmd)} exited {result.returncode}\n{result.stderr[:500]}\n{result.stdout[:2000]}\n"
    return result.stdout


def git(repo: Path, *args: str, timeout: int = 120) -> str:
    # The agent could write tracked files, so nothing in the worktree may steer git here.
    hardened = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", str(repo)]
    return run(hardened + list(args), timeout=timeout)


def write_evidence(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text[:MAX_EVIDENCE_FILE_BYTES], encoding="utf-8", errors="replace")


def read_head(path: Path, lines: int) -> str:
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            return "".join(line for _, line in zip(range(lines), handle))
    except OSError as error:
        return f"UNKNOWN: {error}\n"


# ── Evidence ─────────────────────────────────────────────────────────────────


def gather_previous_prs(evidence: Path, slug: str, name: str) -> None:
    raw = observe(
        [
            "gh", "pr", "list", "-R", slug, "--state", "all", "--limit", "200",
            "--json", "number,title,state,mergedAt,headRefName,body,comments,url",
        ]
    )
    try:
        prs = filter_automation_prs(json.loads(raw), name)[:4]
    except json.JSONDecodeError:
        write_evidence(evidence / "previous-prs.md", raw)
        return
    sections = []
    for pr in prs:
        comments = "\n".join(f"- {item.get('body', '')[:1000]}" for item in pr.get("comments", []))
        sections.append(
            f"## #{pr['number']} {pr['title']} ({pr['state']})\n\n"
            f"Comments:\n{comments or 'none'}\n\nBody:\n{pr.get('body', '')[:6000]}\n"
        )
    write_evidence(evidence / "previous-prs.md", "\n".join(sections) or "No previous runs.\n")


def gather_dotfiles_health(evidence: Path, repo: Path) -> None:
    write_evidence(evidence / "history.txt", git(repo, "log", "--since=30.days", "--format=%as %s", "--name-only"))
    sizes = observe(["bash", "-c", "git ls-files -z | xargs -0 wc -l | sort -rn | head -60"], cwd=repo)
    write_evidence(evidence / "largest-files.txt", sizes)
    write_evidence(evidence / "pins-check.txt", observe(["make", "-s", "-C", str(DOTFILES), "pins-check"], timeout=180))


def npm_search(text: str, size: int = 40) -> str:
    query = urllib.parse.urlencode({"text": text, "size": size})
    url = f"https://registry.npmjs.org/-/v1/search?{query}"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            objects = json.load(response).get("objects", [])
    except (OSError, ValueError) as error:
        return f"UNKNOWN: npm search failed: {error}\n"
    rows = []
    for item in objects:
        package = item.get("package", {})
        rows.append(f"{package.get('name')} {package.get('version')} {package.get('date', '')[:10]}: {package.get('description', '')[:200]}")
    return "\n".join(rows) + "\n"


def gather_package_changes(evidence: Path) -> None:
    sections = []
    npm_root = PI_AGENT / "npm" / "node_modules"
    settings = json.loads((PI_AGENT / "settings.json").read_text(encoding="utf-8"))
    for entry in settings.get("packages", []):
        source = entry["source"] if isinstance(entry, dict) else entry
        if source.startswith("npm:"):
            package = source.removeprefix("npm:")
            root = npm_root / package
            version = "unknown"
            try:
                version = json.loads((root / "package.json").read_text(encoding="utf-8")).get("version", "unknown")
            except (OSError, ValueError):
                pass
            latest = observe(["npm", "view", package, "version"], timeout=30).strip()
            changelog = read_head(root / "CHANGELOG.md", 60) if (root / "CHANGELOG.md").exists() else "No CHANGELOG.\n"
            sections.append(f"## {package}\nInstalled {version}; registry {latest}\n\n{changelog}")
        elif source.startswith("git:"):
            root = PI_AGENT / "git" / source.removeprefix("git:").split("@")[0]
            log = observe(["git", "-C", str(root), "log", "-12", "--format=%as %s"])
            sections.append(f"## {source}\nInstalled history:\n{log}")
    write_evidence(evidence / "pi-packages.md", "\n".join(sections))


def gather_tooling_radar(evidence: Path, repo: Path) -> None:
    pi_version = observe(["pi", "--version"]).strip()
    versions = f"pi {pi_version}\nregistry pi {observe(['npm', 'view', '@earendil-works/pi-coding-agent', 'version'], timeout=30)}"
    versions += observe(["herdr", "--version"])
    write_evidence(evidence / "versions.txt", versions)
    write_evidence(evidence / "pi-list.txt", observe(["pi", "list"]))
    write_evidence(evidence / "pins-check.txt", observe(["make", "-s", "-C", str(DOTFILES), "pins-check"], timeout=180))
    gather_package_changes(evidence)

    pi_package = PI_AGENT / "install" / "releases" / pi_version / "node_modules" / "@earendil-works" / "pi-coding-agent"
    write_evidence(evidence / "pi-changelog.md", read_head(pi_package / "CHANGELOG.md", 200))
    for doc in ("settings.md", "extensions.md", "packages.md"):
        if (pi_package / "docs" / doc).exists():
            write_evidence(evidence / "pi-docs" / doc, read_head(pi_package / "docs" / doc, 400))

    write_evidence(
        evidence / "herdr-releases.json",
        observe(["gh", "api", "repos/herdrdev/herdr/releases?per_page=5", "--jq", "[.[]|{tag_name,published_at,body}]"]),
    )
    write_evidence(evidence / "herdr-help.txt", observe(["herdr", "--help"]))
    herdr_config = HOME / ".config" / "herdr" / "config.toml"
    if herdr_config.exists():
        write_evidence(evidence / "herdr-runtime-config.toml", read_head(herdr_config, 200))

    write_evidence(evidence / "discovery-npm-pi-packages.txt", npm_search("keywords:pi-package"))
    for topic in ("pi-package", "agent-skills", "claude-skills"):
        write_evidence(
            evidence / f"discovery-github-{topic}.json",
            observe(
                [
                    "gh", "search", "repos", "--topic", topic, "--sort", "stars", "--limit", "20",
                    "--json", "fullName,description,stargazersCount,updatedAt,url",
                ]
            ),
        )
    claude_skills = HOME / ".claude" / "skills"
    names = sorted(entry.name for entry in claude_skills.iterdir()) if claude_skills.is_dir() else []
    write_evidence(evidence / "claude-skills-installed.txt", "\n".join(names) + "\n")


def lane_folders(home: Path = HOME) -> list[Path]:
    return sorted(
        path
        for path in home.glob("*-local")
        if path.is_dir() and ((path / "STATE.md").exists() or (path / "COORDINATION.md").exists())
    )


def survey_lane_folder(folder: Path) -> str:
    # Deliberately no recursive walk: these folders hold many full worktrees
    # (one is 74G), and a recursive scan does not finish in any useful time.
    entries = list(os.scandir(folder))
    directories = [entry for entry in entries if entry.is_dir(follow_symlinks=False)]
    with_git = sum(1 for entry in directories if os.path.exists(os.path.join(entry.path, ".git")))
    lanes = folder / "lanes"
    lane_files = sum(1 for _ in os.scandir(lanes)) if lanes.is_dir() else 0
    worktrees = folder / "worktrees"
    worktree_dirs = sum(1 for _ in os.scandir(worktrees)) if worktrees.is_dir() else 0
    size = observe(["du", "-sh", "--exclude=.git", str(folder)], timeout=90).split("\t")[0].strip()
    lines = [
        f"# {folder.name}",
        f"top_level_entries: {len(entries)}",
        f"top_level_directories: {len(directories)}",
        f"top_level_checkouts: {with_git}",
        f"lanes_entries: {lane_files}",
        f"worktrees_entries: {worktree_dirs}",
        f"size_excluding_git: {size}",
        "scripts: " + " ".join(sorted(entry.name for entry in os.scandir(folder / "scripts")) if (folder / "scripts").is_dir() else []),
        "top_level_files: " + " ".join(sorted(entry.name for entry in entries if entry.is_file(follow_symlinks=False))),
        "",
        "recent commits:",
        observe(["git", "-C", str(folder), "log", "-25", "--format=%as %s"]),
    ]
    return "\n".join(lines)


def recent_activity(folder: Path, now: float) -> list[Path]:
    cutoff = now - LANE_ACTIVITY_DAYS * 86400
    found = []
    for name in LANE_ACTIVITY_DIRS:
        directory = folder / name
        if not directory.is_dir():
            continue
        for entry in os.scandir(directory):
            if entry.name.endswith(".md") and entry.is_file(follow_symlinks=False):
                modified = entry.stat(follow_symlinks=False).st_mtime
                if modified >= cutoff:
                    found.append((modified, Path(entry.path)))
    found.sort(reverse=True)
    return [path for _, path in found[:LANE_ACTIVITY_FILES]]


def gather_lane_review(evidence: Path, repo: Path) -> None:
    skills_root = DOTFILES / "ai" / "marketplace" / "plugins" / "my" / "skills"
    for skill in LANE_SKILLS:
        shutil.copytree(
            skills_root / skill,
            evidence / "skills" / skill,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
    surveys = []
    now = dt.datetime.now().timestamp()
    for folder in lane_folders():
        surveys.append(survey_lane_folder(folder))
        for relative in LANE_FILES:
            source = folder / relative
            if source.is_file() and not source.is_symlink():
                write_evidence(evidence / "projects" / folder.name / relative, read_head(source, 600))
        for path in recent_activity(folder, now):
            target = evidence / "projects" / folder.name / "recent-activity" / path.parent.name / path.name
            write_evidence(target, read_head(path, LANE_ACTIVITY_LINES))
    write_evidence(evidence / "survey.md", "\n\n".join(surveys))


GATHER = {
    "dotfiles-health": gather_dotfiles_health,
    "tooling-radar": gather_tooling_radar,
    "lane-review": gather_lane_review,
}


# ── Target resolution ────────────────────────────────────────────────────────


def resolve_slug(profile: Profile) -> str:
    if profile.private_only:
        if not KNOWLEDGE_CONFIG.exists():
            raise AutomationError(f"{profile.name} publishes to the private knowledge repo; {KNOWLEDGE_CONFIG} is missing")
        return json.loads(KNOWLEDGE_CONFIG.read_text(encoding="utf-8"))["repository"]
    return repo_slug(run(["git", "-C", str(DOTFILES), "remote", "get-url", "origin"]))


def check_target(profile: Profile, slug: str) -> str:
    info = json.loads(run(["gh", "repo", "view", slug, "--json", "visibility,defaultBranchRef"]))
    # Checked every run: a repo that later went public must stop receiving these.
    if profile.private_only and info.get("visibility") != "PRIVATE":
        raise AutomationError(f"{slug} is {info.get('visibility')}, refusing to publish private lane evidence")
    return info["defaultBranchRef"]["name"]


# ── Sandbox ──────────────────────────────────────────────────────────────────


def prepare_agent_dir(agent_dir: Path) -> None:
    # Pi needs a writable agent directory, so it gets a throwaway one. That keeps
    # sessions, packages and the real settings out of the sandbox entirely.
    agent_dir.mkdir(mode=0o700, parents=True)
    for name in ("auth.json", "models.json", "models-store.json"):
        source = PI_AGENT / name
        if source.exists():
            shutil.copy2(source, agent_dir / name)
    settings = json.loads((PI_AGENT / "settings.json").read_text(encoding="utf-8"))
    keep = ("defaultProvider", "defaultModel", "defaultThinkingLevel", "compaction")
    (agent_dir / "settings.json").write_text(json.dumps({key: settings[key] for key in keep if key in settings}))


def run_agent(profile: Profile, repo: Path, evidence: Path, agent_dir: Path, log_path: Path, date: str) -> None:
    node = run(["mise", "which", "node"]).strip() if shutil.which("mise") else (shutil.which("node") or "")
    if not node:
        raise AutomationError("node runtime not found")
    node_bin = Path(node).parent
    args = sandbox_args(
        home=HOME,
        repo=repo,
        evidence=evidence,
        agent_dir=agent_dir,
        guard=GUARD,
        node_root=node_bin.parent,
        resolv=Path("/etc/resolv.conf").resolve(),
        pi_agent=PI_AGENT,
    )
    args += ["--chdir", str(repo), "--setenv", "HOME", str(HOME)]
    args += ["--setenv", "PATH", f"{node_bin}:{PI_AGENT / 'bin'}:/usr/bin:/bin"]
    args += ["--setenv", "PI_CODING_AGENT_DIR", str(agent_dir)]
    args += ["--setenv", "AUTOMATION_READ_ROOTS", f"{repo}:{evidence}"]
    args += ["--setenv", "AUTOMATION_WRITE_ROOTS", str(repo)]
    template = (PROMPTS / f"{profile.name}.md").read_text(encoding="utf-8")
    prompt = render_prompt(template, report=profile.report_path, evidence=evidence, repo=repo, date=date)
    args += [
        str(PI_AGENT / "bin" / "pi"), "-p", "--no-session", "--no-extensions", "--no-skills",
        "--no-prompt-templates", "--no-context-files", "--no-mcp", "--no-themes",
        "-e", str(GUARD), "--tools", AGENT_TOOLS, prompt,
    ]
    with log_path.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=AGENT_TIMEOUT_SECONDS, check=False
        )
    if result.returncode != 0:
        raise AutomationError(f"agent exited {result.returncode}; see {log_path}")


# ── Publish ──────────────────────────────────────────────────────────────────


def stage_all(repo: Path) -> tuple[list[str], int, bool]:
    git(repo, "add", "-A")
    paths = [path for path in git(repo, "diff", "--cached", "--name-only", "-z").split("\0") if path]
    changed = 0
    for line in git(repo, "diff", "--cached", "--numstat").splitlines():
        added, removed, _ = line.split("\t", 2)
        if added != "-":
            changed += int(added) + int(removed)
    symlink = bool(re.search(r"^:\d+ 120000 ", git(repo, "diff", "--cached", "--raw"), re.MULTILINE))
    return paths, changed, symlink


def enforce_policy(profile: Profile, repo: Path) -> tuple[list[str], str | None]:
    """Return applied fix paths and the downgrade note, leaving the index final."""
    report_file = repo / profile.report_path
    if report_file.is_file():
        # Forced because the target repository's ignore rules must not decide
        # whether this review's own output gets published.
        git(repo, "add", "-f", "--", profile.report_path)
    paths, _, _ = stage_all(repo)
    if not paths:
        return [], None
    if profile.report_path not in paths or not report_file.is_file():
        raise AutomationError("agent changed files without writing its report")
    report = report_file.read_bytes()
    if not report.strip():
        raise AutomationError("agent wrote an empty report")
    if len(report) > MAX_REPORT_BYTES:
        raise AutomationError(f"report is {len(report)} bytes (limit {MAX_REPORT_BYTES})")

    fix_paths = [path for path in paths if path != profile.report_path]
    report_lines = sum(
        int(line.split("\t")[0]) + int(line.split("\t")[1])
        for line in git(repo, "diff", "--cached", "--numstat", "--", profile.report_path).splitlines()
        if not line.startswith("-")
    )
    _, total_lines, symlink = stage_all(repo)
    note = downgrade_reason(profile, fix_paths, total_lines - report_lines, symlink)
    if note:
        git(repo, "reset", "-q", "--hard")
        git(repo, "clean", "-fdqx")
        report_file.parent.mkdir(parents=True, exist_ok=True)
        report_file.write_bytes(report)
        git(repo, "add", "--", profile.report_path)
        fix_paths = []
    return fix_paths, note


def publish(profile: Profile, repo: Path, slug: str, base: str, date: str, fix_paths: list[str], note: str | None) -> str:
    name = run(["git", "-C", str(DOTFILES), "config", "user.name"]).strip()
    email = run(["git", "-C", str(DOTFILES), "config", "user.email"]).strip()
    branch = f"automation/{profile.name}/{date}"
    title = f"{profile.title} {date}" + (" with fixes" if fix_paths else "")
    git(repo, "-c", f"user.name={name}", "-c", f"user.email={email}", "commit", "-q", "--no-verify", "-m", title)
    git(repo, "push", "-q", "origin", f"HEAD:refs/heads/{branch}", timeout=180)
    report = (repo / profile.report_path).read_text(encoding="utf-8")
    body_file = repo.parent / "pr-body.md"
    body_file.write_text(pr_body(report, note, fix_paths), encoding="utf-8")
    return run(
        ["gh", "pr", "create", "-R", slug, "--base", base, "--head", branch, "--title", title, "--body-file", str(body_file)]
    ).strip()


def record_status(name: str, status: str, detail: str) -> None:
    payload = {"status": status, "detail": detail, "finished": dt.datetime.now().astimezone().isoformat(timespec="seconds")}
    (STATE_ROOT / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"{name}: {status}: {detail}")


def run_automation(profile: Profile, dry_run: bool) -> tuple[str, str]:
    date = dt.date.today().isoformat()
    slug = resolve_slug(profile)
    base = check_target(profile, slug)
    open_prs = filter_automation_prs(
        json.loads(run(["gh", "pr", "list", "-R", slug, "--state", "open", "--limit", "100", "--json", "headRefName,url"])),
        profile.name,
    )
    # Backpressure: an unreviewed PR means another weekly model run adds noise and cost.
    if open_prs and not dry_run:
        return "skipped", f"waiting on {open_prs[0]['url']}"

    run_dir = STATE_ROOT / "runs" / profile.name
    shutil.rmtree(run_dir, ignore_errors=True)
    run_dir.mkdir(parents=True, mode=0o700)
    repo, evidence, agent_dir = run_dir / "repo", run_dir / "evidence", run_dir / "agent"
    log_path = STATE_ROOT / f"{profile.name}.log"
    try:
        run(["git", "clone", "-q", "--depth", "100", "--branch", base, f"https://github.com/{slug}.git", str(repo)], timeout=300)
        evidence.mkdir()
        gather_previous_prs(evidence, slug, profile.name)
        GATHER[profile.name](evidence, repo)
        prepare_agent_dir(agent_dir)
        literals = collect_secret_literals(json.loads((agent_dir / "auth.json").read_text(encoding="utf-8")))
        run_agent(profile, repo, evidence, agent_dir, log_path, date)

        fix_paths, note = enforce_policy(profile, repo)
        staged = git(repo, "diff", "--cached")
        if not staged.strip():
            return "no-change", "nothing material since the last report"
        hit = secret_hit(staged, literals)
        if hit:
            raise AutomationError(f"secret scan blocked publication: {hit}")
        if dry_run:
            kept = STATE_ROOT / f"{profile.name}-dry-run.diff"
            kept.write_text(staged, encoding="utf-8")
            summary = f"would publish to {slug}; fixes={fix_paths or 'none'}; dropped={note or 'none'}"
            return "dry-run", f"{summary}; diff at {kept}"
        return "published", publish(profile, repo, slug, base, date, fix_paths, note)
    finally:
        # The agent directory holds a credential copy, so it never outlives the run.
        shutil.rmtree(agent_dir, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("name", choices=sorted(PROFILES))
    parser.add_argument("--dry-run", action="store_true", help="run the review and policy, but do not push or open a PR")
    args = parser.parse_args(argv)

    STATE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STATE_ROOT / f"{args.name}.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print(f"{args.name}: already running", file=sys.stderr)
            return 1
        try:
            status, detail = run_automation(PROFILES[args.name], args.dry_run)
        except (AutomationError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            record_status(args.name, "failed", str(error))
            return 1
        record_status(args.name, status, detail)
    return 0


if __name__ == "__main__":
    sys.exit(main())
