#!/bin/bash
# OKLabs fork: Telegram messages from the oklabs-* workflows.
# A message never fails the calling job: problems become ::warning:: lines and the
# script exits 0. Only `test` exits 1 when its message was not delivered.
#
# Usage: notify.sh prev-tag | release-ok | sync-failed | autoresolve-pr | test
#   prev-tag     print the newest published release whose tag is on another commit than
#                $GITHUB_SHA (the release to compare with; a re-run never compares with
#                the release its own first attempt published).
#   release-ok   after a published release: version, what changed, the Mac update
#                command. On a push whose app code and build inputs are unchanged since
#                the previous release (CI, docs, tests or bench only) nothing is sent.
#   sync-failed  oklabs-sync failed or was cancelled: a merge conflict (read from
#                $SYNC_RESULT, which sync.sh writes) or any other failure, with the run URL.
#   autoresolve-pr  the auto-resolver on baldr pushed oklabs/auto-resolve/<sha10>: the PR
#                (opened by oklabs-autoresolve-pr.yml), conflicted files; merge is Oleg's.
#   test         the release-ok text for the current latest release, marked [TEST].
#                The only kind that exits 1 when the message was not delivered.
#
# Env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID (repo secrets; unset = warning, nothing sent),
#   GH_TOKEN (release notes and list), NOTIFY_DRY_RUN=1 prints the message instead.
#   release-ok: OKLABS_VERSION, OKLABS_TAG, UPSTREAM_SHA (Version step), PREV_TAG
#   (prev-tag), CHECK_OUTCOME (the download check after publish).
#   sync-failed: SYNC_RESULT, DRY_RUN, JOB_STATUS.
#   autoresolve-pr: PR_URL, PR_STATE (new|existing), UPSTREAM_SHA, UPSTREAM_SUBJECT,
#   CONFLICTED (space-separated paths).
# The token goes from the environment straight into the request URL. Nothing here
# prints it, and GitHub masks secrets in logs.
# Runs on the macOS (bash 3.2, BSD tools) and Ubuntu runners.
set -uo pipefail

KIND="${1:-}"
REPO="${GITHUB_REPOSITORY:-kossoy/VoiceInk}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
RUN_URL="$SERVER/$REPO/actions/runs/${GITHUB_RUN_ID:-0}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
UPDATE_CMD='bash ~/.local/bin/voiceink-oklabs-update'
LABEL="${NOTIFY_LABEL:-}"
# Paths that do not change the app. A release whose diff touches only these is not
# announced (the release itself is still published). oklabs-release.yml is excluded as a
# file, but its build inputs (BUILD_INPUTS) count as app changes.
NON_APP=(':(exclude).github' ':(exclude,glob)**/*.md' ':(exclude).oklabs/ci/sync.sh'
    ':(exclude).oklabs/ci/notify.sh' ':(exclude).oklabs/scribe-bench' ':(exclude)Tests'
    ':(exclude)Package.swift')
BUILD_INPUTS='^[+-][[:space:]]*(DEVELOPER_DIR|WHISPER_TAG|SIGN_IDENTITY|TEAM_ID):'

