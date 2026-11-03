#!/bin/bash
# Archive + export VoiceInk as a Developer ID app (fork build: LOCAL_BUILD + OKLABS).
# Inputs (env): KC, SIGN_IDENTITY, TEAM_ID, OKLABS_VERSION, OKLABS_BUILD, OUT_DIR
# Output: $OUT_DIR/export/VoiceInk.app, APP=<path> appended to $GITHUB_ENV.
set -euo pipefail
: "${KC:?}" "${SIGN_IDENTITY:?}" "${TEAM_ID:?}" "${OKLABS_VERSION:?}" "${OKLABS_BUILD:?}" "${OUT_DIR:?}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
ARCHIVE="$OUT_DIR/VoiceInk.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$OUT_DIR" "$LOG_DIR"

# Fork plist: no upstream Sparkle feed or key in the shipped app (plan C.4-A).
plutil -remove SUFeedURL VoiceInk/Info.plist
plutil -remove SUPublicEDKey VoiceInk/Info.plist

run_logged() {
    local name="$1"; shift
    echo "==> $name"
    if ! "$@" > "$LOG_DIR/$name.log" 2>&1; then
        echo "error: $name failed; last 200 lines:" >&2
        grep -E '(error|warning: .*sign|Code Sign|codesign)' "$LOG_DIR/$name.log" | tail -60 >&2 || true
        tail -200 "$LOG_DIR/$name.log" >&2
        return 1
    fi
    tail -5 "$LOG_DIR/$name.log"
}

# Only the app and XPC product targets consume this override; host macros stay native.
run_logged archive xcodebuild archive \
    -project VoiceInk.xcodeproj \
    -scheme VoiceInk \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$OUT_DIR/DerivedData" \
    -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    OKLABS_PRODUCT_ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_ENTITLEMENTS="$ROOT/VoiceInk/VoiceInk.local.entitlements" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD OKLABS' \
    OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $KC" \
    MARKETING_VERSION="$OKLABS_VERSION" \
    CURRENT_PROJECT_VERSION="$OKLABS_BUILD"

rm -rf "$EXPORT_DIR"
if ! run_logged export xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$ROOT/.oklabs/ExportOptions.plist"; then
    echo "warning: -exportArchive failed; falling back to the archived app + nested re-sign" >&2
    mkdir -p "$EXPORT_DIR"
    ditto "$ARCHIVE/Products/Applications/VoiceInk.app" "$EXPORT_DIR/VoiceInk.app"
    FORCE_RESIGN=1
fi
APP="$EXPORT_DIR/VoiceInk.app"
[[ -d "$APP" ]] || { echo "error: exported app missing" >&2; exit 1; }

# Every nested code item must carry our team, hardened runtime and a timestamp,
# otherwise notarization rejects it. Export normally does this; re-sign
# inside-out only when something is off.
nested_items() {
    # Code bundles at any depth (frameworks, XPC services, helper apps, plug-ins).
    find "$APP/Contents" -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' -o -name '*.bundle' \) 2>/dev/null \
        | while read -r b; do
            # Resource-only bundles carry no code and need no signature.
            if [[ "$b" == *.framework ]] || [[ -n "$(plutil -extract CFBundleExecutable raw "$b/Contents/Info.plist" 2>/dev/null || true)" ]]; then
                echo "$b"
            fi
        done
    # Loose Mach-O files: dylibs and helper tools such as Sparkle's Autoupdate.
    find "$APP/Contents" -type f \( -name '*.dylib' -o -perm +111 \) -not -path '*/_CodeSignature/*' -not -path "$APP/Contents/MacOS/*" 2>/dev/null \
        | while read -r f; do if file -b "$f" | grep -q 'Mach-O'; then echo "$f"; fi; done
    return 0
}
by_depth_desc() { awk '{ n = gsub("/", "/"); print n "\t" $0 }' | sort -t$'\t' -k1,1nr | cut -f2-; }
# Team and secure timestamp everywhere; hardened runtime only where it means
# something (executables and bundles). A dylib's runtime flag is irrelevant to
# notarization, so Xcode's own dylib signatures are left as exported.
check_item() {
    local info
    info="$(codesign -dv --verbose=4 "$1" 2>&1 || true)"
    grep -q "^TeamIdentifier=$TEAM_ID\$" <<<"$info" || return 1
    grep -q '^Timestamp=' <<<"$info" || return 1
    [[ "$1" == *.dylib ]] && return 0
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\(.*runtime' <<<"$info" || return 1
}
BAD_ITEMS=()
while read -r item; do
    [[ -n "$item" ]] || continue
    if check_item "$item"; then
        echo "ok   ${item#"$APP"/}"
    else
        echo "BAD  ${item#"$APP"/}"
        codesign -dv --verbose=4 "$item" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Timestamp|CodeDirectory|Authority)=?' | sed 's/^/       /' || true
        BAD_ITEMS+=("$item")
    fi
