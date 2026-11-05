#!/bin/bash
# Build the normal fork app locally with stable signing and the user's existing settings.
# Does not install, launch, push, notarize, or publish anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${OKLABS_LOCAL_DERIVED_DATA:-$ROOT/.local-build}"
OUTPUT="${OKLABS_LOCAL_OUTPUT_DIR:-$DERIVED/Build/Products/Release}"
IDENTITY="${OKLABS_LOCAL_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning)"
    for KIND in 'Developer ID Application:' 'Apple Development:'; do
        MATCHES="$(printf '%s\n' "$IDENTITIES" | awk -v kind="$KIND" 'index($0,kind) { print $2 }')"
        COUNT="$(printf '%s\n' "$MATCHES" | awk 'NF { n++ } END { print n+0 }')"
        if [[ "$COUNT" == 1 ]]; then IDENTITY="$MATCHES"; break; fi
        if [[ "$COUNT" -gt 1 ]]; then
            echo "Multiple $KIND identities. Set OKLABS_LOCAL_SIGNING_IDENTITY to the intended certificate hash." >&2
            exit 1
        fi
    done
fi
[[ -n "$IDENTITY" && "$IDENTITY" != '-' ]] || {
    echo 'A valid Developer ID or Apple Development certificate is required for stable local signing.' >&2
    exit 1
}

mkdir -p "$DERIVED" "$OUTPUT"
LOG="$DERIVED/oklabs-local-build.log"
if ! xcodebuild -project "$ROOT/VoiceInk.xcodeproj" -scheme VoiceInk -configuration Release \
    -derivedDataPath "$DERIVED" -xcconfig "$ROOT/LocalBuild.xcconfig" \
    CONFIGURATION_BUILD_DIR="$OUTPUT" CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS="$ROOT/VoiceInk/VoiceInk.local.entitlements" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD OKLABS' \
    OKLABS_PRODUCT_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -jobs 4 \
    -skipPackagePluginValidation -skipMacroValidation build > "$LOG" 2>&1; then
    tail -60 "$LOG" >&2
    echo "Build failed. Full log: $LOG" >&2
    exit 1
fi

APP="$OUTPUT/VoiceInk.app"
INFO="$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" == com.prakashjoshipax.VoiceInk ]] || {
    echo 'Unexpected bundle identifier; refusing to hand off a build with different settings.' >&2
    exit 1
}
for KEY in SUFeedURL SUPublicEDKey; do
    if plutil -extract "$KEY" raw "$INFO" >/dev/null 2>&1; then plutil -remove "$KEY" "$INFO"; fi
done
REVISION="$(git -C "$ROOT" rev-parse HEAD)"
if ! git -C "$ROOT" diff --quiet HEAD --; then REVISION="$REVISION-dirty"; fi
if plutil -extract OKLabsSourceRevision raw "$INFO" >/dev/null 2>&1; then
    plutil -replace OKLabsSourceRevision -string "$REVISION" "$INFO"
else
    plutil -insert OKLabsSourceRevision -string "$REVISION" "$INFO"
fi
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements "$ROOT/VoiceInk/VoiceInk.local.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed VoiceInk: $APP"
echo "Build log: $LOG"