summary() { printf '%s\n' "$@" >>"$SUMMARY" 2>/dev/null || true; }
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
plain() { printf '%s' "$1" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'; }
cut_to() { # text max-chars
    local s=$1
    if [ "${#s}" -gt "$2" ]; then s="${s:0:$(($2 - 1))}…"; fi
    printf '%s' "$s"
}
subjects() { # max; lines on stdin -> "a; b; c; +N"
    local max=$1 out="" n=0 line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$((n + 1))
        if [ "$n" -le "$max" ]; then out="${out:+$out; }$(cut_to "$line" 70)"; fi
    done
    if [ "$n" -gt "$max" ]; then out="$out; +$((n - max))"; fi
    printf '%s' "$out"
}
tag_commit() { git rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true; }
build_inputs() { # prev new -> changed build-input lines of oklabs-release.yml, "K: v; ..."
    git diff "$1" "$2" -- .github/workflows/oklabs-release.yml 2>/dev/null | grep -E "$BUILD_INPUTS" |
        grep '^+' | sed -E 's/^\+[[:space:]]*//' | subjects 4
}
app_unchanged() { # prev new
    git diff --quiet "$1" "$2" -- . "${NON_APP[@]}" 2>/dev/null &&
        ! git diff "$1" "$2" -- .github/workflows/oklabs-release.yml 2>/dev/null | grep -Eq "$BUILD_INPUTS"
}
prev_tag() { # commit -> newest published release whose tag is on another commit
    local want t c
    want="$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null || printf '%s' "$1")"
    for t in $(gh release list --repo "$REPO" --limit 30 --json tagName,publishedAt,isDraft \
        -q '[.[] | select(.isDraft | not)] | sort_by(.publishedAt) | reverse | .[].tagName' 2>/dev/null); do
        c="$(tag_commit "$t")"
        if [ -n "$c" ] && [ "$c" != "$want" ]; then
            printf '%s' "$t"
            return 0
        fi
    done
}
prev_base() { # tag new-upstream-base -> upstream base of that release (its notes), else merge-base
    local b
    b="$(gh release view "$1" --repo "$REPO" --json body -q .body 2>/dev/null |
        sed -n 's/.*Upstream Beingpax\/VoiceInk base: \([0-9a-f]\{40\}\).*/\1/p' | head -1)"
    if [ -n "$b" ] && git cat-file -e "$b^{commit}" 2>/dev/null; then
        printf '%s' "$b"
    else
        git merge-base "$(tag_commit "$1")" "$2" 2>/dev/null || true
    fi
}

send() { # html text; returns 1 if not delivered
    local text=$1 clean resp code desc mode body pm
    # Telegram rejects invalid UTF-8 (a subject cut mid-character, say).
    clean="$(printf '%s' "$text" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)"
    if [ -n "$clean" ]; then text=$clean; fi
    if [ "${NOTIFY_DRY_RUN:-}" = 1 ]; then
        printf '%s\n%s\n' "--- Telegram message (dry run) ---" "$text"
        return 0
    fi
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        echo "::warning::TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is not set; Telegram message skipped"
        return 1
    fi
    resp="$(mktemp)"
    for mode in HTML plain; do
        pm=()
        body=$text
        if [ "$mode" = HTML ]; then pm=(--data-urlencode parse_mode=HTML); else body="$(plain "$text")"; fi
        code="$(curl -sS -m 20 --retry 3 --retry-delay 5 -o "$resp" -w '%{http_code}' \
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$body" \
            --data-urlencode disable_web_page_preview=true ${pm[@]+"${pm[@]}"} \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage")" || code=000
        if [ "$code" = 200 ]; then
            echo "Telegram: delivered ($mode, message_id $(jq -r '.result.message_id' "$resp" 2>/dev/null))"
            rm -f "$resp"
            return 0
        fi
        desc="$(jq -r '.description // empty' "$resp" 2>/dev/null | head -c 200)"
        echo "::warning::Telegram sendMessage ($mode) failed: HTTP $code $desc"
        # Only an HTML parse error is worth a second try as plain text.
        if [ "$mode" != HTML ] || [ "$code" != 400 ]; then break; fi
    done
    rm -f "$resp"
    return 1
}

