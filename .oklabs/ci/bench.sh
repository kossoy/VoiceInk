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
lipo "$BIN" -verify_arch arm64
cp "$BIN" "$WORK/pkg/scribe-bench"

codesign --force --options runtime --timestamp --keychain "$KC" \
    --identifier com.oklabs.scribe-bench --sign "$SIGN_IDENTITY" "$WORK/pkg/scribe-bench"
codesign --verify --strict --verbose=2 "$WORK/pkg/scribe-bench"
SIGNATURE="$(codesign -dv --verbose=4 "$WORK/pkg/scribe-bench" 2>&1)"
grep -E '^(Identifier|TeamIdentifier|Timestamp)=' <<< "$SIGNATURE"
grep -q "^TeamIdentifier=$TEAM_ID\$" <<< "$SIGNATURE"
lipo -archs "$WORK/pkg/scribe-bench"

# The published harness stays arm64 on Intel runners. Smoke-test the same product
# natively rather than trying to execute the arm64 release artifact there.
HOST_ARCH="$(uname -m)"
SMOKE_BIN="$WORK/pkg/scribe-bench"
if [[ "$HOST_ARCH" != arm64 ]]; then
    swift build -c release --product scribe-bench --arch "$HOST_ARCH" 2>&1 | tail -20
    SMOKE_BIN="$(swift build -c release --product scribe-bench --arch "$HOST_ARCH" --show-bin-path)/scribe-bench"
    [[ -x "$SMOKE_BIN" ]] || { echo "error: native scribe-bench binary missing" >&2; exit 1; }
    lipo "$SMOKE_BIN" -verify_arch "$HOST_ARCH"
    echo "Smoke test: native $HOST_ARCH helper (published artifact remains arm64)"
else
    echo "Smoke test: published arm64 harness"
fi
HELP_OUTPUT="$("$SMOKE_BIN" --help)"
head -3 <<< "$HELP_OUTPUT"

ZIP="$DIST/scribe-bench-macos-arm64.zip"
(cd "$WORK/pkg" && ditto -c -k --sequesterRsrc . "$ZIP")
bash "$HERE/notarize.sh" "$ZIP"
