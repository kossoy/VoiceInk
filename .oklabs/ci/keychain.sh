#!/bin/bash
# Ephemeral signing keychain for GitHub-hosted macOS runners.
#
#   keychain.sh setup    import the Developer ID identity + Apple's G2 intermediate,
#                        pin the certificate, store notarytool credentials,
#                        and export KC / NOTARY_PROFILE to $GITHUB_ENV
#   keychain.sh cleanup  restore the search list and delete the keychain
#
# Unlike Okilum's hosted helper, the job keychain IS added to the user search
# list: codesign and xcodebuild -exportArchive build the certificate chain from
# the search list, and without it the first codesign fails with
# "The specified item could not be found in the keychain".
#
# Never run with `set -x`: the P12 password and notary password are arguments.
set -euo pipefail

KC="${RUNNER_TEMP:?}/oklabs-signing.keychain-db"
NOTARY_PROFILE="oklabs-notary"
G2_URL="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"

setup() {
    : "${MAC_DEVELOPER_ID_P12:?missing secret MAC_DEVELOPER_ID_P12}"
    : "${MAC_DEVELOPER_ID_PASSWORD:?missing secret MAC_DEVELOPER_ID_PASSWORD}"
    : "${MAC_CERT_SHA256:?missing secret MAC_CERT_SHA256}"
    : "${MAC_NOTARY_APPLE_ID:?missing secret MAC_NOTARY_APPLE_ID}"
    : "${MAC_NOTARY_PASSWORD:?missing secret MAC_NOTARY_PASSWORD}"
    : "${MAC_NOTARY_TEAM:?missing secret MAC_NOTARY_TEAM}"
    : "${SIGN_IDENTITY:?}"
    [[ "$SIGN_IDENTITY" == *"($MAC_NOTARY_TEAM)" ]] || { echo "error: identity and notary team differ" >&2; exit 1; }

    local work="$RUNNER_TEMP/oklabs-signing"
    rm -rf "$work"; mkdir -m 700 "$work"
    local kc_password
    kc_password="$(uuidgen)-$(uuidgen)"

    security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//' > "$work/search-list.orig"

    security create-keychain -p "$kc_password" "$KC"
    security set-keychain-settings -lut 21600 "$KC"
    security unlock-keychain -p "$kc_password" "$KC"

    printf '%s' "$MAC_DEVELOPER_ID_P12" | base64 --decode > "$work/identity.p12"
    security import "$work/identity.p12" -k "$KC" -P "$MAC_DEVELOPER_ID_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign >/dev/null
    rm -f "$work/identity.p12"

    curl -fsSL --retry 3 "$G2_URL" -o "$work/DeveloperIDG2CA.cer"
    security import "$work/DeveloperIDG2CA.cer" -k "$KC" >/dev/null 2>&1 \
        || security add-certificates -k "$KC" "$work/DeveloperIDG2CA.cer"

    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_password" "$KC" >/dev/null

    # Job keychain first, then whatever the runner had (login + System stay reachable).
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$KC" $(cat "$work/search-list.orig")
    echo "keychain search list:"; security list-keychains -d user

    # Certificate pin: the imported leaf must be exactly the frozen certificate.
    local pinned actual
    pinned="$(printf '%s' "$MAC_CERT_SHA256" | tr '[:lower:]' '[:upper:]')"
    actual="$(security find-certificate -a -Z -c "$SIGN_IDENTITY" "$KC" | awk '/^SHA-256 hash:/ {print toupper($3)}')"
    if [[ "$(printf '%s\n' "$actual" | grep -c .)" != 1 || "$actual" != "$pinned" ]]; then
        echo "error: imported certificate does not match MAC_CERT_SHA256" >&2
        exit 1
    fi
    echo "certificate pin: ok"

    security find-identity -v -p codesigning "$KC" | tee "$work/identities.txt"
    grep -qF "\"$SIGN_IDENTITY\"" "$work/identities.txt" || { echo "error: identity not valid for codesigning" >&2; exit 1; }

    xcrun notarytool store-credentials "$NOTARY_PROFILE" --keychain "$KC" \
        --apple-id "$MAC_NOTARY_APPLE_ID" --team-id "$MAC_NOTARY_TEAM" --password "$MAC_NOTARY_PASSWORD" >/dev/null
    echo "notarytool profile: ok"

    {
        echo "KC=$KC"
        echo "NOTARY_PROFILE=$NOTARY_PROFILE"
    } >> "$GITHUB_ENV"
}

cleanup() {
    local work="$RUNNER_TEMP/oklabs-signing"
    if [[ -f "$work/search-list.orig" ]]; then
        # shellcheck disable=SC2046
        security list-keychains -d user -s $(cat "$work/search-list.orig") || true
    fi
    [[ -e "$KC" ]] && security delete-keychain "$KC" || true
    rm -rf "$work"
    echo "signing keychain removed"
}

case "${1:-}" in
    setup) setup ;;
    cleanup) cleanup ;;
    *) echo "usage: $0 setup|cleanup" >&2; exit 2 ;;
esac
