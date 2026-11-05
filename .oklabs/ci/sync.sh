#!/bin/bash
# Nightly fork sync: merge Beingpax/VoiceInk main into the existing fork history,
# prepare a candidate, then promote that exact checked commit with exact leases.
# A merge conflict aborts the merge and fails the run (nothing pushed).
#
# Env:
#   SYNC_PHASE    prepare (default): push only oklabs/upstream-sync; promote: atomically
#                 advance main/upstream to the externally validated candidate
#   UPSTREAM_URL  upstream repository (default https://github.com/Beingpax/VoiceInk.git)
#   UPSTREAM_REF  optional override "owner/repo:ref" for dry-run tests only
#   DRY_RUN       "true" = merge and report, push nothing
#   SYNC_RESULT   optional file: key=value lines for notify.sh (result, error, upstream,
#                 subject, one conflict= line per file)
#   GITHUB_OUTPUT prepare outputs: main, old_upstream, new_upstream, candidate, changed
#   SYNC_CONTRACT_GUARD optional path to a trusted fork-contract script; the workflow
#                 supplies a pre-merge copy and runs it before any candidate push
#   SYNC_EXPECTED_MAIN, SYNC_EXPECTED_UPSTREAM, SYNC_NEW_UPSTREAM, SYNC_CANDIDATE:
#                 exact SHA inputs required for promotion; caller must validate first
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/Beingpax/VoiceInk.git}"
UPSTREAM_REF="${UPSTREAM_REF:-}"
DRY_RUN="${DRY_RUN:-false}"
PHASE="${SYNC_PHASE:-prepare}"
CANDIDATE_BRANCH=oklabs/upstream-sync
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

summary() { printf '%s\n' "$@" >> "$SUMMARY"; }
output() { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi; }

RESULT="${SYNC_RESULT:-}"
note() { if [[ -n "$RESULT" ]]; then printf '%s=%s\n' "$1" "$2" >> "$RESULT"; fi; }
fail() { note result error; note error "$1"; echo "::error::$1"; exit 1; }
if [[ -n "$RESULT" ]]; then : > "$RESULT"; fi
# Any other failing command: record it for the Telegram message, then set -e exits.
trap 'note result error; note error "line $LINENO: $BASH_COMMAND failed"' ERR

git config user.name "Oleg Kossoy"
git config user.email "51094+kossoy@users.noreply.github.com"

if [[ "$PHASE" == promote ]]; then
    [[ "$DRY_RUN" != true ]] || fail 'promotion cannot run in dry-run mode'
    for name in SYNC_EXPECTED_MAIN SYNC_EXPECTED_UPSTREAM SYNC_NEW_UPSTREAM SYNC_CANDIDATE; do
        [[ "${!name:-}" =~ ^[0-9a-f]{40}$ ]] || fail "$name must be an exact commit SHA"
    done
    git fetch --quiet --no-tags origin main upstream "$CANDIDATE_BRANCH"
    [[ "$(git rev-parse origin/main)" == "$SYNC_EXPECTED_MAIN" ]] || fail 'main moved after validation; prepare a new candidate'
    [[ "$(git rev-parse origin/upstream)" == "$SYNC_EXPECTED_UPSTREAM" ]] || fail 'upstream mirror moved after validation'
    [[ "$(git rev-parse "origin/$CANDIDATE_BRANCH")" == "$SYNC_CANDIDATE" ]] || fail 'candidate changed after validation'
    git merge-base --is-ancestor "$SYNC_EXPECTED_MAIN" "$SYNC_CANDIDATE" || fail 'candidate would rewrite main'
    git merge-base --is-ancestor "$SYNC_EXPECTED_UPSTREAM" "$SYNC_NEW_UPSTREAM" || fail 'upstream would rewrite history'
    git merge-base --is-ancestor "$SYNC_NEW_UPSTREAM" "$SYNC_CANDIDATE" || fail 'candidate does not contain checked upstream'
    if ! git push --atomic origin \
        --force-with-lease="upstream:$SYNC_EXPECTED_UPSTREAM" --force-with-lease="main:$SYNC_EXPECTED_MAIN" \
        "$SYNC_NEW_UPSTREAM:refs/heads/upstream" "$SYNC_CANDIDATE:refs/heads/main"; then
        fail 'push rejected (main or upstream moved during promotion); nothing pushed'
    fi
    note result pushed
    summary "### oklabs-sync promotion" "- checked candidate: \`$SYNC_CANDIDATE\`" \
        '- result: **pushed** upstream and main after successful validation'
    exit 0
fi
[[ "$PHASE" == prepare ]] || fail 'SYNC_PHASE must be prepare or promote'

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
output main "$OLD_MAIN"
output old_upstream "$OLD_UPSTREAM"
output changed false
git fetch --quiet --no-tags "$SOURCE_URL" "$SOURCE_REF"
NEW_UPSTREAM="$(git rev-parse FETCH_HEAD)"
output new_upstream "$NEW_UPSTREAM"

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
output candidate "$NEW_MAIN"
output changed true
NEW_LAYER="$(git rev-list --count "$NEW_UPSTREAM..$NEW_MAIN")"
echo "merged: main ${OLD_MAIN:0:10} -> ${NEW_MAIN:0:10} ($NEW_LAYER fork commits)"
git log --oneline "$NEW_UPSTREAM..$NEW_MAIN"
for required in .github/workflows/oklabs-release.yml .github/workflows/oklabs-sync.yml .oklabs/ci/sync.sh; do
    [[ -f "$required" ]] || fail "$required missing after merge; refusing to push"
done
summary "- merged main: \`${NEW_MAIN:0:10}\` ($NEW_LAYER fork commits)"

if [[ -n "${SYNC_CONTRACT_GUARD:-}" ]]; then
    python3 "$SYNC_CONTRACT_GUARD" --base "$OLD_MAIN" --candidate "$NEW_MAIN"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    summary "- result: **clean merge** (dry run, nothing pushed)"
    echo "dry run: not pushing"
    exit 0
fi

# Prepare never changes main or the upstream mirror. The workflow validates this
# exact SHA before a separate promotion job receives write credentials.
git merge-base --is-ancestor "$OLD_MAIN" "$NEW_MAIN" || fail "main would not fast-forward; refusing to push"
git merge-base --is-ancestor "$OLD_UPSTREAM" "$NEW_UPSTREAM" || fail "upstream would not fast-forward; refusing to push"
REMOTE_CANDIDATE="$(git ls-remote --heads origin "refs/heads/$CANDIDATE_BRANCH")"
REMOTE_CANDIDATE="${REMOTE_CANDIDATE%%$'\t'*}"
if ! git push origin --force-with-lease="refs/heads/$CANDIDATE_BRANCH:$REMOTE_CANDIDATE" \
    "$NEW_MAIN:refs/heads/$CANDIDATE_BRANCH"; then
    fail 'candidate push rejected; main and upstream were not changed'
fi
note result prepared
summary "- result: **candidate prepared**, main and upstream unchanged" \
    "- candidate branch: \`$CANDIDATE_BRANCH\`, commit \`$NEW_MAIN\`"
