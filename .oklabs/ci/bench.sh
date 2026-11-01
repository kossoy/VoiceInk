#!/bin/bash
# Build the scribe-bench harness (arm64), sign it with Developer ID + hardened
# runtime, notarize it, and put scribe-bench-macos-arm64.zip into $OUT_DIR/dist.
# A bare Mach-O cannot be stapled; Gatekeeper checks the ticket online when the
# file is quarantined (a curl download is not).
# Inputs (env): KC, NOTARY_PROFILE, SIGN_IDENTITY, TEAM_ID, OUT_DIR
set -euo pipefail
: "${KC:?}" "${NOTARY_PROFILE:?}" "${SIGN_IDENTITY:?}" "${TEAM_ID:?}" "${OUT_DIR:?}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIST="$OUT_DIR/dist"
WORK="$OUT_DIR/bench"
rm -rf "$WORK"; mkdir -p "$WORK/pkg" "$DIST"

cd "$ROOT"
swift build -c release --product scribe-bench --arch arm64 2>&1 | tail -20
BIN="$(swift build -c release --product scribe-bench --arch arm64 --show-bin-path)/scribe-bench"
[[ -x "$BIN" ]] || { echo "error: scribe-bench binary missing" >&2; exit 1; }
cp "$BIN" "$WORK/pkg/scribe-bench"

codesign --force --options runtime --timestamp --keychain "$KC" \
    --identifier com.oklabs.scribe-bench --sign "$SIGN_IDENTITY" "$WORK/pkg/scribe-bench"
codesign --verify --strict --verbose=2 "$WORK/pkg/scribe-bench"
codesign -dv --verbose=4 "$WORK/pkg/scribe-bench" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Timestamp)='
codesign -dv --verbose=4 "$WORK/pkg/scribe-bench" 2>&1 | grep -q "^TeamIdentifier=$TEAM_ID\$"
lipo -archs "$WORK/pkg/scribe-bench"
"$WORK/pkg/scribe-bench" --help | head -3

ZIP="$DIST/scribe-bench-macos-arm64.zip"
(cd "$WORK/pkg" && ditto -c -k --sequesterRsrc . "$ZIP")
bash "$HERE/notarize.sh" "$ZIP"
