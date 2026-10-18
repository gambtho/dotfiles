"""Publish private review text with cooperating-writer locking and a content CAS.

The caller owns semantic merging and trusted root selection. Each invocation
publishes one file, not a transaction across files. Advisory locks do not
constrain unrelated programs which ignore this protocol.
"""
import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path


class Refusal(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def digest(content):
    return None if content is None else hashlib.sha256(content).hexdigest()


def regular_bytes(path):
    if path.is_symlink():
        raise Refusal("unsafe symlink")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise Refusal("unsafe non-regular file")
    with os.fdopen(fd, "rb") as stream:
        return stream.read()


def store_directory(root, store):
    parts = store.split("/")
    if len(parts) != 2 or any(p in (".", "..") or not re.fullmatch(r"[A-Za-z0-9_.-]+", p) for p in parts):
        raise Refusal("unsafe store slug; expected OWNER/REPO")
    directory = Path(root).expanduser()
    directory.mkdir(mode=0o700, exist_ok=True)
    if directory.is_symlink() or not directory.is_dir():
        raise Refusal("unsafe store root")
    directory = directory.resolve(strict=True)
    for part in parts:
        directory = directory / part
        if directory.is_symlink():
            raise Refusal("unsafe store symlink")
        directory.mkdir(mode=0o700, exist_ok=True)
    return directory


@contextmanager
def store_lock(directory):
    try:
        import fcntl
    except ImportError as error:
        raise Refusal("safe locking is unavailable on this platform") from error
    path = directory / ".review-store.lock"
    if path.is_symlink():
        raise Refusal("unsafe lock symlink")
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NONBLOCK | os.O_NOFOLLOW, 0o600)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise Refusal("unsafe lock file")
    with os.fdopen(fd, "r+b") as stream:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Refusal("busy private review store; leave update pending", 3) from error
        try:
            yield
        finally:
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def scratch_bytes(root, path):
    scratch = Path(root).expanduser().resolve(strict=True)
    candidate = Path(path).expanduser().absolute()
    if not candidate.resolve().is_relative_to(scratch):
        raise Refusal("candidate is outside its scratch root")
    # Reject links within scratch, while allowing a trusted root spelled through
    # an OS alias such as macOS /var -> /private/var.
    for part in (candidate, *candidate.parents):
        if part.resolve() == scratch:
            break
        if part.is_symlink():
            raise Refusal("unsafe candidate symlink")
    try:
        content = regular_bytes(candidate)
    except Refusal as error:
        raise Refusal(f"unsafe candidate: {error}") from error
    if content is None:
        raise Refusal("candidate does not exist")
    content.decode("utf-8")
    return content


def private_temp(directory, prefix, content):
    fd, name = tempfile.mkstemp(dir=directory, prefix=prefix)
    path = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("snapshot", "publish"):
        sub = commands.add_parser(command)
        sub.add_argument("--root", required=True)
        sub.add_argument("--store", required=True)
        sub.add_argument("--file", choices=("review.md", "learnings.md"), required=True)
        if command == "publish":
            sub.add_argument("--expected", required=True)
            sub.add_argument("--candidate-root", required=True)
            sub.add_argument("--candidate", required=True)
    args = parser.parse_args(argv)
    candidate = None
    if args.command == "publish":
        if args.expected != "absent" and not re.fullmatch(r"[a-f0-9]{64}", args.expected):
            raise Refusal("invalid expected digest")
        candidate = scratch_bytes(args.candidate_root, args.candidate)
    directory = store_directory(args.root, args.store)
    target = directory / args.file
    with store_lock(directory):
        old = regular_bytes(target)
        previous = digest(old)
        if args.command == "snapshot":
            print(json.dumps({"sha256": previous}))
            return
        expected = None if args.expected == "absent" else args.expected
        if previous != expected:
            raise Refusal("stale private review snapshot; re-read and merge", 4)
        status = "unchanged"
        if old != candidate:
            if old is not None:
                private_temp(directory, f"{args.file}.backup.", old)
            pending = private_temp(directory, f"{args.file}.candidate.", candidate)
            try:
                os.replace(pending, target)
            finally:
                pending.unlink(missing_ok=True)
            status = "changed"
        print(json.dumps({"status": status, "file": args.file, "old_sha256": previous, "new_sha256": digest(candidate)}))


if __name__ == "__main__":
    try:
        main()
    except Refusal as error:
        print(f"private review store: {error}", file=sys.stderr)
        sys.exit(error.code)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"private review store: {error}", file=sys.stderr)
        sys.exit(2)
