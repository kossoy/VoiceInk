#!/bin/bash
# Build the macOS slice of whisper.xcframework at a pinned whisper.cpp tag, into
# the path the Xcode project references ($HOME/VoiceInk-Dependencies/...).
# Upstream's `make whisper` tracks whisper.cpp master and builds every Apple
# platform; the fork pins a tag so CI is reproducible and cacheable.
set -euo pipefail

WHISPER_TAG="${WHISPER_TAG:-v1.9.5}"
DEPS_DIR="$HOME/VoiceInk-Dependencies"
WHISPER_DIR="$DEPS_DIR/whisper.cpp"
FRAMEWORK="$WHISPER_DIR/build-apple/whisper.xcframework"
STAMP="$WHISPER_DIR/.oklabs-tag"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$FRAMEWORK" && -f "$STAMP" && "$(cat "$STAMP")" == "$WHISPER_TAG" ]]; then
    echo "whisper.xcframework $WHISPER_TAG already built at $FRAMEWORK"
    exit 0
fi

rm -rf "$WHISPER_DIR"
mkdir -p "$DEPS_DIR"
git clone --quiet --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
cd "$WHISPER_DIR"
python3 -I "$HERE/ci/whisper_macos_only.py" build-xcframework.sh build-xcframework-macos.sh
bash ./build-xcframework-macos.sh

ls "$FRAMEWORK"
[[ -d "$FRAMEWORK/macos-arm64_x86_64/whisper.framework" ]] || {
    echo "error: macOS slice missing from $FRAMEWORK" >&2
    exit 1
}
echo "$WHISPER_TAG" > "$STAMP"