changes() { # new-commit new-upstream-base prev-tag -> one plain-text line
    local new=$1 up=$2 prev=$3 prev_sha prev_up line="" n s old
    prev_sha="$(tag_commit "$prev")"
    if [ -z "$prev" ] || [ -z "$prev_sha" ]; then
        printf 'fork commit %s' "$(git log -1 --format='%h %s' "$new" 2>/dev/null || printf '%s' "${new:0:7}")"
        return
    fi
    if [ "$up" = unknown ] || [ -z "$up" ]; then up="$(git merge-base "$new" origin/upstream 2>/dev/null || true)"; fi
    if [ -z "$up" ]; then
        printf 'fork commit %s (upstream base unknown)' "$(git log -1 --format='%h %s' "$new" 2>/dev/null)"
        return
    fi
    prev_up="$(prev_base "$prev" "$up")"
    if [ -n "$prev_up" ] && [ "$prev_up" != "$up" ]; then
        if git merge-base --is-ancestor "$prev_up" "$up"; then
            n="$(git rev-list --no-merges --count "$prev_up..$up")"
            s="$(git log --no-merges --format=%s "$prev_up..$up" | subjects 3)"
            line="upstream +$n commits: $s"
        else
            line="upstream: история переписана (${prev_up:0:7} -> ${up:0:7})"
        fi
    fi
    # Fork commits touching the app that the previous release did not have. Compared by
    # subject, to remain compatible with older releases whose commits were rebased.
    old="$(mktemp)"
    if [ -n "$prev_up" ]; then git log --format=%s "$prev_up..$prev_sha" -- . "${NON_APP[@]}" >"$old" 2>/dev/null; fi
    s="$(git log --format=%s "$up..$new" -- . "${NON_APP[@]}" 2>/dev/null | grep -vxF -f "$old" | subjects 3)"
    rm -f "$old"
    if [ -n "$s" ]; then line="${line:+$line · }fork: $s"; fi
    s="$(build_inputs "$prev_sha" "$new")"
    if [ -n "$s" ]; then line="${line:+$line · }build: $s"; fi
    if [ -z "$line" ]; then
        if app_unchanged "$prev_sha" "$new"; then
            line="app code тот же, что в $prev"
        else
            line="fork: изменены уже существующие commits"
        fi
    fi
    printf '%s' "$line"
}

release_text() { # version tag new-commit upstream-base prev-tag
    local note=""
    if [ -n "$LABEL" ]; then note="Проверка канала Telegram, ничего делать не надо.
"; fi
    if [ -n "${CHECK_OUTCOME:-}" ] && [ "$CHECK_OUTCOME" != success ]; then
        note="${note}Release опубликован, но проверка releases/latest после него не прошла: $RUN_URL
"
    fi
    printf '%s' "<b>${LABEL:+[$LABEL] }Новая сборка VoiceInk $(esc "$1")</b>
${note}Что изменилось: $(esc "$(cut_to "$(changes "$3" "$4" "$5")" 600)")
Обновить на Mac:
<pre>$(esc "$UPDATE_CMD")</pre>
<a href=\"$SERVER/$REPO/releases/tag/$(esc "$2")\">release $(esc "$2")</a>"
}

release_ok() {
    local new="${GITHUB_SHA:-HEAD}" prev="${PREV_TAG:-}" prev_sha
    prev_sha="$(tag_commit "$prev")"
    if [ "${GITHUB_EVENT_NAME:-}" = push ] && [ -n "$prev_sha" ] && app_unchanged "$prev_sha" "$new"; then
        echo "app code and build inputs unchanged since $prev (only CI, docs, tests or bench): no Telegram message"
        summary "- Telegram: not sent, app code unchanged since \`$prev\`"
        return 0
    fi
    if send "$(release_text "${OKLABS_VERSION:-?}" "${OKLABS_TAG:-?}" "$new" "${UPSTREAM_SHA:-unknown}" "$prev")"; then
        summary "- Telegram: new-build message sent"
    else
        summary "- Telegram: message not delivered (see the step's warnings)"
    fi
}

sync_failed() {
    local f="${SYNC_RESULT:-}" k v result="" upstream="" subject="" error="" files="" n=0 dry="" text
    if [ -n "$f" ] && [ -f "$f" ]; then
        while IFS='=' read -r k v; do
            case $k in
                result) result=$v ;;
                upstream) upstream=$v ;;
                subject) subject=$v ;;
                error) error=$v ;;
                conflict)
                    n=$((n + 1))
                    if [ "$n" -le 10 ]; then files="${files:+$files, }<code>$(esc "$v")</code>"; fi
                    ;;
            esac
        done <"$f"
    fi
    if [ "$n" -gt 10 ]; then files="$files, +$((n - 10))"; fi
    if [ "${DRY_RUN:-false}" = true ]; then dry=" (dry run)"; fi
    if [ -z "$result" ] && [ "${JOB_STATUS:-}" = cancelled ]; then
        error="job cancelled: timeout 15 min (зависли fetch или push?) или отмена вручную"
    fi
    if [ "$result" = conflict ]; then
        text="<b>${LABEL:+[$LABEL] }VoiceInk sync$dry: конфликт с upstream</b>
