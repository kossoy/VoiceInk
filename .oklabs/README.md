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
| `Package.swift`, `Tests/ScribeCoreTests`, `Tests/ScribeBenchKitTests` | `swift test`: unit tests and live-session scenarios against a scripted WebSocket server |
| `.oklabs/scribe-bench/` | `scribe-bench`, the real-voice harness (aggregate numbers only) |
| `.oklabs/ci/` | keychain, archive, notarize, package, bench and sync scripts |
| `.github/workflows/oklabs-*.yml` | `oklabs-test`, `oklabs-release`, `oklabs-sync` |

Branches: `upstream` mirrors Beingpax `main`; `main` = `upstream` + the OKLabs commits.

## Flows

- **Test** (`oklabs-test.yml`, every push to a branch other than `main`/`upstream`): `swift test`
  and an unsigned app compile with `LOCAL_BUILD OKLABS`.
- **Release** (`oklabs-release.yml`, push to `main` or manual): runs the tests, then on a
  GitHub-hosted `macos-26` runner builds whisper.cpp (pinned tag, macOS slice), archives with
  `LOCAL_BUILD OKLABS` and the local entitlements, exports with Developer ID, checks every nested
  signature, notarizes and staples the app and the DMG, signs and notarizes `scribe-bench`, and
  publishes `oklabs-<upstream version>-<run>` as the latest release with `VoiceInk-oklabs.zip`,
  `VoiceInk-oklabs.dmg`, `scribe-bench-macos-arm64.zip` and `SHA256SUMS`. Version:
  `<upstream>+oklabs.<UTC yyyymmddHHMM>.<sha7>`, build `<upstream build>.<run>`.
- **Sync** (`oklabs-sync.yml`, nightly 01:17 UTC or manual): fetches Beingpax `main`; if it moved,
  rebases the OKLabs commits onto it and pushes `upstream` and `main` atomically with
  `--force-with-lease`, using the `OKLABS_SYNC_TOKEN` secret (a token with the `workflow` scope;
  `GITHUB_TOKEN` can neither push rewritten workflow files nor start other workflows). That push
  starts a release. Unchanged upstream = no-op. **A rebase conflict aborts, pushes nothing and
  fails the run**: the Actions tab shows it red, with the fork commit and files in the run
  summary, and the last good release stays `latest`. Fix it locally:
  `git fetch upstream && git rebase --onto upstream/main <base from the summary> main`, resolve,
  `git push --force-with-lease origin main` and push the new `upstream`. Manual runs take
  `dry_run` and a test-only `upstream_ref` (`owner/repo:ref`).
- **Update on the Mac**: Sparkle is off (`UpdaterViewModel.isSparkleDisabled`, and CI strips
  `SUFeedURL`/`SUPublicEDKey`), so upstream can never replace the fork build. Updates come from
  `releases/latest` through the command below.

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
curl -fsSLO https://github.com/kossoy/VoiceInk/releases/latest/download/VoiceInk-oklabs.zip
curl -fsSLO https://github.com/kossoy/VoiceInk/releases/latest/download/SHA256SUMS
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
