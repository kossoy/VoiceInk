# VoiceInk OKLabs fork

`kossoy/VoiceInk` is [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) plus a small fork
layer: an ElevenLabs Scribe v2 Realtime engine ported from voxtype, verbatim-output defaults, a
managed mode, Developer ID builds on GitHub Actions, and no Sparkle.

## Map

| Path | What |
|---|---|
| `VoiceInk/OKLabs/ScribeCore/` | Scribe engine, Foundation only: framing, segmenter, commit ledger, keyterms, URL/wire format, `ScribeLiveSession` |
| `VoiceInk/OKLabs/*.swift` | app side: `ScribeRealtimeProvider`, `ManagedSettings`, `FailureNotice`, `OKLabsSettings`, keyterms file |
| `#if OKLABS` hooks in upstream files | `UpdaterViewModel`, `VoiceInk.swift`, `ElevenLabsProvider`, `CustomVocabularyService`, `StreamingTranscriptionService`, `TranscriptionSession`, `TranscriptionPipeline`, `TranscriptionOutputFilter`, `CursorPaster`, `AudioFileTranscriptionService`, `AudioFileTranscriptionManager` |
| `Package.swift`, `Tests/ScribeCoreTests`, `Tests/ScribeBenchKitTests`, `Tests/OKLabsVocabularyTests`, `Tests/OKLabsUpdaterTests` | `swift test`: unit tests, mock WebSocket scenarios, and production vocabulary/updater fork regressions |
| `.oklabs/scribe-bench/` | `scribe-bench`, the real-voice harness (aggregate numbers only) |
| `.oklabs/ci/` | keychain, archive, notarize, package, bench, sync and Telegram notify scripts |
| `.github/workflows/oklabs-*.yml` | `oklabs-test`, `oklabs-release`, `oklabs-sync`, `oklabs-autoresolve-pr`, `oklabs-verify-release` |

Branches: `upstream` mirrors Beingpax `main`; `main` preserves OKLabs history and merges upstream updates.

## Flows

Meeting mode captures other apps through ScreenCaptureKit and the microphone through
AVAudioEngine voice processing. The microphone path requests acoustic echo cancellation;
it does not silently fall back to raw capture if initialization fails. Minimum ducking
reduces the effect on other apps' playback volume, but does not guarantee unchanged volume.
A microphone route/format change stops the recording with a visible error instead of
continuing with only system audio. Start a new recording after selecting the desired route.
Saved audio and transcript history are unchanged.

Speaker separation: after Stop, once every chunk is transcribed, the system-audio track
("Others") is diarized on this Mac with FluidAudio's offline pipeline (pyannote segmentation,
WeSpeaker embeddings, VBx clustering; `MeetingRuntime/MeetingDiarizer.swift`). The saved
system chunks are stitched with 0.5 s silences and the turns mapped back to the session clock
(`diarization.json` beside `session.json`; cluster IDs and times only, no voice embeddings).
Each line takes the voice that covers most of it and shows "Speaker N" until named. Clicking
a speaker renames that voice everywhere or names only that line; names live in `session.json`
(schema 2) and survive "Detect Speakers Again". Precedence, strongest first: the user's name
for the line, the user's name for the voice, complete meeting-app cues for the line, the
voice's cue majority (`MeetingSpeakerNaming`, fed by the Teams Accessibility observer below),
Speaker N, Others. The microphone is always Me. Models download once from Hugging Face into
FluidAudio's model cache; nothing else leaves the Mac. Older meetings: open one and use
Detect Speakers. Measure on a saved meeting without the app: `.oklabs/diarization-bench`. Off switch:
`defaults write com.prakashjoshipax.VoiceInk OKLabsMeetingSpeakerDiarization -bool NO`.

