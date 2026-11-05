#!/bin/bash
# Integration tests against local Git remotes; no GitHub credentials or network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SYNC="$ROOT/.oklabs/ci/sync.sh"
NOTIFY="$ROOT/.oklabs/ci/notify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME='Sync test' GIT_AUTHOR_EMAIL='sync@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected $2, got $1"; }
commit() { git -C "$1" add .; git -C "$1" commit -qm "$2"; }
write_project() {
    cat > "$1/project.pbxproj" <<'PBX'
ARCHS = "$(ARCHS_STANDARD)";
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
CODE_SIGN_STYLE = Automatic;
COMBINE_HIDPI_IMAGES = YES;
CURRENT_PROJECT_VERSION = 224;
DEAD_CODE_STRIPPING = YES;
ENABLE_HARDENED_RUNTIME = YES;
GENERATE_INFOPLIST_FILE = YES;
MACOSX_DEPLOYMENT_TARGET = 15.0;
MARKETING_VERSION = 2.22;
PRODUCT_BUNDLE_IDENTIFIER = com.prakashjoshipax.VoiceInk;
PRODUCT_NAME = VoiceInk;
PBX
}
replace_version() {
    sed "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $2;/" "$1/project.pbxproj" > "$1/project.tmp"
    mv "$1/project.tmp" "$1/project.pbxproj"
    commit "$1" "Release $2"
}
fixture() {
    CASE="$TMP/$1"
    mkdir -p "$CASE"
    SOURCE="$CASE/source"; ORIGIN="$CASE/origin.git"; WORK="$CASE/work"
    git init -q -b main "$SOURCE"
    write_project "$SOURCE"
    commit "$SOURCE" 'Initial upstream'
    OLD_UPSTREAM="$(git -C "$SOURCE" rev-parse HEAD)"
    git clone -q --bare "$SOURCE" "$ORIGIN"
    git --git-dir="$ORIGIN" update-ref refs/heads/upstream "$OLD_UPSTREAM"
    git clone -q "$ORIGIN" "$WORK"
    mkdir -p "$WORK/.github/workflows" "$WORK/.oklabs/ci"
    touch "$WORK/.github/workflows/oklabs-release.yml" "$WORK/.github/workflows/oklabs-sync.yml" "$WORK/.oklabs/ci/sync.sh"
    # Historical fork commit inserts a setting next to the upstream version.
    sed '/MARKETING_VERSION/a\
OKLABS_PRODUCT_ARCHS = "$(ARCHS_STANDARD)";
' "$WORK/project.pbxproj" > "$WORK/project.tmp"
    mv "$WORK/project.tmp" "$WORK/project.pbxproj"
    commit "$WORK" 'Old architecture override next to the version'
    # Fix the current tree, preserving that historical commit. A rebase would
    # still replay the old insertion and conflict on the next upstream version.
    sed '/^OKLABS_PRODUCT_ARCHS/d; s/^ARCHS = .*/ARCHS = "$(OKLABS_PRODUCT_ARCHS)";/' "$WORK/project.pbxproj" > "$WORK/project.tmp"
    { printf 'OKLABS_PRODUCT_ARCHS = "$(ARCHS_STANDARD)";\n'; cat "$WORK/project.tmp"; } > "$WORK/project.pbxproj"
    rm "$WORK/project.tmp"
    commit "$WORK" 'Keep product architecture defaults away from version metadata'
    git -C "$WORK" push -q origin main
    OLD_MAIN="$(git -C "$WORK" rev-parse HEAD)"
    replace_version "$SOURCE" 2.25
    NEW_UPSTREAM="$(git -C "$SOURCE" rev-parse HEAD)"
}
prepare_run() {
    (cd "$WORK" && UPSTREAM_URL="$SOURCE" DRY_RUN="${1:-false}" \
        SYNC_PHASE=prepare GITHUB_OUTPUT="$CASE/outputs" \
        GITHUB_STEP_SUMMARY="$CASE/summary" SYNC_RESULT="$CASE/result" bash "$SYNC") > "$CASE/output" 2>&1
}
output_value() { sed -n "s/^$1=//p" "$CASE/outputs" | tail -1; }
promote_run() {
    (cd "$WORK" && SYNC_PHASE=promote \
        SYNC_EXPECTED_MAIN="$(output_value main)" SYNC_EXPECTED_UPSTREAM="$(output_value old_upstream)" \
        SYNC_NEW_UPSTREAM="$(output_value new_upstream)" SYNC_CANDIDATE="$(output_value candidate)" \
        GITHUB_STEP_SUMMARY="$CASE/summary" SYNC_RESULT="$CASE/result" bash "$SYNC") >> "$CASE/output" 2>&1
}
sync_run() {
    : > "$CASE/outputs"
    prepare_run "${1:-false}" || return 1
    [[ "${1:-false}" == true || "$(output_value changed)" != true ]] || promote_run
}
refs_unchanged() {
    assert_equal "$(git --git-dir="$ORIGIN" rev-parse main)" "$OLD_MAIN" 'origin/main'
    assert_equal "$(git --git-dir="$ORIGIN" rev-parse upstream)" "$OLD_UPSTREAM" 'origin/upstream'
}

