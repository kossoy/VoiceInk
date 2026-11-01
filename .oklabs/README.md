# OKLabs fork layer

This is `kossoy/VoiceInk`, a fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk).

- `upstream` mirrors Beingpax `main`; `main` is upstream plus the OKLabs commits.
- Fork code lives in `VoiceInk/OKLabs/**`, `Tests/ScribeCoreTests`, `Tests/ScribeBenchKitTests`,
  `.oklabs/**`, `Package.swift` and `.github/workflows/oklabs-*.yml`, plus small hooks in
  upstream files guarded by `#if OKLABS`.

## Build and release

- `oklabs-release.yml` (push to `main`): runs `oklabs-test.yml`, then builds on a GitHub-hosted
  macOS runner with `LOCAL_BUILD OKLABS`, signs with Developer ID, notarizes and staples the app
  and the DMG, signs and notarizes the `scribe-bench` harness, and publishes a release.
  Stable URL: `https://github.com/kossoy/VoiceInk/releases/latest/download/VoiceInk-oklabs.zip`.
- `oklabs-test.yml` (every other branch): `swift test` for ScribeCore and the harness, plus an
  unsigned app compile.
- Sparkle is disabled (`UpdaterViewModel.isSparkleDisabled`); CI removes `SUFeedURL` and
  `SUPublicEDKey` from `Info.plist`, so an upstream release can never replace the fork build.
- Version: `CFBundleShortVersionString = <upstream>+oklabs.<UTC yyyymmddHHMM>.<sha7>`,
  `CFBundleVersion = <upstream build>.<run number>`.
- whisper.cpp is pinned (`WHISPER_TAG`) and only the macOS slice is built (`.oklabs/build-whisper.sh`).

## Scribe engine (`VoiceInk/OKLabs/ScribeCore`)

A Swift port of voxtype's ElevenLabs Scribe v2 Realtime engine: 100 ms frames, client commits at
the first pause after 30 s and always by 34 s, every commit counted and answered, final segment
padded to 0.35 s, `commit_throttled` counted as answered, a 2 s write-stall detector, and a final
wait of at most 8 s counted from the stop request. A failed stream sends the whole recording to
batch `scribe_v2`; errors a retry cannot fix (bad key, quota) are reported without a retry.

## Settings (`defaults write com.prakashjoshipax.VoiceInk <key> …`)

| Key | Default | Meaning |
|---|---|---|
| `oklabs.scribeEngine` | `oklabs` | `upstream` switches back to LLMkit's client |
| `oklabs.keytermsFile` | unset | keyterms file (one per line, `#` comments, or a JSON array); goes first, in file order |
| `oklabs.managedMode` | `false` | restore the managed "Scribe" mode (Scribe V2 realtime, language auto, no AI, every other mode off) on each launch |
| `oklabs.stripBracketedText` | `false` | upstream's removal of `()`, `[]`, `{}` and `<tag>…</tag>` |
| `oklabs.applyWordReplacements` | `false` | Dictionary → Word Replacements |
| `oklabs.prePasteDelayMs` | `200` | delay before paste, 0-500 ms |
| `oklabs.notifyOnFailure` | `true` | notification with Retry when a cloud transcription fails |
| `oklabs.scribeEndpoint` | unset | realtime endpoint override |

The fork also registers `IsAutomaticVocabularyCorrectionEnabled`, `IsAutoLearnDictionaryEnabled`,
`VoiceInkChecksForUpdatesOnLaunch` and `enableAnnouncements` as `false` by default. The build
ships no keyterms; the list lives in the user's keyterms file.

## Real-voice harness (`scribe-bench`)

Runs on the user's Mac against local recordings (default: Raycast's
`~/Library/Application Support/com.raycast.macos/dictation-recordings`). It streams each WAV
through the same `ScribeLiveSession` the app uses and prints only aggregate numbers: WER and
Latin-term retention (scored like the dictation benchmark: NFC, lowercase, ё→е, punctuation
ignored), failures, stop-to-text latency at upload speed and at 1x, and an A/B of VoiceInk's
capture resampler against AVAudioConverter. No file names, ids or text are printed or written.
Without `--refs` the reference is batch `scribe_v2` (agreement, not ground truth).
