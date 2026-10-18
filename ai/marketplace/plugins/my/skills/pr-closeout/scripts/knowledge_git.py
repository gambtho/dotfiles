"""Opt-in private knowledge storage. Ensure never refreshes an existing checkout.

Git operations are scoped to a configured private GitHub repository. Locks protect
cooperating writers, not unrelated editors or hostile processes with the same UID.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

TIMEOUT = 30
SLUG = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
HASH = re.compile(r"[a-f0-9]{64}\Z")


class KnowledgeError(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def home_path(variable, default):
    return Path(os.environ.get(variable, str(Path.home() / default))).expanduser().absolute()


def config_path():
    return home_path("XDG_CONFIG_HOME", ".config") / "dotfiles/agent-knowledge.json"


def state_dir():
    return home_path("XDG_STATE_HOME", ".local/state") / "dotfiles/agent-knowledge"


def valid_repository(value):
    if not isinstance(value, str) or not SLUG.fullmatch(value) or any(p in (".", "..") or p.startswith("-") for p in value.split("/")):
        raise KnowledgeError("expected repository OWNER/REPO, not a URL or credential")
    return value


def private_directory(path):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise KnowledgeError("unsafe private directory")
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    if path.stat().st_uid != os.getuid():
        raise KnowledgeError("private directory is not owned by this user")
    path.chmod(0o700)


def private_json(path):
    if path.is_symlink():
        raise KnowledgeError("unsafe private state symlink")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise KnowledgeError("private configuration/state must be owner-only regular files")
        try:
            return json.load(stream)
        except (ValueError, UnicodeError) as error:
            raise KnowledgeError("invalid private configuration/state JSON") from error


def write_json(path, value):
    private_directory(path.parent)
    private_json(path)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".knowledge-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def command(args):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", GH_PROMPT_DISABLED="1")
    try:
        result = subprocess.run(args, text=True, capture_output=True, env=env, timeout=TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise KnowledgeError("command unavailable or timed out; knowledge remains local", 5) from error
    if result.returncode:
        # Git hooks and credential helpers can print secrets. Do not echo their output.
        raise KnowledgeError("Git/GitHub operation failed; knowledge remains local", 5)
    return result.stdout


def git(cfg, *args, bare=False, raw=False):
    root = Path(cfg["worktree"])
    prefix = ["git", "--git-dir=" + cfg["git_dir"]] if bare or not (root / ".git").is_file() else ["git", "-C", str(root)]
    result = command([*prefix, *args])
    return result if raw else result.strip()


def metadata(repository):
    value = json.loads(command(["gh", "api", "--hostname", "github.com", "repos/" + repository]))
    if not isinstance(value, dict) or value.get("private") is not True or not isinstance(value.get("full_name"), str) or value["full_name"].casefold() != repository.casefold():
        raise KnowledgeError("configured destination must be the same verified private repository")
    branch = value.get("default_branch")
    if not isinstance(branch, str) or not branch:
        raise KnowledgeError("repository has no verified default branch")
    command(["git", "check-ref-format", "refs/heads/" + branch])
    return value


def load_config():
    cfg = private_json(config_path())
    if cfg is None:
        return None
    if not isinstance(cfg, dict) or cfg.get("version") != 1:
        raise KnowledgeError("unsupported knowledge configuration")
    valid_repository(cfg.get("repository"))
    for key in ("branch", "worktree", "git_dir"):
        if not isinstance(cfg.get(key), str) or not cfg[key]:
            raise KnowledgeError("incomplete knowledge configuration")
    if not isinstance(cfg.get("auto_publish"), bool):
        raise KnowledgeError("invalid automatic publication setting")
    if Path(cfg["worktree"]) != Path.home() / ".pi/pr-reviews" or not Path(cfg["git_dir"]).is_absolute():
        raise KnowledgeError("unexpected configured knowledge paths")
    command(["git", "check-ref-format", "refs/heads/" + cfg["branch"]])
    requested = os.environ.get("DOTFILES_AGENT_KNOWLEDGE_REPO")
    if requested and valid_repository(requested).casefold() != cfg["repository"].casefold():
        raise KnowledgeError("refusing to retarget existing knowledge configuration")
    return cfg


@contextmanager
def repo_lock():
    directory = state_dir()
    private_directory(directory)
    path = directory / "repository.lock"
    if path.is_symlink():
        raise KnowledgeError("unsafe repository lock symlink")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(fd, "r+b") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise KnowledgeError("unsafe repository lock")
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise KnowledgeError("busy knowledge repository; retry later", 3) from error
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def verify_remote(cfg):
    value = metadata(cfg["repository"])
    if value["default_branch"] != cfg["branch"]:
        raise KnowledgeError("default branch changed; review configuration", 5)
    expected = "https://github.com/" + cfg["repository"] + ".git"
    for options in (("--all",), ("--push", "--all")):
        urls = git(cfg, "remote", "get-url", *options, "origin").splitlines()
        if urls != [expected]:
            raise KnowledgeError("effective fetch/push destination differs from configured private repository")


def fetch(cfg, initial=False):
    verify_remote(cfg)
    branch = cfg["branch"]
    destination = "refs/heads/" + branch if initial else "refs/remotes/origin/" + branch
    git(cfg, "fetch", "--no-tags", "--no-recurse-submodules", "origin", "refs/heads/" + branch + ":" + destination)


def validate_managed(cfg):
    root = Path(cfg["worktree"])
    common = Path(cfg["git_dir"])
    if root.is_symlink() or common.is_symlink() or not (root / ".git").is_file() or (root / ".git").is_symlink():
        raise KnowledgeError("regular linked knowledge worktree required; run make agent-knowledge-adopt", 5)
    actual_common = Path(git(cfg, "rev-parse", "--git-common-dir"))
    if not actual_common.is_absolute():
        actual_common = root / actual_common
    actual_git = Path(git(cfg, "rev-parse", "--git-dir"))
    if not actual_git.is_absolute():
        actual_git = root / actual_git
    if actual_common.resolve() != common.resolve() or actual_git.resolve() == actual_common.resolve() or Path(git(cfg, "rev-parse", "--show-toplevel")).resolve() != root.resolve():
        raise KnowledgeError("not the configured linked knowledge worktree")
    if git(cfg, "symbolic-ref", "--quiet", "HEAD") != "refs/heads/" + cfg["branch"]:
        raise KnowledgeError("knowledge branch changed or detached", 5)


def changed_paths(cfg, cached=False):
    args = ["diff", "--name-only", "-z"]
    if cached:
        args.append("--cached")
    return set(filter(None, git(cfg, *args, raw=True).split("\0")))


def main_worktree(cfg):
    for block in git(cfg, "worktree", "list", "--porcelain", bare=True).split("\n\n"):
        values = dict(line.split(" ", 1) for line in block.splitlines() if " " in line)
        if values.get("branch") == "refs/heads/" + cfg["branch"]:
            return Path(values["worktree"])
    return None


def remote_head(cfg):
    value = json.loads(command(["gh", "api", "--hostname", "github.com", "repos/" + cfg["repository"] + "/git/ref/heads/" + quote(cfg["branch"], safe="")]))
    sha = value.get("object", {}).get("sha")
    if not isinstance(sha, str) or not re.fullmatch(r"(?:[a-f0-9]{40}|[a-f0-9]{64})", sha):
        raise KnowledgeError("invalid remote head metadata", 5)
    return sha


def status(cfg):
    validate_managed(cfg)
    verify_remote(cfg)
    if changed_paths(cfg) or changed_paths(cfg, cached=True):
        return {"status": "pending", "advice": "Local edits pending; review or run make agent-knowledge-sync after stopping Pi."}
    if git(cfg, "rev-parse", "HEAD") != remote_head(cfg):
        return {"status": "pending", "advice": "Knowledge history differs; run make agent-knowledge-sync after stopping Pi."}
    return {"status": "ready"}


def prepare_bare(cfg):
    directory = Path(cfg["git_dir"])
    if directory.is_symlink():
        raise KnowledgeError("unsafe bare Git directory")
    if not directory.exists():
        private_directory(directory)
        command(["git", "init", "--bare", "--initial-branch=" + cfg["branch"], str(directory)])
        git(cfg, "remote", "add", "origin", "https://github.com/" + cfg["repository"] + ".git", bare=True)
    if git(cfg, "rev-parse", "--is-bare-repository", bare=True) != "true":
        raise KnowledgeError("configured Git storage is not bare")
    verify_remote(cfg)
    try:
        git(cfg, "rev-parse", "--verify", "refs/heads/" + cfg["branch"], bare=True)
    except KnowledgeError:
        fetch(cfg, initial=True)


def ensure(cfg):
    prepare_bare(cfg)
    root = Path(cfg["worktree"])
    if root.is_symlink():
        raise KnowledgeError("symlink root is unsupported; review existing setup")
    if (root / ".git").exists():
        return status(cfg)
    if root.exists() and (not root.is_dir() or any(root.iterdir())):
        return {"status": "pending", "advice": "Existing store preserved. Stop Pi, then run make agent-knowledge-adopt."}
    occupied = main_worktree(cfg)
    if occupied is not None:
        return {"status": "pending", "advice": "Branch already has a worktree. Stop Pi, then run make agent-knowledge-adopt."}
    root.parent.mkdir(parents=True, exist_ok=True)
    if root.exists():
        root.rmdir()
    git(cfg, "worktree", "add", str(root), cfg["branch"], bare=True)
    root.chmod(0o700)
    return status(cfg)


def adopt(cfg):
    prepare_bare(cfg)
    root = Path(cfg["worktree"])
    if root.is_symlink() or (root.exists() and not root.is_dir()):
        raise KnowledgeError("unsafe legacy root")
    if (root / ".git").exists():
        return status(cfg)
    if root.exists():
        for directory, dirs, files in os.walk(root, followlinks=False):
            for name in [*dirs, *files]:
                item = Path(directory) / name
                if item.is_symlink():
                    raise KnowledgeError("legacy store contains a symlink; review before adoption")
            for name in files:
                relative = (Path(directory) / name).relative_to(root)
                relevant = (len(relative.parts) == 3 and name in ("review.md", "learnings.md", "config.md", "sources.md")) or relative.as_posix() == "aliases.json"
                if relevant:
                    try:
                        existing = git(cfg, "show", cfg["branch"] + ":" + relative.as_posix(), bare=True, raw=True).encode()
                    except KnowledgeError as error:
                        raise KnowledgeError("local-only curated record; import explicitly before adoption", 5) from error
                    if existing != (root / relative).read_bytes():
                        raise KnowledgeError("legacy/remote records differ; merge explicitly before adoption", 5)
    source = main_worktree(cfg)
    cache = Path(cfg["git_dir"]).parent / "agent-knowledge"
    if source is not None and source != cache:
        raise KnowledgeError("unexpected occupied worktree; review before adoption", 5)
    if source is None:
        if cache.exists():
            raise KnowledgeError("staging worktree path already exists", 5)
        git(cfg, "worktree", "add", str(cache), cfg["branch"], bare=True)
        cache.chmod(0o700)
        source = cache
    if command(["git", "-C", str(source), "status", "--porcelain"]):
        raise KnowledgeError("staging worktree has local changes", 5)
    archive = None
    old_mode = None
    moved = False
    try:
        if root.exists():
            old_mode = stat.S_IMODE(root.stat().st_mode)
            archive = root.with_name(root.name + ".pre-git-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
            root.rename(archive)
            archive.chmod(0o700)
        root.parent.mkdir(parents=True, exist_ok=True)
        git(cfg, "worktree", "move", str(source), str(root), bare=True)
        moved = True
        root.chmod(0o700)
        validate_managed(cfg)
    except BaseException:
        if moved:
            git(cfg, "worktree", "move", str(root), str(source), bare=True)
        if archive is not None:
            archive.rename(root)
            root.chmod(old_mode)
        raise
    return {"status": "ready", "archive": str(archive) if archive else None, "advice": "Local-only supporting material remains in the archive; it was not versioned."}


def sync(cfg):
    validate_managed(cfg)
    if changed_paths(cfg) or changed_paths(cfg, cached=True):
        raise KnowledgeError("unrecorded local edits; review before synchronization", 5)
    fetch(cfg)
    git(cfg, "merge", "--ff-only", "refs/remotes/origin/" + cfg["branch"])
    return status(cfg)


def run(action):
    cfg = load_config()
    requested = os.environ.get("DOTFILES_AGENT_KNOWLEDGE_REPO")
    if cfg is None:
        if not requested:
            return {"status": "skipped", "advice": "Agent knowledge is not configured on this machine."}
        valid_repository(requested)
        info = metadata(requested)
        cfg = {"version": 1, "repository": info["full_name"], "branch": info["default_branch"], "worktree": str(Path.home() / ".pi/pr-reviews"), "git_dir": str(home_path("XDG_DATA_HOME", ".local/share") / "agent-knowledge.git"), "auto_publish": True}
        if action == "check":
            return {"status": "pending", "advice": "Run make agent-knowledge to configure storage."}
        with repo_lock():
            if load_config() is not None:
                raise KnowledgeError("configuration appeared concurrently; retry", 3)
            write_json(config_path(), cfg)
    if action == "check":
        return status(cfg)
    with repo_lock():
        return {"ensure": ensure, "adopt": adopt, "sync": sync}[action](cfg)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("ensure", "check", "adopt", "sync"), nargs="?", default="ensure")
    args = parser.parse_args(argv)
    previous = os.umask(0o077)
    try:
        result = run(args.action)
        print(json.dumps(result))
        return 5 if result["status"] == "pending" else 0
    except KnowledgeError as error:
        print(json.dumps({"status": "pending" if error.code in (3, 5) else "refused", "reason": str(error)}))
        return error.code
    except (OSError, ValueError, UnicodeError):
        print(json.dumps({"status": "refused", "reason": "Invalid configuration or filesystem state; no automatic repair attempted."}))
        return 2
    finally:
        os.umask(previous)


if __name__ == "__main__":
    sys.exit(main())
