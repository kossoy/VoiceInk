"""Exercise the fork guard against real local Git histories, without network access."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


GUARD = Path(__file__).resolve().parents[1] / "check-fork-contracts.py"


class ForkContractsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.repo = root / "repo"
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="Guard test", GIT_AUTHOR_EMAIL="guard@example.invalid",
                        GIT_COMMITTER_NAME="Guard test", GIT_COMMITTER_EMAIL="guard@example.invalid")
        self.git("init", "-q", "-b", "main")
        self.write("VoiceInk/OKLabs/engine.swift", "fork implementation\n")
        self.write("VoiceInk/App.swift", "before\nstartForkEngine()\nafter\n")
        self.write(".github/workflows/oklabs-test.yml", "trusted tests\n")
        self.write("README.md", "upstream documentation\n")
        self.base = self.commit("Fork base")
        self.manifest = root / "contracts.json"
        self.manifest.write_text(json.dumps({
            "protected_paths": ["VoiceInk/OKLabs/**", ".github/workflows/**"],
            "required_snippets": {"VoiceInk/App.swift": ["startForkEngine()"]},
        }))

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.repo, env=self.env, stderr=subprocess.PIPE).decode().strip()

    def write(self, name, contents):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def guard(self, candidate, error=None):
        result = subprocess.run(
            [sys.executable, str(GUARD), "--base", self.base, "--candidate", candidate,
             "--manifest", str(self.manifest)], cwd=self.repo, env=self.env,
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0 if error is None else 1, result.stdout + result.stderr)
        if error is not None:
            self.assertIn(error, result.stderr)

    def test_ordinary_upstream_changes_with_hooks_preserved_are_allowed(self):
        self.write("VoiceInk/App.swift", "new upstream setup\nstartForkEngine()\nnew upstream behavior\n")
        self.write("README.md", "updated documentation\n")
        self.guard(self.commit("Compatible upstream change"))

    def test_clean_merge_removing_a_hook_is_rejected(self):
        # A textual merge can succeed while deleting the app's only use of fork code.
        self.git("switch", "-qc", "incoming")
        self.write("VoiceInk/App.swift", "before\nstartUpstreamEngine()\nafter\n")
        self.commit("Upstream replaces startup")
        self.git("switch", "-q", "main")
        self.git("merge", "--no-ff", "-qm", "Clean upstream merge", "incoming")
        self.guard("HEAD", "fork hook missing in VoiceInk/App.swift")

    def test_overwritten_fork_implementation_is_rejected(self):
        self.write("VoiceInk/OKLabs/engine.swift", "upstream replacement\n")
        self.guard(self.commit("Overwrite fork code"), "upstream changed fork-owned path")

    def test_deleted_fork_implementation_is_rejected(self):
        self.git("rm", "-q", "VoiceInk/OKLabs/engine.swift")
        self.guard(self.commit("Delete fork code"), "VoiceInk/OKLabs/engine.swift")

    def test_added_fork_implementation_is_rejected(self):
        self.write("VoiceInk/OKLabs/new.swift", "unexpected fork addition\n")
        self.guard(self.commit("Add to fork namespace"), "VoiceInk/OKLabs/new.swift")

    def test_rename_out_of_protected_namespace_is_rejected(self):
        self.git("mv", "VoiceInk/OKLabs/engine.swift", "VoiceInk/engine.swift")
        self.guard(self.commit("Move fork code out of namespace"), "VoiceInk/OKLabs/engine.swift")

    def test_replaced_test_workflow_is_rejected(self):
        self.write(".github/workflows/oklabs-test.yml", "skip tests\n")
        self.guard(self.commit("Disable validation"), ".github/workflows/oklabs-test.yml")

    def test_new_incoming_workflow_is_rejected(self):
        self.write(".github/workflows/new-upstream.yml", "on: push\n")
        self.guard(self.commit("New incoming workflow"), ".github/workflows/new-upstream.yml")

    def test_missing_integration_file_is_rejected(self):
        self.git("rm", "-q", "VoiceInk/App.swift")
        self.guard(self.commit("Remove integration"), "fork integration file missing: VoiceInk/App.swift")


if __name__ == "__main__":
    unittest.main()
