"""Exercise transport recovery and provenance/integrity gates without network access."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


VERIFY = Path(__file__).resolve().parents[1] / "verify-release.sh"
COMMIT = "a" * 40
TAG = "oklabs-2.26-test"
ARTIFACTS = ("VoiceInk-oklabs.zip", "VoiceInk-oklabs.dmg", "scribe-bench-macos-arm64.zip")


class ReleaseDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.assets = self.root / "assets"
        self.assets.mkdir()
        sums = []
        for name in ARTIFACTS:
            content = f"verified fixture: {name}\n".encode()
            (self.assets / name).write_bytes(content)
            sums.append(f"{hashlib.sha256(content).hexdigest()}  {name}\n")
        (self.assets / "SHA256SUMS").write_text("".join(sums))
        self.metadata = {
            "tag_name": TAG,
            "target_commitish": COMMIT,
            "assets": [{"name": p.name, "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest()}
                       for p in self.assets.iterdir()],
        }
        self.write_metadata()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        MOCK_ROOT=str(self.root), MOCK_TAG_COMMIT=COMMIT,
                        GITHUB_REPOSITORY="kossoy/VoiceInk")
        self.executable("curl", r'''#!/bin/bash
set -euo pipefail
echo browser >> "$MOCK_ROOT/calls"
dest= url=
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ "${MOCK_BROWSER_FAIL:-0}" != 1 ]] || exit 22
if [[ "${MOCK_BROWSER_CORRUPT:-0}" == 1 && "$url" == *.zip ]]; then
    echo corrupt > "$dest"
else
    cp "$MOCK_ROOT/assets/${url##*/}" "$dest"
fi
''')
        self.executable("gh", r'''#!/bin/bash
set -euo pipefail
if [[ "$1" == api ]]; then
    if [[ "$2" == */commits/* ]]; then
        echo "$MOCK_TAG_COMMIT"
    elif [[ "${3:-}" == --jq ]]; then
        jq -r .tag_name "$MOCK_ROOT/latest.json"
    else
        cat "$MOCK_ROOT/latest.json"
    fi
    exit 0
fi
[[ "$1 $2" == 'release download' ]]
echo api-download >> "$MOCK_ROOT/calls"
[[ "${MOCK_API_FAIL:-0}" != 1 ]] || exit 42
shift 2
assets=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) dest="$2"; shift 2 ;;
        --pattern) assets+=("$2"); shift 2 ;;
        --repo) shift 2 ;;
        --clobber) shift ;;
        *) exit 43 ;;
    esac
done
for asset in "${assets[@]}"; do cp "$MOCK_ROOT/assets/$asset" "$dest/$asset"; done
if [[ "${MOCK_API_CORRUPT:-0}" == 1 ]]; then echo stale > "$dest/SHA256SUMS"; fi
''')

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def write_metadata(self):
        (self.root / "latest.json").write_text(json.dumps(self.metadata))

    def verify(self, succeeds=True, expected_sums=None):
        args = ["bash", str(VERIFY), TAG, COMMIT, str(self.root / "download")]
        if expected_sums:
            args.append(str(expected_sums))
        result = subprocess.run(args, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def calls(self):
        path = self.root / "calls"
        return path.read_text() if path.exists() else ""

    def test_healthy_browser_route_checks_all_assets_without_api_download(self):
        self.verify(expected_sums=self.assets / "SHA256SUMS")
        self.assertEqual(self.calls().count("browser"), 4)
        self.assertNotIn("api-download", self.calls())

    def test_browser_transport_failure_recovers_via_api(self):
        self.env["MOCK_BROWSER_FAIL"] = "1"
        self.assertIn("all asset digests and checksums match", self.verify())
        self.assertIn("api-download", self.calls())

    def test_both_transports_failing_stays_failed(self):
        self.env.update(MOCK_BROWSER_FAIL="1", MOCK_API_FAIL="1")
        self.verify(succeeds=False)

    def test_corrupted_browser_bytes_are_not_hidden_by_fallback(self):
        self.env["MOCK_BROWSER_CORRUPT"] = "1"
        self.assertIn("digest mismatch", self.verify(succeeds=False))
        self.assertNotIn("api-download", self.calls())

    def test_api_fallback_cannot_supply_stale_manifest(self):
        self.env.update(MOCK_BROWSER_FAIL="1", MOCK_API_CORRUPT="1")
        self.assertIn("digest mismatch: SHA256SUMS", self.verify(succeeds=False))

    def test_wrong_latest_tag_stops_before_download(self):
        self.metadata["tag_name"] = "another-release"
        self.write_metadata()
        self.assertIn("Latest release tag differs", self.verify(succeeds=False))
        self.assertEqual(self.calls(), "")

    def test_wrong_release_source_stops_before_download(self):
        self.metadata["target_commitish"] = "b" * 40
        self.write_metadata()
        self.assertIn("Release source differs", self.verify(succeeds=False))
        self.assertEqual(self.calls(), "")

    def test_retagged_release_stops_before_download(self):
        self.env["MOCK_TAG_COMMIT"] = "b" * 40
        self.assertIn("tag resolves to another commit", self.verify(succeeds=False))
        self.assertEqual(self.calls(), "")

    def test_published_checksums_must_match_original_build(self):
        sums = self.root / "original-build-sums"
        sums.write_text("different build\n")
        self.assertIn("Published checksums differ", self.verify(succeeds=False, expected_sums=sums))


if __name__ == "__main__":
    unittest.main()