done < <(nested_items | sort -u)

resign() {
    codesign --force --options runtime --timestamp --keychain "$KC" \
        --preserve-metadata=identifier,entitlements,flags --sign "$SIGN_IDENTITY" "$1"
}
if [[ "${FORCE_RESIGN:-0}" == 1 ]]; then
    echo "==> re-signing all nested code inside-out (export failed)"
    nested_items | sort -u | by_depth_desc | while read -r item; do resign "$item"; done
    codesign --force --options runtime --timestamp --keychain "$KC" \
        --entitlements "$ROOT/VoiceInk/VoiceInk.local.entitlements" --sign "$SIGN_IDENTITY" "$APP"
elif [[ ${#BAD_ITEMS[@]} -gt 0 ]]; then
    # Re-sign only what failed, then every bundle that contains it (its seal
    # covers the changed file), deepest first; everything else keeps the export's
    # signature.
    echo "==> re-signing ${#BAD_ITEMS[@]} item(s) and their containing bundles"
    {
        for item in "${BAD_ITEMS[@]}"; do
            echo "$item"
            parent="$(dirname "$item")"
            while [[ "$parent" != "$APP" && "$parent" == "$APP"/* ]]; do
                case "$parent" in
                    *.framework | *.xpc | *.app | *.appex | *.bundle) echo "$parent" ;;
                esac
                parent="$(dirname "$parent")"
            done
        done
    } | sort -u | by_depth_desc | while read -r item; do resign "$item"; done
    codesign --force --options runtime --timestamp --keychain "$KC" \
        --entitlements "$ROOT/VoiceInk/VoiceInk.local.entitlements" --sign "$SIGN_IDENTITY" "$APP"
fi

echo "==> verify"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)'
check_item "$APP" || { echo "error: app signature lacks team/runtime/timestamp" >&2; exit 1; }
echo "entitlements:"; codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true

INFO="$APP/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw "$INFO")" == "$OKLABS_VERSION" ]] || { echo "error: version mismatch" >&2; exit 1; }
[[ "$(plutil -extract CFBundleIdentifier raw "$INFO")" == "com.prakashjoshipax.VoiceInk" ]] || { echo "error: bundle id mismatch" >&2; exit 1; }
if plutil -extract SUFeedURL raw "$INFO" >/dev/null 2>&1 || plutil -extract SUPublicEDKey raw "$INFO" >/dev/null 2>&1; then
    echo "error: Sparkle feed/key still present in the shipped Info.plist" >&2; exit 1
fi
for binary in "$APP/Contents/MacOS/VoiceInk" "$APP/Contents/XPCServices/VoiceInkRefineXPC.xpc/Contents/MacOS/VoiceInkRefineXPC"; do
    lipo "$binary" -verify_arch arm64
    [[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "error: expected an arm64-only product: $binary" >&2; exit 1; }
done
lipo -archs "$APP/Contents/MacOS/VoiceInk"

echo "APP=$APP" >> "$GITHUB_ENV"
