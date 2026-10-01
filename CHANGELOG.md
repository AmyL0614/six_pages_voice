# Changelog

All notable changes to this plugin. Dates are when the change reached `main`.
Pin a full commit SHA in your `pubspec.yaml` (see the README's Install section).

## 0.2.0 - 2026-10-01

### Added
- `clearPlayback()` on both platforms: discards agent audio that has been fed
  but not yet played, with a short fade so the cut does not click. Call it on
  an ElevenLabs `interruption` event (barge-in). Returns false, and is safe to
  call, when nothing is playing.
- Android: 16 KB memory page support. The AEC3 library is linked with 16 KB
  ELF alignment, as Google Play requires of apps targeting Android 15
  (API 35) and up.
- Android: a `droppedBytes` counter for the playback ring, logged throttled
  and once at session end, matching the iOS counter.

### Changed
- Android: the call lifecycle and audio routing are owned by Jetpack
  Core-Telecom (`androidx.core:core-telecom` 1.0.1) on API 26 and up. The
  plugin no longer sets the audio mode, communication device or audio focus
  while a Telecom call is active. API 24-25 keep the previous path.
- Android: when the current route is the earpiece, the plugin makes one
  request to move it to the speaker. It never overrides a car, headset or
  wired route.
- Android: playback runs on a dedicated writer thread. `feedPlayback()`
  only enqueues, so the calling thread never blocks while the agent speaks.

### Fixed
- Android: ending a session stops playback immediately (pause and flush
  before stop), instead of letting the current sentence finish.
- Android: a car's End Call button ends the session.

## 0.1.0 - 2026-07-14

First public version.

- Full-duplex voice for conversational AI: microphone capture and agent
  playback through one echo-cancelling path, PCM16 at 16 kHz mono.
- iOS: VoiceProcessingIO for echo cancellation; CallKit, so cars and
  Bluetooth hands-free units treat the session as a call; a 180-second
  playback ring with a `droppedBytes` overflow counter.
- Android: WebRTC AEC3 (arm64-v8a) for echo cancellation, with a
  microphone foreground service.
- MIT license.
