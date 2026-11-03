# ElevenLabs realtime reliability contribution

Status: published on 2026-11-03 as [Beingpax/VoiceInk #1050](https://github.com/Beingpax/VoiceInk/issues/1050) by `kossoy`, after explicit user approval. Await maintainer direction before preparing an upstream code submission.

## Published VoiceInk issue title

ElevenLabs realtime: proposal for bounded connection and finalization handling

## Published issue body

VoiceInk already supports ElevenLabs Scribe V2 Realtime through LLMkit. We maintain
a working fork with additional connection, streaming, and finalization handling,
and would like to contribute narrowly scoped reliability fixes rather than a
second provider or a replacement of the existing integration.

The fork has explicit handshake and send deadlines, audio framing and segment
boundaries, short-tail padding, commit bookkeeping, and a confirmed final-result
path. Retryable failures can use the full recorded file for batch transcription;
authentication and quota failures are reported without a redundant batch request.

### Suggested first change: LLMkit handshake lifecycle

The current `ElevenLabsStreamingClient.connect()` awaits the first WebSocket
message without a dedicated handshake deadline. It also falls through to the
receive loop for an unexpected initial payload instead of requiring a valid
`session_started`. This is a source finding, not a claim that we reproduced an
outage against the public ElevenLabs service.

We propose a small first patch in **Beingpax/LLMkit** that:

- Requires a valid `session_started` before reporting connection success.
- Bounds the handshake wait with a configurable deadline.
- Closes the socket and session on failure, timeout, or cancellation.
- Adds deterministic mock WebSocket tests for these paths.

LLMkit owns the network protocol; VoiceInk should keep the app-level fallback,
recorded-file lifecycle, and user feedback. A later VoiceInk change could adopt
the improved client and its completion/error contract. Framing, padding, send
deadlines, and finalization would be separate follow-ups, not bundled into the
first handshake patch.

### Evidence and limits

On 2026-11-03, the fork's local SwiftPM run passed 61 tests: 48 ScribeCore tests,
12 benchmark-support tests, and one vocabulary-correction regression test.
The ScribeCore tests use a local scripted WebSocket server, without API keys.
Passing cases include normal streaming, a silent handshake hitting a configured
one-second deadline, auth failure, unreachable endpoint, and socket closure while
the handshake is pending. These tests exercise the fork implementation; a port
to LLMkit still needs its own tests, including unexpected initial payloads.

The broader suite also covers 70-second streams, short tails, `commit_throttled`,
send stalls, and missing final responses. It does **not** establish that every
delayed server auto-commit ordering is safe: the unsolicited-commit test waits
for that event **before** sending the final client commit. We would add a distinct
reproducer before claiming to fix an auto-commit arriving after the final commit.
No production latency or accuracy improvement is claimed from these mock tests.

### Existing work and scope

- [PR #872](https://github.com/Beingpax/VoiceInk/pull/872) already covers empty
  streaming results falling back to batch; we would coordinate rather than
  submit a duplicate.
- [PR #643](https://github.com/Beingpax/VoiceInk/pull/643) touches ElevenLabs
  auth/quota handling. Key rotation is outside this proposal.
- [Issue #908](https://github.com/Beingpax/VoiceInk/issues/908) concerns a batch
  HTTP timeout and is closed; this proposal concerns the realtime connection.

Personal managed settings, keyterms files, signing, release/sync workflows,
notifications, and Sparkle changes would remain in the fork.

Your contribution guide currently asks for issues/discussions rather than PRs.
Would a focused LLMkit handshake patch with these tests be useful, and would you
prefer an issue in LLMkit before any code submission?

## Sources

- [VoiceInk contribution policy](https://github.com/Beingpax/VoiceInk/blob/main/CONTRIBUTING.md)
- [LLMkit network-layer scope](https://github.com/Beingpax/LLMkit/blob/main/README.md)
- [Current ElevenLabs client](https://github.com/Beingpax/LLMkit/blob/1fb15b5771e6faff94f4dbe5c48cf74b7e91a74b/Sources/LLMkit/Streaming/ElevenLabsStreamingClient.swift)
- [Fork session implementation](https://github.com/kossoy/VoiceInk/blob/main/VoiceInk/OKLabs/ScribeCore/ScribeLiveSession.swift)
- [Fork mock WebSocket scenarios](https://github.com/kossoy/VoiceInk/blob/main/Tests/ScribeCoreTests/ScribeLiveSessionTests.swift)
- [Fork provider adapter](https://github.com/kossoy/VoiceInk/blob/main/VoiceInk/OKLabs/ScribeRealtimeProvider.swift)
