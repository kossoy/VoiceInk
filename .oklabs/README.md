# OKLabs fork layer

This is `kossoy/VoiceInk`, a fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk).

- `upstream` mirrors Beingpax `main`; `main` is upstream plus the OKLabs commits.
- Fork code lives in `VoiceInk/OKLabs/**`, `.oklabs/**` and `.github/workflows/oklabs-*.yml`,
  plus a few small hooks in upstream files guarded by `#if OKLABS`.
- `oklabs-release.yml` builds on a GitHub-hosted macOS runner with the compilation
  conditions `LOCAL_BUILD OKLABS`, signs with Developer ID, notarizes and staples the app
  and the DMG, and publishes a release. Stable URL:
  `https://github.com/kossoy/VoiceInk/releases/latest/download/VoiceInk-oklabs.zip`.
- Sparkle is disabled (`UpdaterViewModel.isSparkleDisabled`), and CI removes `SUFeedURL`
  and `SUPublicEDKey` from `Info.plist` before building, so an upstream release can never
  replace the fork build.
- Version: `CFBundleShortVersionString = <upstream>+oklabs.<UTC yyyymmddHHMM>.<sha7>`,
  `CFBundleVersion = <upstream build>.<run number>`.
- whisper.cpp is pinned (`WHISPER_TAG` in the workflow) and only the macOS slice is built
  (`.oklabs/build-whisper.sh`).