fixture version-bump
git -C "$WORK" fetch -q "$SOURCE" main
if git -C "$WORK" rebase --onto "$NEW_UPSTREAM" "$OLD_UPSTREAM" main > "$CASE/old-rebase" 2>&1; then
    fail 'regression fixture must reproduce the historical rebase conflict'
fi
git -C "$WORK" rebase --abort
sync_run || { cat "$CASE/output"; fail 'version bump must merge without replaying old insertion'; }
git -C "$WORK" merge-base --is-ancestor "$OLD_MAIN" HEAD || fail 'published fork history lost'
git -C "$WORK" merge-base --is-ancestor "$NEW_UPSTREAM" HEAD || fail 'new upstream history missing'
grep -q '^MARKETING_VERSION = 2.25;' "$WORK/project.pbxproj" || fail 'upstream version lost'
grep -q '^ARCHS = "$(OKLABS_PRODUCT_ARCHS)";' "$WORK/project.pbxproj" || fail 'fork architecture lost'
assert_equal "$(git --git-dir="$ORIGIN" rev-parse upstream)" "$NEW_UPSTREAM" 'published upstream'
merged="$(git --git-dir="$ORIGIN" rev-parse main)"
sync_run || fail 'unchanged upstream must succeed'
assert_equal "$(git --git-dir="$ORIGIN" rev-parse main)" "$merged" 'no-op main'
grep -q 'no-op' "$CASE/summary" || fail 'no-op not reported'
replace_version "$SOURCE" 2.26
sync_run || fail 'second version bump must preserve the previous merge'
git -C "$WORK" merge-base --is-ancestor "$merged" HEAD || fail 'previous merge resolution lost'
grep -q '^MARKETING_VERSION = 2.26;' "$WORK/project.pbxproj" || fail 'second version lost'
echo 'PASS: repeated version bumps, fork settings, published ancestry and no-op'

fixture dry-run
sync_run true || fail 'clean dry run failed'
refs_unchanged
if git --git-dir="$ORIGIN" show-ref --verify --quiet refs/heads/oklabs/upstream-sync; then
    fail 'dry run pushed a candidate'
fi
grep -q 'clean merge.*dry run' "$CASE/summary" || fail 'dry run not reported'
echo 'PASS: dry run changes no remote refs'

fixture conflict
sed 's/^ARCHS = .*/ARCHS = arm64;/' "$SOURCE/project.pbxproj" > "$SOURCE/project.tmp"
mv "$SOURCE/project.tmp" "$SOURCE/project.pbxproj"
commit "$SOURCE" 'Conflicting upstream architecture change'
if sync_run; then fail 'real conflict was accepted'; fi
refs_unchanged
[[ ! -f "$WORK/.git/MERGE_HEAD" ]] || fail 'failed merge was not aborted'
assert_equal "$(git -C "$WORK" status --porcelain)" '' 'working tree after conflict'
grep -q '^result=conflict$' "$CASE/result" || fail 'conflict result missing'
grep -q '^conflict=project.pbxproj$' "$CASE/result" || fail 'conflict file missing'
NOTIFY_DRY_RUN=1 SYNC_RESULT="$CASE/result" bash "$NOTIFY" sync-failed > "$CASE/notification"
grep -q 'git merge upstream/main' "$CASE/notification" || fail 'notification missing merge recovery'
if grep -q 'git rebase\|force-with-lease' "$CASE/notification"; then fail 'notification suggests rewriting history'; fi
echo 'PASS: real conflicts abort, preserve both refs and report merge recovery'

