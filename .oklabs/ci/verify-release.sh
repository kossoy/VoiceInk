#!/bin/bash
# Verify an already-published latest release without rebuilding or changing it.
set -euo pipefail
TAG="${1:?usage: verify-release.sh TAG COMMIT DEST [EXPECTED_SHA256SUMS]}"
COMMIT="${2:?expected source commit required}"
DEST="${3:?download directory required}"
EXPECTED_SUMS="${4:-}"
REPO="${GITHUB_REPOSITORY:-kossoy/VoiceInk}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected an exact source commit SHA' >&2; exit 1; }
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
gh api "repos/$REPO/releases/latest" > "$DEST/release.json"
[[ "$(jq -r .tag_name "$DEST/release.json")" == "$TAG" ]] || { echo 'Latest release tag differs from expected tag' >&2; exit 1; }
[[ "$(jq -r .target_commitish "$DEST/release.json")" == "$COMMIT" ]] || { echo 'Release source differs from expected commit' >&2; exit 1; }
[[ "$(gh api "repos/$REPO/commits/$TAG" --jq .sha)" == "$COMMIT" ]] || { echo 'Release tag resolves to another commit' >&2; exit 1; }
ASSETS=(SHA256SUMS VoiceInk-oklabs.zip VoiceInk-oklabs.dmg scribe-bench-macos-arm64.zip)
bash "$HERE/download-release-assets.sh" "$DEST" "${ASSETS[@]}"
# Bind the manifest itself, and every artifact, to the exact release API metadata.
# API fallback never turns missing, stale or corrupted bytes into a passing check.
for asset in "${ASSETS[@]}"; do
    expected="$(jq -er --arg name "$asset" '[.assets[] | select(.name == $name)] | if length == 1 then .[0].digest else error("missing or duplicate asset") end' "$DEST/release.json")"
    [[ "$expected" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Missing SHA256 digest for $asset" >&2; exit 1; }
    actual="$(shasum -a 256 "$DEST/$asset" | cut -d' ' -f1)"
    [[ "sha256:$actual" == "$expected" ]] || { echo "Release asset digest mismatch: $asset" >&2; exit 1; }
done
if [[ -n "$EXPECTED_SUMS" ]]; then
    cmp "$EXPECTED_SUMS" "$DEST/SHA256SUMS" || { echo 'Published checksums differ from this build' >&2; exit 1; }
fi
(cd "$DEST" && shasum -a 256 -c SHA256SUMS)
[[ "$(gh api "repos/$REPO/releases/latest" --jq .tag_name)" == "$TAG" ]] || { echo 'Latest release changed during verification' >&2; exit 1; }
echo "Verified latest release $TAG from $COMMIT: all asset digests and checksums match."