Teams speaker names (`MeetingSystem/TeamsSpeakerObserver.swift`, on by default): while a meeting
records, VoiceInk reads Teams desktop's Accessibility tree at 4 Hz, read-only. The purple border
of the active speaker's tile (main call window in front) or the compact view's "<Name> is
speaking" label become speaker cues on the session clock, and the voice clusters take the
majority name. Measured on live calls: 97% of the call named with the main window in front,
compact view alone 2%. The user's own tile is ignored. Details and captures:
`.oklabs/meeting-probe/LIVE-CALL.md`. Off switch:
`defaults write com.prakashjoshipax.VoiceInk oklabs.meeting.teamsSpeakerObserver -bool NO`.
It needs the FluidAudio `Diarizer` package trait in `project.pbxproj` (fork contract):
with `traits = ( )` Xcode 26+ compiles FluidAudio without its diarizer.

After a capture change, measure echo reduction using speech played by another app through
the real speaker route, then check local-only speech, double talk, headphones, pause/resume,
and stop. Confirm the system track remains present and local words survive overlap.
Unit tests or `isVoiceProcessingEnabled` alone do not prove a working playback reference.

For a local build with the normal app identity and existing settings, run
`bash .oklabs/build-local.sh`. It selects a single Developer ID Application
certificate (or Apple Development as a fallback), uses Release with LOCAL_BUILD
and OKLABS, strips the upstream Sparkle feed from the built bundle, verifies the
signature and prints the app path. It never installs, launches or publishes.
No ad-hoc fallback is used: stable signing avoids changing the app's identity on
every rebuild. Override the certificate with `OKLABS_LOCAL_SIGNING_IDENTITY` or
the output/DerivedData paths with `OKLABS_LOCAL_OUTPUT_DIR` and
`OKLABS_LOCAL_DERIVED_DATA`. The local entitlements keep iCloud disabled; the
existing fork preferences, model directory and LOCAL_BUILD Keychain service are
preserved. macOS may request permission once when switching from an ad-hoc build.

- **Test** (`oklabs-test.yml`, every push except `main`, `upstream` and the sync candidate): local-Git sync
  and fork-contract regression scenarios on Linux, `swift test`
  and an unsigned arm64 app compile with `LOCAL_BUILD OKLABS` on standard `macos-26-intel` runners.
- **Release** (`oklabs-release.yml`, push to `main` or manual; a push that touches only docs,
  `oklabs-sync.yml`, `sync.sh` or `notify.sh` does not release): runs the tests, then on a
  standard GitHub-hosted `macos-26-intel` runner builds whisper.cpp (pinned tag, macOS slice), archives with
  `LOCAL_BUILD OKLABS` and the local entitlements, exports with Developer ID, checks every nested
  signature, notarizes and staples the app and the DMG, signs and notarizes `scribe-bench`, and
  publishes `oklabs-<upstream version>-<run>` as the latest release with `VoiceInk-oklabs.zip`,
  `VoiceInk-oklabs.dmg`, `scribe-bench-macos-arm64.zip` and `SHA256SUMS`. Version:
  `<upstream>+oklabs.<UTC yyyymmddHHMM>.<sha7>`, build `<upstream build>.<run>`.
  `OKLABS_PRODUCT_ARCHS=arm64` scopes the architecture override to the app and RefineXPC
  Release targets. Swift package dependencies retain their normal architectures, and build-time
  macros run natively on the host. App and XPC binaries must each contain only arm64.
  Keep the custom architecture default next to `ARCHS`, away from upstream version metadata.
  Intel runners smoke-test a separate native `scribe-bench --help` executable; the published
  harness remains arm64.
  Keep the input file before the variadic architecture list: `lipo "$binary" -verify_arch arm64`.
  Release version metadata is read from the unique app Release configuration, independently of
  project-file key order.