Merge Beingpax main <code>$(esc "${upstream:0:10}")</code> $(esc "$(cut_to "$subject" 90)") требует разрешения конфликта.
Файлы: ${files:-не определены, см. run}
Ничего не pushed, latest release прежний.
Auto-resolver на baldr (voiceink-oklabs-autoresolve, 02:30 UTC и каждые 6 h) попробует разрешить сам и откроет PR; придёт отдельное сообщение. Если он не справится, тоже придёт сообщение.
Fix вручную (.oklabs/README.md, раздел Sync):
<pre>git fetch origin &amp;&amp; git fetch upstream
git switch -c fix/upstream-sync origin/main
git merge upstream/main</pre>
После разрешения конфликта — PR с merge commit (без squash/rebase).
Run: <a href=\"$RUN_URL\">$RUN_URL</a>"
    else
        text="<b>${LABEL:+[$LABEL] }VoiceInk sync$dry упал</b>
${error:+$(esc "$(cut_to "$error" 300)")
}Run: <a href=\"$RUN_URL\">$RUN_URL</a>"
    fi
    send "$text" || true
}

autoresolve_pr() {
    local files="" n=0 f
    for f in ${CONFLICTED:-}; do
        n=$((n + 1))
        if [ "$n" -le 10 ]; then files="${files:+$files, }<code>$(esc "$f")</code>"; fi
    done
    if [ "$n" -gt 10 ]; then files="$files, +$((n - 10))"; fi
    send "<b>${LABEL:+[$LABEL] }VoiceInk sync: конфликт разрешён агентом</b>
Merge Beingpax main <code>$(esc "${UPSTREAM_SHA:0:10}")</code> $(esc "$(cut_to "${UPSTREAM_SUBJECT:-}" 90)").
Файлы: ${files:-см. PR}
PR${PR_STATE:+ ($(esc "$PR_STATE"))}: <a href=\"$(esc "${PR_URL:-}")\">$(esc "${PR_URL:-}")</a>
Checks (oklabs-test: swift test, compile app) идут на этом PR. Merge вручную после review resolution в PR, merge commit (без squash/rebase). После merge release соберётся сам." || true
}

test_msg() {
    local tag prev ver new up
    LABEL="${LABEL:-TEST}"
    git fetch --quiet --force --tags origin 2>/dev/null || true
    git fetch --quiet origin '+refs/heads/upstream:refs/remotes/origin/upstream' 2>/dev/null || true
    tag="$(gh release view --repo "$REPO" --json tagName -q .tagName)"
    ver="$(gh release view "$tag" --repo "$REPO" --json name -q .name | sed 's/^VoiceInk OKLabs //')"
    new="$(tag_commit "$tag")"
    [ -n "$tag" ] && [ -n "$new" ] || { echo "::error::cannot resolve the latest release"; return 1; }
    prev="$(prev_tag "$new")"
    up="$(git merge-base "$new" origin/upstream 2>/dev/null || echo unknown)"
    echo "test: latest release $tag ($ver, ${new:0:10}), previous $prev"
    send "$(release_text "$ver" "$tag" "$new" "$up" "$prev")"
}

case $KIND in
    prev-tag) prev_tag "${GITHUB_SHA:-HEAD}" ;;
    release-ok) release_ok ;;
    sync-failed) sync_failed ;;
    autoresolve-pr) autoresolve_pr ;;
    test) test_msg || exit 1 ;;
    *) echo "usage: notify.sh prev-tag | release-ok | sync-failed | autoresolve-pr | test" >&2; exit 64 ;;
esac
exit 0
