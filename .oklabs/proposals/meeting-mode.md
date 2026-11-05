# Meeting mode: foundation and Teams verification

## Status

Prepared on a separate feature branch. This is a tested core and a read-only
diagnostic executable, not a working recording mode in the installed app.
The app's recorder, dictation delivery, UI and provider contracts are unchanged.

The first local probe confirmed Accessibility access to Microsoft Teams desktop
26276.505.5234.9924. The user confirmed that no call was active. Active-speaker
attributes and their latency remain unverified. No participant names, chat text,
audio or screenshots were saved from that probe.

## Confirmed product behavior

Granola reads participant display names and active-speaker information from the
Teams desktop interface through macOS Accessibility. It needs neither a Teams API
connection nor a meeting bot for this attribution:

- https://docs.granola.ai/help-center/taking-notes/speaker-attribution
- https://docs.granola.ai/help-center/taking-notes/speaker-attribution-teams

Screen Recording permission is distinct from Accessibility. VoiceInk already
captures screen context once for vocabulary preparation; that snapshot does not
provide a continuous speaker timeline.

## Prepared implementation

- MeetingCore stores raw partial/final ASR segments, stable segment IDs, audio
  source and start/end offsets on a shared monotonic session clock.
- Pause/resume preserves gaps in that clock. Late ASR results for audio captured
  before pause/stop remain accepted. Results from a paused interval are rejected.
- A partial can be replaced by its final event without duplicating text.
  A committed final cannot silently become a different utterance or audio source.
- Name resolution requires complete, unambiguous speaker-cue coverage for a
  segment. Missing or conflicting evidence produces Others. Microphone text
  remains Me. A roster entry or OCR name alone must not create a speaker cue.
- MeetingTranscriptStore writes an atomic canonical session checkpoint and
  regenerates TXT/MD/JSON raw exports. Checkpoints preserve partial hypotheses and
  speaker cues; exports include finalized segments only.
- meeting-probe inspects only Teams Accessibility windows, with depth, node and
  time limits. It performs no AX actions and captures no audio or screenshots.
  It does not implement or guess an active-speaker selector.

The store must have one serialized owner. A process restart can recover saved
text and state, but the next integration must explicitly re-establish capture,
record the interrupted interval and rebase the new process's monotonic clock.
The core alone does not resume a live microphone or prevent audio loss.

## Local verification commands

From this checkout:

    swift test --filter MeetingCoreTests
    swift run meeting-probe --help
    swift run meeting-probe

Default probe output contains structural identifiers and attribute names.
For a live call, identify the call window index from the default structural
snapshot, then inspect only that window:

    swift run meeting-probe --window 0 --include-labels --max-seconds 5

The index is an example, not an assumed Teams selector. Labels can contain work
content; keep such snapshots outside the repository. The tool prints to stdout
and does not create files.

## Next integration steps

1. In an actual Teams call, sample speaker changes between two participants.
   Verify which AX identifier/attribute exposes active speaker, whether it
   survives Teams being in the background, and what happens during overlap.
   Measure timestamp lag. Ambiguous observations must remain unknown.
2. Implement a Teams-specific observer against that verified evidence. Keep
   audio capture and ASR running when AX temporarily fails. Avoid treating every
   participant name as the active speaker.
3. Add microphone and system-audio capture with distinct sources and one audio
   clock. Exclude the app's own playback and handle loudspeaker echo. Meeting
   capture must bypass dictation's optional media pause/system mute.
4. Extend the meeting ASR adapter to preserve audio timestamps and segment
   metadata. Do not remove the existing Scribe duplicate-event protection just
   to consume timestamp events; merge metadata into stable segment IDs.
5. Connect the core to a Meeting mode coordinator: checkpoint after segment and
   control events, restore explicitly after interruption, and bypass paste/send
   delivery into the currently focused app.
6. Add the transcript window: separate utterances, Me/participant labels,
   timestamps, Pause/Resume, search, Copy and export directory selection.

Acceptance requires actual dual-source recording, a long-call/paused-call test,
correct raw exports, and measured Teams name attribution. A passing core test or
a successful Accessibility read does not establish those runtime results.
