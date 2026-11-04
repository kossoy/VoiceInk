#!/bin/bash
# Nightly fork sync: merge Beingpax/VoiceInk main into the existing fork history,
# then fast-forward `upstream` and `main` atomically with exact leases.
# A merge conflict aborts the merge and fails the run (nothing pushed).
#
# Env:
#   UPSTREAM_URL  upstream repository (default https://github.com/Beingpax/VoiceInk.git)
#   UPSTREAM_REF  optional override "owner/repo:ref" for dry-run tests only
#   DRY_RUN       "true" = merge and report, push nothing
#   SYNC_RESULT   optional file: key=value lines for notify.sh (result, error, upstream,
#                 subject, one conflict= line per file)
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/Beingpax/VoiceInk.git}"
UPSTREAM_REF="${UPSTREAM_REF:-}"
DRY_RUN="${DRY_RUN:-false}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

summary() { printf '%s\n' "$@" >> "$SUMMARY"; }

RESULT="${SYNC_RESULT:-}"
note() { if [[ -n "$RESULT" ]]; then printf '%s=%s\n' "$1" "$2" >> "$RESULT"; fi; }
fail() { note result error; note error "$1"; echo "::error::$1"; exit 1; }
if [[ -n "$RESULT" ]]; then : > "$RESULT"; fi
# Any other failing command: record it for the Telegram message, then set -e exits.
trap 'note result error; note error "line $LINENO: $BASH_COMMAND failed"' ERR

git config user.name "Oleg Kossoy"
git config user.email "51094+kossoy@users.noreply.github.com"

if [[ -n "$UPSTREAM_REF" ]]; then
    [[ "$DRY_RUN" == "true" ]] || fail "upstream_ref overrides are for dry runs only"
    SOURCE_URL="https://github.com/${UPSTREAM_REF%%:*}.git"
    SOURCE_REF="${UPSTREAM_REF#*:}"
else
    SOURCE_URL="$UPSTREAM_URL"
    SOURCE_REF="main"
fi

git fetch --quiet --no-tags origin main upstream
OLD_MAIN="$(git rev-parse origin/main)"
OLD_UPSTREAM="$(git rev-parse origin/upstream)"
git fetch --quiet --no-tags "$SOURCE_URL" "$SOURCE_REF"
NEW_UPSTREAM="$(git rev-parse FETCH_HEAD)"

# The fork layer: everything on main since it last met upstream.
# Do not replay these historical commits: that loses earlier conflict resolutions.
BASE="$(git merge-base "$OLD_MAIN" "$OLD_UPSTREAM")"
LAYER="$(git rev-list --count "$BASE..$OLD_MAIN")"

summary "### oklabs-sync" "" \
    "- upstream source: \`$SOURCE_URL $SOURCE_REF\`" \
    "- old upstream \`${OLD_UPSTREAM:0:10}\`, new upstream \`${NEW_UPSTREAM:0:10}\`" \
    "- main \`${OLD_MAIN:0:10}\`, fork layer: $LAYER commits on \`${BASE:0:10}\`" \
    "- dry run: $DRY_RUN"
echo "fork layer ($LAYER commits on ${BASE:0:10}):"
git log --oneline "$BASE..$OLD_MAIN"

if [[ "$LAYER" == 0 ]]; then
    fail "main has no OKLabs commits on top of upstream; refusing to sync"
fi

if [[ "$NEW_UPSTREAM" == "$OLD_UPSTREAM" ]] && git merge-base --is-ancestor "$NEW_UPSTREAM" "$OLD_MAIN"; then
    echo "upstream unchanged; nothing to do"
    summary "- result: **no-op**, upstream unchanged"
    exit 0
fi

if git merge-base --is-ancestor "$OLD_UPSTREAM" "$NEW_UPSTREAM"; then
    INCOMING="$(git rev-list --count "$OLD_UPSTREAM..$NEW_UPSTREAM")"
    echo "upstream moved forward by $INCOMING commits"
    summary "- upstream: +$INCOMING commits"
else
    fail "upstream history was rewritten; refusing to replace published history automatically"
fi

git checkout --quiet -B oklabs-sync "$OLD_MAIN"
if ! git merge --no-edit --no-ff -m "Merge upstream VoiceInk ${NEW_UPSTREAM:0:10}" "$NEW_UPSTREAM"; then
    SUBJECT="$(git log -1 --format=%s "$NEW_UPSTREAM")"
    CONFLICT_LIST="$(git diff --name-only --diff-filter=U || true)"
    CONFLICTS="$(printf '%s' "$CONFLICT_LIST" | tr '\n' ' ')"
    git merge --abort || true
    [[ -n "$CONFLICT_LIST" ]] || fail "merge failed without file conflicts; see the Git output"
    note result conflict; note upstream "$NEW_UPSTREAM"; note subject "$SUBJECT"
    while IFS= read -r f; do [[ -z "$f" ]] || note conflict "$f"; done <<< "$CONFLICT_LIST"
    echo "::error title=oklabs-sync: merge conflict::upstream ${NEW_UPSTREAM:0:10} \"$SUBJECT\" conflicts in: $CONFLICTS"
    summary "- result: **merge conflict**, nothing pushed" \
        "- incoming upstream commit \`${NEW_UPSTREAM:0:10}\` $SUBJECT" \
        "- conflicting files: \`$CONFLICTS\`" \
        "- fix: merge upstream/main into a branch from origin/main, resolve and open a PR; use a merge commit, not squash/rebase"
    exit 1
fi

NEW_MAIN="$(git rev-parse HEAD)"
NEW_LAYER="$(git rev-list --count "$NEW_UPSTREAM..$NEW_MAIN")"
echo "merged: main ${OLD_MAIN:0:10} -> ${NEW_MAIN:0:10} ($NEW_LAYER fork commits)"
git log --oneline "$NEW_UPSTREAM..$NEW_MAIN"
for required in .github/workflows/oklabs-release.yml .github/workflows/oklabs-sync.yml .oklabs/ci/sync.sh; do
    [[ -f "$required" ]] || fail "$required missing after merge; refusing to push"
done
summary "- merged main: \`${NEW_MAIN:0:10}\` ($NEW_LAYER fork commits)"

if [[ "$DRY_RUN" == "true" ]]; then
    summary "- result: **clean merge** (dry run, nothing pushed)"
    echo "dry run: not pushing"
    exit 0
fi

# Leases protect against concurrent changes; the ancestry checks forbid rewriting
# either branch even though Git's compare-and-swap option is named force-with-lease.
git merge-base --is-ancestor "$OLD_MAIN" "$NEW_MAIN" || fail "main would not fast-forward; refusing to push"
git merge-base --is-ancestor "$OLD_UPSTREAM" "$NEW_UPSTREAM" || fail "upstream would not fast-forward; refusing to push"
# OKLABS_SYNC_TOKEN credentials from checkout start oklabs-release on the new main.
if ! git push --atomic origin \
    --force-with-lease="upstream:$OLD_UPSTREAM" --force-with-lease="main:$OLD_MAIN" \
    "$NEW_UPSTREAM:refs/heads/upstream" "$NEW_MAIN:refs/heads/main"; then
    fail "push rejected (main or upstream moved during the sync, or the token lost access); nothing pushed"
fi
summary "- result: **pushed** upstream and main; oklabs-release builds the new main"
