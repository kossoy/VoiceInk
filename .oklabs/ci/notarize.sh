#!/bin/bash
# notarize.sh <file.zip|file.dmg>  — submit, wait, require "Accepted", print the
# notary log either way (it lists every rejected binary on failure).
set -euo pipefail
FILE="${1:?usage: notarize.sh <file>}"
: "${KC:?}" "${NOTARY_PROFILE:?}"

OUT="$RUNNER_TEMP/notary-$(basename "$FILE").json"
for attempt in 1 2 3; do
    if xcrun notarytool submit "$FILE" --keychain-profile "$NOTARY_PROFILE" --keychain "$KC" \
        --wait --timeout 45m --output-format json > "$OUT"; then
        break
    fi
    # A non-zero exit with a status in the JSON is a real verdict, not a transport error.
    if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status") else 1)' "$OUT" 2>/dev/null; then
        break
    fi
    echo "notarytool submit failed (attempt $attempt), retrying in 30 s" >&2
    sleep 30
done
cat "$OUT"; echo

STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$OUT")"
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$OUT")"
if [[ -n "$ID" ]]; then
    xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" --keychain "$KC" || true
fi
if [[ "$STATUS" != "Accepted" ]]; then
    echo "error: notarization of $(basename "$FILE") ended with status '$STATUS'" >&2
    exit 1
fi
echo "notarization of $(basename "$FILE"): Accepted"
