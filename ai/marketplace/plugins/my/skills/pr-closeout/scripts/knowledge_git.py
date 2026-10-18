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


def command(args, binary=False, cwd=None):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", GH_PROMPT_DISABLED="1")
    # A caller may run inside a product hook/worktree. Keep authentication and
    # user policy, but never inherit its index, object storage or repository.
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_SHALLOW_FILE", "GIT_REPLACE_REF_BASE", "GIT_CONFIG"):
        env.pop(key, None)
    try:
        result = subprocess.run(args, text=not binary, capture_output=True, env=env, cwd=cwd, timeout=TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise KnowledgeError("command unavailable or timed out; knowledge remains local", 5) from error
    if result.returncode:
        # Git hooks and credential helpers can print secrets. Do not echo their output.
        raise KnowledgeError("Git/GitHub operation failed; knowledge remains local", 5)
    return result.stdout


def git(cfg, *args, bare=False, raw=False, binary=False):
    root = Path(cfg["worktree"])
    prefix = ["git", "--git-dir=" + cfg["git_dir"]] if bare or not (root / ".git").is_file() else ["git", "-C", str(root)]
    result = command([*prefix, *args], binary=binary)
    return result if raw else result.strip()


def metadata(repository, cwd=None):
    value = json.loads(command(["gh", "api", "--hostname", "github.com", "repos/" + repository], cwd=cwd))
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


def gh_directory(cfg):
    # The intentional gh shim selects an account from cwd's Git owner map.
    # Never let a product repo choose the knowledge repository's credentials.
    for root in (Path(cfg["worktree"]), Path(cfg["git_dir"]).parent / "agent-knowledge"):
        if (root / ".git").is_file():
            return root
    return None  # Initial setup retains the operator's explicit account context.


def verify_remote(cfg):
    value = metadata(cfg["repository"], cwd=gh_directory(cfg))
    if value["default_branch"] != cfg["branch"]:
        raise KnowledgeError("default branch changed; review configuration", 5)
    expected = "https://github.com/" + cfg["repository"] + ".git"
    keys = git(cfg, "config", "--name-only", "--get-regexp", r"^remote\.origin\.(url|vcs)$").splitlines()
    if "remote.origin.vcs" in keys:
        raise KnowledgeError("custom remote helpers are not an authorized knowledge transport")
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
    for directory in (root, common):
        info = directory.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise KnowledgeError("knowledge worktree and Git storage must be owner-private (0700)")
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
    value = json.loads(command(["gh", "api", "--hostname", "github.com", "repos/" + cfg["repository"] + "/git/ref/heads/" + quote(cfg["branch"], safe="")], cwd=gh_directory(cfg)))
    sha = value.get("object", {}).get("sha")
    if not isinstance(sha, str) or not re.fullmatch(r"(?:[a-f0-9]{40}|[a-f0-9]{64})", sha):
        raise KnowledgeError("invalid remote head metadata", 5)
    return sha


def status(cfg):
    validate_managed(cfg)
    verify_remote(cfg)
    pending = Publication(cfg).state()
    if pending["pending_files"] or pending["authorized_commit"]:
        return {"status": "pending", "advice": "Verified publication is pending; run make agent-knowledge-sync after stopping Pi."}
    if profile_changes(cfg) or changed_paths(cfg, cached=True):
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
    private_directory(directory)
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
                        existing = git(cfg, "show", cfg["branch"] + ":" + relative.as_posix(), bare=True, raw=True, binary=True)
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
    old_mode = 0o700
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
        result = status(cfg)
    except BaseException:
        if moved:
            git(cfg, "worktree", "move", str(root), str(source), bare=True)
        if archive is not None:
            archive.rename(root)
            root.chmod(old_mode)
        raise
    return {**result, "archive": str(archive) if archive else None, "archive_note": "Local-only supporting material remains in the archive; it was not versioned."}


def record_path(path):
    parts = path.split("/") if isinstance(path, str) else []
    if len(parts) != 3 or parts[2] not in ("review.md", "learnings.md"):
        return False
    return bool(SLUG.fullmatch("/".join(parts[:2]))) and all(p not in (".", "..") for p in parts[:2])


def profile_changes(cfg):
    untracked = git(cfg, "ls-files", "--others", "--exclude-standard", "-z", raw=True).split("\0")
    return changed_paths(cfg) | {p for p in untracked if record_path(p)}


def record_bytes(cfg, path):
    if not record_path(path):
        raise KnowledgeError("unsafe pending profile path")
    target = Path(cfg["worktree"])
    for component in path.split("/"):
        target = target / component
        if target.is_symlink():
            raise KnowledgeError("unsafe pending profile symlink")
    fd = os.open(target, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise KnowledgeError("pending profile is not a regular file")
        return stream.read()


def oid(value):
    return isinstance(value, str) and re.fullmatch(r"(?:[a-f0-9]{40}|[a-f0-9]{64})", value)


class Publication:
    def __init__(self, cfg):
        self.cfg = cfg
        self.path = state_dir() / "pending.json"

    def state(self):
        value = private_json(self.path)
        if value is None:
            return {"version": 1, "repository": self.cfg["repository"], "branch": self.cfg["branch"], "pending_files": {}, "authorized_commit": None}
        if not isinstance(value, dict) or value.get("version") != 1 or value.get("repository") != self.cfg["repository"] or value.get("branch") != self.cfg["branch"]:
            raise KnowledgeError("pending state binding changed; reconcile explicitly", 5)
        files = value.get("pending_files")
        if not isinstance(files, dict) or any(not record_path(p) or not isinstance(h, str) or not HASH.fullmatch(h) for p, h in files.items()):
            raise KnowledgeError("invalid pending file state")
        receipt = value.get("authorized_commit")
        if receipt is not None:
            if not isinstance(receipt, dict) or not oid(receipt.get("sha")) or not oid(receipt.get("parent")) or not isinstance(receipt.get("files"), dict) or not receipt["files"]:
                raise KnowledgeError("invalid pending commit receipt")
            if any(not record_path(p) or not isinstance(h, str) or not HASH.fullmatch(h) for p, h in receipt["files"].items()):
                raise KnowledgeError("invalid authorized commit paths")
        return value

    def save(self, state):
        write_json(self.path, state)

    def check_files(self, state):
        for path, expected in state["pending_files"].items():
            if hashlib.sha256(record_bytes(self.cfg, path)).hexdigest() != expected:
                raise KnowledgeError("pending profile changed outside verified publication", 5)
        allowed = set(state["pending_files"])
        if (profile_changes(self.cfg) | changed_paths(self.cfg, cached=True)) - allowed:
            raise KnowledgeError("unrelated local/staged changes require manual review", 5)
        for path in changed_paths(self.cfg, cached=True):
            staged = git(self.cfg, "show", ":" + path, raw=True, binary=True)
            if hashlib.sha256(staged).hexdigest() != state["pending_files"][path]:
                raise KnowledgeError("staged content differs from verified pending bytes", 5)

    def check_receipt(self, receipt):
        cfg = self.cfg
        sha = receipt["sha"]
        if git(cfg, "rev-list", "--parents", "-n", "1", sha).split() != [sha, receipt["parent"]]:
            raise KnowledgeError("commit ancestry differs from recorded authorization", 5)
        paths = set(git(cfg, "diff-tree", "--no-commit-id", "--name-only", "-r", "-z", sha, raw=True).rstrip("\0").split("\0"))
        if paths != set(receipt["files"]):
            raise KnowledgeError("commit scope differs from verified authorization", 5)
        for path, expected in receipt["files"].items():
            body = git(cfg, "show", sha + ":" + path, raw=True, binary=True)
            if hashlib.sha256(body).hexdigest() != expected:
                raise KnowledgeError("committed content differs from verified bytes", 5)
            mode = git(cfg, "ls-tree", sha, "--", path).split()[0]
            if mode != "100644":
                raise KnowledgeError("profile commit is not a plain non-executable file", 5)

    def push(self, receipt):
        validate_managed(self.cfg)
        verify_remote(self.cfg)
        self.check_receipt(receipt)
        if git(self.cfg, "rev-parse", "HEAD") != receipt["sha"]:
            raise KnowledgeError("unowned local commit prevents automatic push", 5)
        git(self.cfg, "-c", "remote.origin.mirror=false", "-c", "push.followTags=false", "push", "--no-follow-tags", "--recurse-submodules=no", "origin", receipt["sha"] + ":refs/heads/" + self.cfg["branch"])

    def clear_receipt(self, state):
        for path, expected in state["authorized_commit"]["files"].items():
            if state["pending_files"].get(path) == expected:
                del state["pending_files"][path]
        state["authorized_commit"] = None
        self.save(state)

    def finish(self, state):
        cfg = self.cfg
        validate_managed(cfg)
        self.check_files(state)
        fetch(cfg)
        remote = git(cfg, "rev-parse", "refs/remotes/origin/" + cfg["branch"])
        head = git(cfg, "rev-parse", "HEAD")
        delivered = None
        receipt = state["authorized_commit"]
        if receipt:
            self.check_receipt(receipt)
            if head != receipt["sha"] or remote not in (receipt["parent"], receipt["sha"]):
                raise KnowledgeError("divergent or unowned history; reconcile before publishing", 5)
            if remote != receipt["sha"]:
                self.push(receipt)
            delivered = receipt["sha"]
            self.clear_receipt(state)
            remote = delivered
        if head != remote:
            raise KnowledgeError("remote ahead or unowned local history; run make agent-knowledge-sync", 5)
        selected = {}
        for path, expected in list(state["pending_files"].items()):
            try:
                body = git(cfg, "show", "HEAD:" + path, raw=True, binary=True)
            except KnowledgeError:
                body = None
            if body is not None and hashlib.sha256(body).hexdigest() == expected:
                del state["pending_files"][path]
            else:
                selected[path] = expected
        self.save(state)
        if not selected:
            return {"status": "pushed" if delivered else "unchanged", "local_saved": True, "commit": delivered}
        secret = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|https?://[^\s/@]+:[^\s/@]+@)")
        if any(secret.search(record_bytes(cfg, path)) for path in selected):
            raise KnowledgeError("possible credential pattern; automatic commit refused", 5)
        git(cfg, "add", "--", *sorted(selected))
        git(cfg, "commit", "--only", "-m", "docs: update verified repository learnings", "--", *sorted(selected))
        receipt = {"sha": git(cfg, "rev-parse", "HEAD"), "parent": remote, "files": selected}
        self.check_receipt(receipt)
        state["authorized_commit"] = receipt
        self.save(state)
        self.push(receipt)
        delivered = receipt["sha"]
        self.clear_receipt(state)
        return {"status": "pushed", "local_saved": True, "commit": delivered}

    def record(self, path, sha256):
        try:
            if not record_path(path) or not HASH.fullmatch(sha256) or hashlib.sha256(record_bytes(self.cfg, path)).hexdigest() != sha256:
                raise KnowledgeError("publication digest/path mismatch", 5)
            state = self.state()
            state["pending_files"][path] = sha256
            self.save(state)
            return self.finish(state)
        except KnowledgeError as error:
            return {"status": "pending", "local_saved": True, "reason": str(error)}
        except (OSError, ValueError):
            return {"status": "pending", "local_saved": True, "reason": "Private sync state could not be saved; reconcile before retrying."}


@contextmanager
def publication(root):
    cfg = load_config()
    if cfg is None or not cfg["auto_publish"]:
        yield None
        return
    root = Path(root).expanduser()
    try:
        matches = not root.is_symlink() and root.resolve() == Path(cfg["worktree"]).resolve()
    except (OSError, RuntimeError) as error:
        raise KnowledgeError("unsafe publication root") from error
    if not matches:
        yield None
        return
    with repo_lock():
        if (Path(root) / ".git").exists():
            validate_managed(cfg)
        yield Publication(cfg)


def sync(cfg):
    validate_managed(cfg)
    actor = Publication(cfg)
    state = actor.state()
    actor.check_files(state)
    fetch(cfg)
    remote = git(cfg, "rev-parse", "refs/remotes/origin/" + cfg["branch"])
    head = git(cfg, "rev-parse", "HEAD")
    if state["authorized_commit"]:
        if not cfg["auto_publish"]:
            raise KnowledgeError("automatic publication disabled; pending commit retained", 5)
        result = actor.finish(state)
    else:
        if head != remote:
            # merge --ff-only alone also succeeds when local HEAD is ahead. Do
            # not mistake an unowned local commit for a permitted fast-forward.
            if git(cfg, "merge-base", head, remote) != head:
                raise KnowledgeError("divergent or unowned history; reconcile manually", 5)
            git(cfg, "merge", "--ff-only", "refs/remotes/origin/" + cfg["branch"])
        actor.check_files(state)
        result = actor.finish(state) if cfg["auto_publish"] and state["pending_files"] else {"status": "unchanged"}
    if result["status"] == "pending":
        raise KnowledgeError(result["reason"], 5)
    return {**status(cfg), "sync": result}


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
