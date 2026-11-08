#!/bin/bash
# Download latest-release assets, recovering GitHub browser-route transport errors
# through the official asset API. Callers must still verify identity and checksums.
set -euo pipefail
DEST="${1:?usage: download-release-assets.sh DEST ASSET...}"; shift
[[ $# -gt 0 ]] || { echo 'No assets requested' >&2; exit 1; }
REPO="${GITHUB_REPOSITORY:-kossoy/VoiceInk}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
for asset in "$@"; do
    if ! curl -fsSL --connect-timeout 15 --max-time 120 \
        "https://github.com/$REPO/releases/latest/download/$asset" -o "$DEST/$asset"; then
        echo 'GitHub browser download failed; retrying through the release asset API'
        args=(release download --repo "$REPO" --dir "$DEST" --clobber)
        for requested in "$@"; do args+=(--pattern "$requested"); done
        gh "${args[@]}"
        exit 0
    fi
done
