# Meeting mode: local preview and Teams verification

## Implementation

The feature branch contains an app-integrated Meeting Transcript window. The
installed app and the main checkout are separate from this worktree.

- Open **File → Meeting Transcript…**, or **Meeting Transcript…** in the menu bar.
- Select an available model independently of dictation. Local models run on the
  Mac; cloud models send audio to the selected provider and can incur charges.
- Start requests microphone and Screen & System Audio Recording permissions.
  SCStream supplies separate microphone and system buffers on the host clock.
  No video output is registered or saved. The default microphone and audio from
  all other apps are captured; VoiceInk's own playback is excluded.
- Each source is converted to 16 kHz mono PCM independently. A bounded energy
  gate retains 200 ms of pre-roll, ends after 700 ms of silence, and limits chunks
  to 12 seconds. It is not voice diarization or word-level timestamp alignment.
- Audio WAV files and queue metadata are saved before ASR starts. The queue is
  serial, pauses on provider failure, and exposes Retry. Raw text is committed
  before marking the audio job complete. Saved meetings restore pending jobs
  after restarting, without automatically reopening the microphone or sending
  audio to a provider.
- Pause stops both capture outputs and drains trailing audio. Resume preserves
  the paused gap on the same session clock. Stop also waits for audio persistence;
  ASR may finish afterward. Closing a live meeting offers Stop and Close.
  Quitting offers Stop and Quit and preserves pending audio for later recovery.
- The window shows timestamped Me/Others utterances, audio meters, pending/failed
  work, transcript search, Copy, TXT export, saved meetings and a Files button.
- The meeting uses a separate ASR registry and bypasses dictation's media pause,
  system mute, enhancement and paste/send workflow. Dictation is blocked while
  capture or meeting ASR is active to avoid resource and audio-policy conflicts.

Files are stored under:

    ~/Library/Application Support/com.prakashjoshipax.VoiceInk/Meetings/<session UUID>/
        session.json
        transcript.txt
        transcript.md
        transcript.json
        audio/<job UUID>.wav
        audio/<job UUID>.json

Audio is retained locally for recovery; this preview has no meeting retention
policy or deletion UI. The Files button opens the relevant directory. Final
exports include raw ASR text only. A sudden process crash can still lose audio
in the current, unfinished chunk (up to about 12 seconds); completed chunks are
durable. Headphones are recommended because acoustic echo cancellation is not
implemented.

## Teams participant names

Granola's documented attribution reads participant display names and
active-speaker information from Teams desktop through macOS Accessibility:

- https://docs.granola.ai/help-center/taking-notes/speaker-attribution
- https://docs.granola.ai/help-center/taking-notes/speaker-attribution-teams

The read-only meeting-probe confirmed Accessibility access to installed Teams
26276.505.5234.9924 while no call was active. It did not establish an active-speaker
selector. The current app therefore labels system audio **Others**. It does not
assign names from roster entries or OCR. The resolver accepts names only when
verified, unambiguous cues cover an entire segment; no Teams observer is enabled.

## Automated validation

From this worktree:

    swift test
    swift run meeting-probe --help

Meeting tests cover dual-source ordering, raw text, partial/final events, pause
gaps and late results, conservative name resolution, interrupted resume recovery,
invalid checkpoints, bounded/silent audio, durable queue failures and WAV bytes.
Capture tests feed synthetic CMSampleBuffer data through the real AVAudioConverter
without touching a microphone: stereo/native-rate input, source isolation and
repeated small device packets. The converter respects requested packet counts
and drains all output; a single oversized input buffer can otherwise lose samples.

The actual macOS app is built separately with Xcode and fork flags LOCAL_BUILD
and OKLABS. The local Debug bundle is ad-hoc signed. Build/test logs are under
/tmp/voiceink-meeting-*.log. No live meeting capture, paid ASR call, or participant
attribution validation is implied by these automated checks.

## First runtime check

The local preview bundle is:

    /tmp/voiceink-meeting-derived/Build/Products/Debug/VoiceInk Dev.app

1. Quit the installed VoiceInk before opening the preview: the existing app
   architecture shares local transcript/model stores between Debug and Release.
2. Open File → Meeting Transcript…. Choose a downloaded local model or an
   explicitly selected cloud model. Press Start and grant the two audio permissions.
3. Speak for 15–20 seconds. Check the microphone meter, Me text and timestamps.
4. Pause, speak a phrase that must be absent, Resume, then speak another phrase.
   Stop, let the queue drain, Copy/Export and inspect Files.
5. For system audio, play a known spoken recording with headphones. Check that
   it appears as Others and the microphone text remains a separate source.
6. Restart the app and load the meeting under Saved Meetings. To check provider
   failure, disconnect before an ASR request, verify saved audio and Retry after
   restoring connectivity. A forced crash is not needed for the first smoke test.

A solo Teams call is enough for the microphone/UI/AX structural check. Playback
can test system audio without another participant. Two speaking participants are
needed to validate actual Teams remote-speaker names and speaker changes.

For Teams inspection, run the structural probe first to find the call window:

    swift run meeting-probe --max-nodes 500 --max-seconds 3
    swift run meeting-probe --window N --include-labels --max-nodes 1500 --max-seconds 5

N must be the observed call window index. Keep label snapshots outside git.
The probe is bounded and read-only: no AX actions, screenshots, audio or permission
prompts. Next, verify actual active-speaker attributes, their latency, background
behavior and overlap across two participants before implementing name observation.