- **Sync** (`oklabs-sync.yml`, nightly 01:17 UTC or manual): fetches Beingpax `main`; if it moved,
  merges it with existing fork history and pushes **only `oklabs/upstream-sync`**. Before touching
  `main` or the `upstream` mirror, it checks fork contracts, runs the regression and Swift tests,
  and compiles the actual app. Only the exact tested candidate SHA can then advance `upstream`
  and `main` atomically. Exact `--force-with-lease` expectations reject concurrent changes,
  while explicit ancestry checks prohibit history rewrites. If `main` moves while checks run,
  promotion fails and the next run must prepare a fresh candidate.

  The guard script and manifest come from the pre-merge fork `main`, so incoming code cannot
  remove its own checks. It rejects changes to `VoiceInk/OKLabs/`, `.oklabs/`, fork workflows,
  `Package.swift` and `Tests/`, and checks the app hooks for Meeting mode, the ElevenLabs engine,
  vocabulary, verbatim output and the disabled upstream updater. Structural checks complement
  compiled tests; they do not prove runtime compatibility. Real Teams capture, speaker labels
  and macOS permissions still need a meeting smoke test after meaningful app changes.

  The guard also runs from a trusted pre-merge copy before the candidate push, rejecting all
  workflow additions or edits before they can run. Preparation and promotion use the existing
  `OKLABS_SYNC_TOKEN` (with the `workflow` scope); its `main` push starts a release.
  Candidate tests and app compile receive no signing or promotion secrets.
  Unchanged upstream = no-op. Rewritten upstream
  history is rejected for manual review. **A merge conflict aborts, pushes nothing and fails
  the run**. Failed contracts, tests or build leave `main` and the mirror untouched; the rejected
  candidate, if already pushed, remains available for investigation. The run summary and Telegram report failures;
  the last good release stays `latest`. Manual runs take `dry_run` (merge preview without
  pushing or running candidate validation) and a test-only `upstream_ref` (`owner/repo:ref`).

  **Auto-resolve.** A conflict is first tried by `voiceink-oklabs-autoresolve` on baldr (user
  timer 02:30, 08:30, 14:30, 20:30 UTC; GitHub-hosted runners cannot reach the LAN model proxy).
  It merges Beingpax `main` into `origin/main` in a scratch worktree, lets Claude Code
  (`~/.local/bin/oklabs-agent`, CLIProxyAPI on maestro) resolve the conflicted files and then
  review the result in a second pass, and enforces guards the agent cannot change: the final
  tree may differ from `git merge-tree --write-tree` only in the conflicted paths, no conflict
  markers, then `check-fork-contracts.py` with its manifest from the old `main`, `tests/sync.sh`
  and the fork guard unittests. It pushes one merge commit to `oklabs/auto-resolve/<upstream sha10>`
  as the GitHub App `kossoy-voiceink-autoresolve` (installed on this repo only, contents
  write; 1 h installation token per push via `GIT_ASKPASS`). That push starts
  `oklabs-test` (swift test, app compile), and `oklabs-autoresolve-pr.yml` opens the PR to `main`
  with the agent's explanation and sends Telegram. **Nothing merges automatically**: review the
  resolution and merge with a merge commit. One attempt per upstream commit and **one pending
  PR at a time**: while any `oklabs/auto-resolve/*` branch exists, runs exit quietly. Merging
  deletes the branch (`delete_branch_on_merge`); **close the PR without merging to let the next
  attempt run** (the workflow deletes the closed PR's branch). A clean merge or an upstream
  already in `main` is a quiet exit too.

  The agent runs in `oklabs-agent`'s bubblewrap sandbox: read-only filesystem, empty `$HOME`
  (no SSH keys or Infisical identity), only the worktree and its git admin dir writable, user
  settings only (no `.claude/` settings, hooks or `.mcp.json` from the upstream-controlled
  worktree), read-only git tools plus `git add`. Every check runs from a private export of the
  old `main`'s `.oklabs/` with `python -I`, never from the merge worktree, so incoming top-level
  files cannot shadow modules. The `Conflicted:` trailer is written by the script as the last
  paragraph and read by the workflow from there; commit text reaches the workflow shell only
  through env variables. Repository ruleset `autoresolve-app-only-own-branches` blocks creating,
  updating and deleting every branch except `oklabs/auto-resolve/**`, with bypass for the admin
  role only, so the App cannot touch `main` or `upstream` while Oleg and `OKLABS_SYNC_TOKEN`
  (admin) keep working. The App key lives on baldr (`~/.config/voiceink-autoresolve/app.pem`,
  0600, outside the agent sandbox); canon in Infisical `services:/voiceink-autoresolve`
  (`GITHUB_APP_CLIENT_ID`, `GITHUB_APP_PRIVATE_KEY_B64`). On failure nothing is pushed
  and Telegram gets «VoiceInk auto-resolve не справился» with the log path on baldr
  (`~/.local/state/voiceink-oklabs/runs/<run>.log`). Retry an upstream commit:
  `rm ~/.local/state/voiceink-oklabs/attempted/<sha>` on baldr, then
  `systemctl --user start voiceink-oklabs-autoresolve.service`. Preview without push or message:
  `voiceink-oklabs-autoresolve --dry-run`.

  Recover a real conflict manually on a branch from current `origin/main`: fetch both remotes, merge
  `upstream/main`, resolve and validate, then open a PR. **Merge that PR with a merge commit**
  so the upstream ancestry and conflict resolution are retained; do not squash or rebase it.
  Run the sync workflow after the PR merge to fast-forward the `upstream` mirror if needed.
  For correct release provenance when the recovery PR itself includes upstream app changes,
  fast-forward the mirror to that exact upstream commit before merging the PR.

  The previous rebase workflow replayed historical fork commits on every sync. A version bump
  from 2.22 to 2.25 conflicted with an old architecture-setting insertion even after the fork's
  current tree could merge cleanly. Merging preserves prior resolutions instead of replaying
  those old patches. Run `bash .oklabs/ci/tests/sync.sh` for offline tests of repeated version
  bumps, no-op/dry-run behavior, real conflicts, rewritten upstream, prepare/promotion isolation
  and atomic race rejection. Run `python3 -m unittest discover -s .oklabs/ci/tests -p 'test_*.py' -v`
  for fork-contract regressions, including clean-but-incompatible merges and renamed fork files.
- **Update on the Mac**: Sparkle is excluded from the OKLabs updater (`UpdaterViewModel.isSparkleDisabled`, and CI strips
  `SUFeedURL`/`SUPublicEDKey`), so upstream can never replace the fork build. Updates come from
  `releases/latest` through the command below.

  `VoiceInk/App/Updates/UpdaterViewModel.swift` retains the upstream implementation behind
  `#if !OKLABS`. The fork uses `VoiceInk/OKLabs/OKLabsUpdaterViewModel.swift`, an inert adapter
  with no Sparkle dependency or preference migration. This keeps upstream scheduler changes
  out of the fork instead of inserting guards throughout changing upstream methods. The adapter
  supports both the old Dashboard API and the automatic-check API introduced in upstream PR #1053.
  `OKLabsUpdaterTests` compiles these production files without linking Sparkle and verifies that
  existing automatic-check preferences and manual/scheduled actions cannot enable the updater.

## Notifications

`.oklabs/ci/notify.sh` sends Telegram messages through a bot. The token and the chat live only
in the repo secrets `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`; GitHub masks them in logs. A
message that cannot be delivered is a warning in the log and never fails a job.

| Event | Message |
|---|---|
| `oklabs-release` published a build | «Новая сборка VoiceInk `<version>`», one line on what changed since the previous release on another commit (upstream +N commits with their subjects, new fork commits, changed build inputs), the update command below, the release link. Sent even if the download check after publish failed, with a line saying so |
| any `oklabs-release` job failed or was cancelled | «VoiceInk release упал», the job results, the run URL |
| `oklabs-sync` merge conflict | «VoiceInk sync: конфликт с upstream», the incoming upstream commit, conflicting files, a note that the auto-resolver on baldr will try, manual merge recovery commands and the run URL |
| auto-resolver pushed `oklabs/auto-resolve/<sha10>` | «VoiceInk sync: конфликт разрешён агентом» from `oklabs-autoresolve-pr`: upstream commit, files, the PR link; checks run on the PR, merge is manual |
| auto-resolver failed (baldr) | «VoiceInk auto-resolve не справился»: reason, nothing pushed, the `ssh baldr tail` command for the run log |
| any other `oklabs-sync` failure, timeout or cancel | «VoiceInk sync упал», the failing command or the cancel, the run URL (a fallback text if even the checkout failed) |
| no-op night, clean sync, dry run without a conflict | nothing |

A push whose diff since the previous release touches only CI, docs, tests or the bench
(`.github/`, `*.md`, `Tests/`, `Package.swift`, `.oklabs/scribe-bench/`, `sync.sh`,
`notify.sh`) is still released but not announced. A push that touches only docs,
`oklabs-sync.yml`, `oklabs-autoresolve-pr.yml`, `sync.sh` or `notify.sh` is not released at all. Build inputs in `oklabs-release.yml`
(`DEVELOPER_DIR`, `WHISPER_TAG`, `SIGN_IDENTITY`, `TEAM_ID`) count as app changes. Manual
release runs are always announced. A re-run compares with the newest release on another
commit, never with the release its own first attempt published.

Test the channel without a build: a manual `oklabs-release` run with `telegram_test` sends one
`[TEST]` message, the new-build text for the current latest release, and builds nothing. It
is the only Telegram path that turns a run red, when the message was not delivered.

```bash
gh workflow run oklabs-release.yml -R kossoy/VoiceInk -f telegram_test=true
```

## Mac: install, update, roll back

Install/update command, created once (it verifies the checksum, the signature and Gatekeeper,
keeps the previous app as `VoiceInk.app.old`, and swaps in a staged copy with `mv`):

```bash
mkdir -p ~/.local/bin && cat > ~/.local/bin/voiceink-oklabs-update <<'SH'
#!/bin/bash
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
T=$(mktemp -d ~/Downloads/voiceink-oklabs.XXXX); cd "$T"
echo "1/6 download"
if ! curl -fsSLO https://github.com/kossoy/VoiceInk/releases/latest/download/VoiceInk-oklabs.zip ||
   ! curl -fsSLO https://github.com/kossoy/VoiceInk/releases/latest/download/SHA256SUMS; then
    echo "GitHub browser download failed; retrying through the release asset API"
    gh release download --repo kossoy/VoiceInk --pattern VoiceInk-oklabs.zip --pattern SHA256SUMS --dir "$T" --clobber
fi
grep VoiceInk-oklabs.zip SHA256SUMS | shasum -a 256 -c -
echo "2/6 unpack"
ditto -x -k VoiceInk-oklabs.zip staged
echo "3/6 verify signature"
codesign --verify --deep --strict staged/VoiceInk.app
# No `codesign | grep -q` here: grep -q closes the pipe early, codesign gets
# SIGPIPE and pipefail aborts the script silently (seen on macOS 27.2).
SIG=$(codesign -dv staged/VoiceInk.app 2>&1)
case "$SIG" in *TeamIdentifier=LA9V2K2376*) echo "team OK";; *) echo "unexpected signature:"; echo "$SIG"; exit 1;; esac
echo "4/6 gatekeeper"
spctl -a -t exec -vv staged/VoiceInk.app
echo "5/6 install"
if pgrep -xq VoiceInk; then osascript -e 'quit app "VoiceInk"' || true; sleep 2; fi
mkdir -p ~/Applications; rm -rf ~/Applications/VoiceInk.app.old
if [ -d ~/Applications/VoiceInk.app ]; then mv ~/Applications/VoiceInk.app ~/Applications/VoiceInk.app.old; fi
mv staged/VoiceInk.app ~/Applications/VoiceInk.app
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' ~/Applications/VoiceInk.app/Contents/Info.plist
cd ~; rm -rf "$T"
echo "6/6 launch"
[ -n "${VOICEINK_NO_OPEN:-}" ] || open ~/Applications/VoiceInk.app
SH
chmod +x ~/.local/bin/voiceink-oklabs-update
```

The download stage falls back to the GitHub CLI's official release asset API when
GitHub's browser redirect route fails. `gh` must already be installed for that
fallback; checksum, signature, team and Gatekeeper checks are unchanged. CI uses
the same fallback in `.oklabs/ci/download-release-assets.sh`, additionally binding
all downloaded assets and the checksum manifest to the expected tag, source SHA,
GitHub asset digests and the build's original checksums.

If publication succeeded but download verification failed, use the read-only
`oklabs-verify-release.yml` workflow with the exact existing `tag` and `commit`
inputs. It verifies the published release without building, signing, publishing,
installing or sending another release notification. The historical failed run
stays failed; the separate verification run records recovery.

Update (same command):

```bash
bash ~/.local/bin/voiceink-oklabs-update
```

Roll back to the previous build:

```bash
pgrep -xq VoiceInk && osascript -e 'quit app "VoiceInk"'; sleep 2; rm -rf ~/Applications/VoiceInk.app && mv ~/Applications/VoiceInk.app.old ~/Applications/VoiceInk.app && open ~/Applications/VoiceInk.app
```

Switch back to the upstream streaming engine without reinstalling (and forward again with `oklabs`):

```bash
defaults write com.prakashjoshipax.VoiceInk oklabs.scribeEngine -string upstream
```

The first install over an ad-hoc `make local` build needs one permission reset, because the
grants belong to the old signature; Developer ID builds keep them across updates:

```bash
for s in Microphone Accessibility ScreenCapture AppleEvents PostEvent ListenEvent; do tccutil reset $s com.prakashjoshipax.VoiceInk; done
```

## Settings: `oklabs.*` defaults keys

`defaults write com.prakashjoshipax.VoiceInk <key> <value>`; restart the app afterwards.

| Key | Type, default | Meaning |
|---|---|---|
| `oklabs.scribeEngine` | string, `oklabs` | `upstream` = LLMkit's ElevenLabs client instead of the fork engine |
| `oklabs.keytermsFile` | string, unset | keyterms file: one term per line (`#` comments) or a JSON array; first in file order, max 50 × 20 characters, re-read for every recording |
| `oklabs.managedMode` | bool, `false` | on every launch (after onboarding), make the "Scribe" mode default: Scribe V2 realtime, language auto, no AI, no screen/selection/clipboard context; disable every other mode |
| `oklabs.stripBracketedText` | bool, `false` | upstream's removal of `()`, `[]`, `{}` and `<tag>…</tag>` from transcripts |
| `oklabs.applyWordReplacements` | bool, `false` | apply Dictionary → Word Replacements |
| `oklabs.prePasteDelayMs` | int, `200` | delay before paste, clamped to 0-500 ms |
| `oklabs.notifyOnFailure` | bool, `true` | notification with Retry (re-transcribes, copies to the clipboard) when a transcription fails |
| `oklabs.scribeEndpoint` | string, unset | realtime endpoint override, e.g. a regional `wss://…/v1/speech-to-text/realtime` |

The fork also registers these upstream keys as `false` by default:
`IsAutomaticVocabularyCorrectionEnabled`, `IsAutoLearnDictionaryEnabled`,
`VoiceInkChecksForUpdatesOnLaunch`, `enableAnnouncements`. The ElevenLabs key lives in the login
Keychain (service `com.prakashjoshipax.VoiceInk.Local`, account `elevenLabsAPIKey`); a Data value
written to `LocalKeychain_elevenLabsAPIKey` is moved there on first use. The build ships no
keyterms.

Upstream removed the vocabulary-correction toggle in November 2026. The fork keeps
`IsAutomaticVocabularyCorrectionEnabled` as an explicit opt-in: unset or `false`
preserves verbatim text; `true` enables the upstream phonetic matcher. This applies
to live dictation, file transcription and history retranscription.

## Scribe engine behaviour

100 ms frames; the client commits at the first 0.3 s pause after 30 s and always by 34 s, so the
server's ~36 s auto-commit never fires; every commit is counted and answered (`commit_throttled`
counts as an answer, unsolicited server commits are kept), and all segments are joined; the final
segment is padded to 0.35 s; a socket write blocked for 2 s marks the stream failed; after stop
the wait is at most 8 s, counted from the stop request. A failed stream re-uploads the whole
recording to batch `scribe_v2`; a bad key, quota or terms error is reported without a retry.

## Real-voice harness

`scribe-bench` (release asset) streams local recordings (default: Raycast's
`~/Library/Application Support/com.raycast.macos/dictation-recordings`) through the same
`ScribeLiveSession` and prints only aggregate numbers: WER and Latin-term retention scored like
the dictation benchmark, failures, stop-to-text latency at upload speed and at 1x, and an A/B of
VoiceInk's capture resampler against AVAudioConverter on recordings made at ≥ 32 kHz. Nothing
else is printed or written. `scribe-bench --help` lists the options; it needs
`ELEVENLABS_API_KEY` in the environment.
