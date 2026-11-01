#!/bin/bash
# Notarize + staple the app, build the release zip and DMG (DMG signed, notarized,
# stapled), check both the way a downloaded copy is checked, write SHA256SUMS.
# Inputs (env): APP, KC, NOTARY_PROFILE, SIGN_IDENTITY, OUT_DIR
# Output: $OUT_DIR/dist/{VoiceInk-oklabs.zip,VoiceInk-oklabs.dmg,SHA256SUMS}
set -euo pipefail
: "${APP:?}" "${KC:?}" "${NOTARY_PROFILE:?}" "${SIGN_IDENTITY:?}" "${OUT_DIR:?}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$OUT_DIR/dist"
WORK="$OUT_DIR/package"
rm -rf "$DIST" "$WORK"; mkdir -p "$DIST" "$WORK"

echo "==> notarize app"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarization-app.zip"
bash "$HERE/notarize.sh" "$WORK/notarization-app.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"

echo "==> release zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/VoiceInk-oklabs.zip"

echo "==> Gatekeeper check of a quarantined copy of the zip"
mkdir "$WORK/fresh"
ditto -x -k "$DIST/VoiceInk-oklabs.zip" "$WORK/fresh"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$WORK/fresh/VoiceInk.app"
codesign --verify --deep --strict --verbose=2 "$WORK/fresh/VoiceInk.app"
spctl -a -t exec -vv "$WORK/fresh/VoiceInk.app"

echo "==> DMG"
mkdir "$WORK/dmg-root"
ditto "$APP" "$WORK/dmg-root/VoiceInk.app"
ln -s /Applications "$WORK/dmg-root/Applications"
DMG="$DIST/VoiceInk-oklabs.dmg"
for attempt in 1 2 3 4; do
    # hdiutil on hosted runners fails now and then with "Resource busy".
    if hdiutil create -volname "VoiceInk" -srcfolder "$WORK/dmg-root" -fs APFS -format UDZO -ov "$DMG"; then
        break
    fi
    [[ $attempt == 4 ]] && { echo "error: hdiutil create failed" >&2; exit 1; }
    sleep $((attempt * 10))
done
codesign --force --timestamp --keychain "$KC" --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
bash "$HERE/notarize.sh" "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "==> DMG contents"
MNT="$(mktemp -d)"
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true' EXIT
codesign --verify --deep --strict --verbose=2 "$MNT/VoiceInk.app"
xcrun stapler validate "$MNT/VoiceInk.app"
spctl -a -t exec -vv "$MNT/VoiceInk.app"
[[ -L "$MNT/Applications" ]]
hdiutil detach "$MNT" >/dev/null; trap - EXIT

(cd "$DIST" && shasum -a 256 VoiceInk-oklabs.zip VoiceInk-oklabs.dmg > SHA256SUMS && cat SHA256SUMS)