fixture rewritten-upstream
git -C "$SOURCE" checkout -q --orphan replacement
commit "$SOURCE" 'Rewritten upstream history'
git -C "$SOURCE" branch -M main
if sync_run; then fail 'rewritten upstream was accepted'; fi
refs_unchanged
grep -q 'history was rewritten' "$CASE/result" || fail 'upstream rewrite not reported'
echo 'PASS: rewritten upstream is rejected without pushing'

fixture race
race_commit="$(printf 'Concurrent fork change\n' | git --git-dir="$ORIGIN" commit-tree "$OLD_MAIN^{tree}" -p "$OLD_MAIN")"
git -C "$WORK" config test.origin "$ORIGIN"
git -C "$WORK" config test.race "$race_commit"
cat > "$WORK/.git/hooks/pre-push" <<'HOOK'
#!/bin/bash
while read -r local_ref local_sha remote_ref remote_sha; do
    if [[ "$remote_ref" == refs/heads/main ]]; then
        git --git-dir="$(git config test.origin)" update-ref refs/heads/main "$(git config test.race)"
    fi
done
HOOK
chmod +x "$WORK/.git/hooks/pre-push"
if sync_run; then fail 'concurrent main update was overwritten'; fi
assert_equal "$(git --git-dir="$ORIGIN" rev-parse main)" "$race_commit" 'concurrent main'
assert_equal "$(git --git-dir="$ORIGIN" rev-parse upstream)" "$OLD_UPSTREAM" 'atomic upstream after rejected push'
grep -q 'push rejected' "$CASE/result" || fail 'race rejection not reported'
echo 'PASS: a concurrent main update rejects the atomic push of both refs'

fixture prepare-only
prepare_run || { cat "$CASE/output"; fail 'candidate preparation failed'; }
refs_unchanged
assert_equal "$(git --git-dir="$ORIGIN" rev-parse refs/heads/oklabs/upstream-sync)" "$(output_value candidate)" 'candidate SHA'
assert_equal "$(output_value changed)" true 'candidate requires validation'
# A failing build/contract check must simply never call promote.
refs_unchanged
echo 'PASS: preparation and failing validation cannot change main or the upstream mirror'

fixture rejected-contract
cp "$ROOT/.oklabs/ci/check-fork-contracts.py" "$CASE/check-fork-contracts.py"
cat > "$CASE/fork-contracts.json" <<'JSON'
{"protected_paths": ["project.pbxproj"], "required_snippets": {}}
JSON
if SYNC_CONTRACT_GUARD="$CASE/check-fork-contracts.py" prepare_run; then
    fail 'prepare ignored a rejected fork contract'
fi
refs_unchanged
if git --git-dir="$ORIGIN" show-ref --verify --quiet refs/heads/oklabs/upstream-sync; then
    fail 'rejected contract was pushed as a candidate'
fi
grep -q 'upstream changed fork-owned path: project.pbxproj' "$CASE/output" || fail 'contract error missing'
echo 'PASS: trusted contract failure prevents even the candidate push'

fixture stale-main
prepare_run || fail 'prepare failed'
race_commit="$(printf 'New main after checks\n' | git --git-dir="$ORIGIN" commit-tree "$OLD_MAIN^{tree}" -p "$OLD_MAIN")"
git --git-dir="$ORIGIN" update-ref refs/heads/main "$race_commit"
if promote_run; then fail 'promotion accepted a main that moved after checks'; fi
assert_equal "$(git --git-dir="$ORIGIN" rev-parse main)" "$race_commit" 'new main preserved'
assert_equal "$(git --git-dir="$ORIGIN" rev-parse upstream)" "$OLD_UPSTREAM" 'mirror preserved'
grep -q 'main moved after validation' "$CASE/result" || fail 'stale validation was not reported'
echo 'PASS: main advancing after checks invalidates the candidate'

fixture stale-candidate
prepare_run || fail 'prepare failed'
git --git-dir="$ORIGIN" update-ref refs/heads/oklabs/upstream-sync "$OLD_MAIN"
if promote_run; then fail 'promotion accepted an unchecked replacement candidate'; fi
refs_unchanged
grep -q 'candidate changed after validation' "$CASE/result" || fail 'changed candidate was not reported'
echo 'PASS: only the exact checked candidate can be promoted'

fixture missing-validation-inputs
if (cd "$WORK" && SYNC_PHASE=promote SYNC_RESULT="$CASE/result" bash "$SYNC") > "$CASE/output" 2>&1; then
    fail 'promotion accepted missing validation inputs'
fi
refs_unchanged
echo 'PASS: promotion requires exact commit identities from validation'
