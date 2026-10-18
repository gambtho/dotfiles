"""Real Git fixtures; only GitHub metadata and network transport are replaced."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "ai/marketplace/plugins/my/skills/pr-closeout/scripts/knowledge_git.py"
PUBLISHER = CONTROLLER.with_name("private_review_store.py")


class KnowledgeFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir(mode=0o700)
        self.root = self.home / ".pi/pr-reviews"
        self.root.parent.mkdir()
        self.bare = self.home / ".local/share/agent-knowledge.git"
        self.config = self.home / ".config/dotfiles/agent-knowledge.json"
        self.state = self.home / ".local/state/dotfiles/agent-knowledge"
        self.remote = self.base / "remote.git"
        self.seed = self.base / "seed"
        self.meta = self.base / "metadata.json"
        self.meta.write_text(json.dumps({"full_name": "fixture/knowledge", "private": True, "default_branch": "main"}))
        self.log = self.base / "network.log"
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        self.real_git = shutil.which("git")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "DOTFILES_AGENT_KNOWLEDGE_REPO")}
        self.env.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / ".config"), XDG_DATA_HOME=str(self.home / ".local/share"), XDG_STATE_HOME=str(self.home / ".local/state"), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.home / ".gitconfig"), GIT_TERMINAL_PROMPT="0", TEST_REMOTE=str(self.remote), TEST_REAL_GIT=self.real_git, TEST_META=str(self.meta), TEST_LOG=str(self.log), PATH=str(bin_dir) + os.pathsep + self.env["PATH"])
        (self.home / ".gitconfig").write_text("[user]\n name = Fixture\n email = fixture@example.invalid\n")
        git_shim = bin_dir / "git"
        git_shim.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
args=sys.argv[1:]
network=next((i for i,a in enumerate(args) if a in ('clone','fetch','push')),None)
if network is not None:
    verb=args[network]
    if verb=='push':Path(os.environ['TEST_LOG']).with_suffix('.push-argv').write_text(json.dumps(args))
    with open(os.environ['TEST_LOG'],'a') as log: log.write(verb+'\\n')
    meta=Path(os.environ['TEST_META'])
    if meta.with_suffix('.offline').exists() or (verb=='push' and meta.with_suffix('.push-fail').exists()):sys.exit(71)
    args=[os.environ['TEST_REMOTE'] if a=='origin' or a=='https://github.com/fixture/knowledge.git' else a for a in args]
    if any(a.startswith(('https://','http://','ssh://','git@')) for a in args):sys.exit(96)
sys.exit(subprocess.call([os.environ['TEST_REAL_GIT'],*args]))
''')
        git_shim.chmod(0o700)
        gh_shim = bin_dir / "gh"
        gh_shim.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
from pathlib import Path
meta=Path(os.environ['TEST_META'])
with open(os.environ['TEST_LOG'],'a') as log:log.write('gh\\n')
if meta.with_suffix('.offline').exists():sys.exit(72)
expected=meta.with_suffix('.cwd')
if expected.exists() and str(Path.cwd())!=expected.read_text():sys.exit(73)
if '/git/ref/heads/' in ' '.join(sys.argv):
    sha=subprocess.check_output([os.environ['TEST_REAL_GIT'],'--git-dir='+os.environ['TEST_REMOTE'],'rev-parse','main'],text=True).strip()
    print(json.dumps({'object':{'sha':sha}}))
else:print(meta.read_text())
''')
        gh_shim.chmod(0o700)
        self.git("init", "--initial-branch=main", str(self.seed))
        (self.seed / "owner/repo").mkdir(parents=True)
        (self.seed / "owner/repo/review.md").write_text("old\n")
        (self.seed / ".gitignore").write_text("**/.review-store.lock\n**/*.backup.*\n**/*.candidate.*\n")
        self.git("-C", str(self.seed), "add", ".")
        self.git("-C", str(self.seed), "commit", "-m", "initial")
        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("-C", str(self.seed), "remote", "add", "origin", str(self.remote))
        self.git("-C", str(self.seed), "push", "origin", "main")

    def git(self, *args):
        return subprocess.check_output([self.real_git, *args], env=self.env, text=True, stderr=subprocess.PIPE).strip()

    def cli(self, action="ensure", configure=False):
        env = dict(self.env)
        if configure:
            env["DOTFILES_AGENT_KNOWLEDGE_REPO"] = "fixture/knowledge"
        return subprocess.run([sys.executable, str(CONTROLLER), action], env=env, text=True, capture_output=True, check=False)

    def setup_store(self):
        result = self.cli(configure=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def advance(self, path="other/repo/review.md", text="remote change\n"):
        target = self.seed / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        self.git("-C", str(self.seed), "add", "--", path)
        self.git("-C", str(self.seed), "commit", "-m", "remote update")
        self.git("-C", str(self.seed), "push", "origin", "main")

    def head(self, root=None):
        return self.git("-C", str(root or self.root), "rev-parse", "HEAD")

    def offline(self):
        self.meta.with_suffix(".offline").touch()

    def publish(self, text="new\n", store="owner/repo", file="review.md", expected=None, root=None):
        import hashlib
        target = self.root / store / file
        if expected is None:
            expected = hashlib.sha256(target.read_bytes()).hexdigest() if target.exists() else "absent"
        scratch = self.base / "scratch"
        scratch.mkdir(exist_ok=True)
        candidate = scratch / (store.replace("/", "-") + "-" + file)
        candidate.write_text(text)
        return subprocess.run([sys.executable, str(PUBLISHER), "publish", "--root", str(root or self.root), "--store", store, "--file", file, "--expected", expected, "--candidate-root", str(scratch), "--candidate", str(candidate)], env=self.env, text=True, capture_output=True, check=False)
