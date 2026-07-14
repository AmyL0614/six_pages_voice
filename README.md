# Six Pages Voice

**A Flutter plugin for real-time conversational AI.**

*Built by a paramedic who needed conversational AI to feel as natural as talking to another person.*

Full-duplex, echo-cancelled, low-latency voice — on the phone speaker, on wired headphones, on Bluetooth headsets, and in a car. Built to make an AI voice conversation feel like a phone call, because that is what it has to feel like to be worth having.

Originally developed for [Six Pages](https://thesixpages.app), a trauma-informed voice and writing companion. Extracted and open-sourced because the infrastructure shouldn't have to be rebuilt by the next person.

---

## Why this exists

Most Flutter audio packages do one thing well: record, or play, or stream, or route Bluetooth.

Very few do **all of them at once, in both directions, without the AI hearing itself** — and almost none of them survive a car.

That last part is the hard part. A conversation isn't a recording followed by a playback. It's both, continuously, with the microphone open while the speaker is talking, and something has to cancel the echo or the AI transcribes its own voice and answers itself.

This plugin is the missing bridge between Flutter and streaming conversational AI (ElevenLabs, or anything else that speaks and listens in real time).

---

## Features

- **Full-duplex streaming** — mic open while audio plays
- **Native acoustic echo cancellation**
  - Android: WebRTC **AEC3** (software, both far-end and near-end fed)
  - iOS: **VoiceProcessingIO** (hardware/system AEC)
- **CallKit integration on iOS** — the session is a real call, at call priority
- **Bluetooth HFP** — bidirectional, including **automotive** head units
- **Bluetooth A2DP**, wired headsets, and speaker
- **Lock-free SPSC ring buffer** — 180-second capacity, so a long TTS turn delivered faster than real time never overflows
- **Automatic route following** — audio follows the device the user actually connected, mid-conversation
- **Survives screen lock** — Android foreground service + wakelock; iOS background audio
- **Rich diagnostics** — a single-line strip that makes failures legible (this is how the car bug was found)

---

## Platforms

| Platform | Status | AEC | Bluetooth HFP | Car |
|---|---|---|---|---|
| Android | Supported | WebRTC AEC3 | Yes | Proven |
| iOS | Supported | VoiceProcessingIO | Yes | Proven |

---

## Install

```yaml
dependencies:
  six_pages_voice:
    git:
      url: https://github.com/AmyL0614/six_pages_voice.git
      ref: <commit-sha>
```

Pin a full 40-character SHA. A short hash that happens to be all digits will be parsed as a number and fail.

---

## Usage

The API is intentionally small. Four things.

```dart
import 'package:six_pages_voice/six_pages_voice.dart';

final voice = SixPagesVoice();

// Start the engine. Returns false if the session could not open.
final bool ok = await voice.start();
if (!ok) return;

// Microphone frames: PCM16, 16 kHz, mono, 640 bytes per 20 ms frame.
// Send these to your STT / conversational endpoint.
voice.captureStream.listen((Uint8List frame) {
  socket.add(frame);
});

// Audio coming back from your TTS. Raw PCM16 @ 16 kHz.
// Write it straight in — no resampling needed, the platform handles it.
voice.feedPlayback(pcmBytes);

// Tear down.
await voice.stop();
```

**`start()` is genuinely asynchronous on iOS.** It does not resolve until the system has activated the audio session and the unit is running. When it returns `true`, the engine is live and it is safe to feed playback. If it returns `false`, the session did not open — do not feed it.

---

## iOS setup — required

### Info.plist

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <string>voip</string>
</array>

<key>NSMicrophoneUsageDescription</key>
<string>Your reason here.</string>
```

**Both background modes are required, and they do different jobs.**

- `audio` keeps playback alive when the screen locks.
- `voip` is what **CallKit checks on every transaction**. Without it, `CXStartCallAction` is refused with `CXErrorCodeRequestTransactionError.unentitled` — `provider(_:didActivate:)` never fires, the audio unit is never built, and **the session never starts at all.**

This is not optional and it is not a background-only concern. It gates the foreground path too.

> **On App Store review:** `voip` falls under Guideline 2.5.4 — background modes must be used for their intended purpose. Apple rejects apps that declare a mode they *don't use*, not apps that aren't telephones. If your app conducts genuine real-time two-way voice over IP and needs CallKit for hands-free audio, that is a truthful and specific justification. Be ready to state it.

### What this plugin does NOT do on iOS

This matters more than what it does. **Every iOS fix in this project's history was a removal.**

- **No `setActive(true)`.** Anywhere. Under CallKit, *the system* activates the session at elevated priority in `provider(_:didActivate:)`. Activating it yourself fights that. (Apple, WWDC 2016 S230.)
- **No `overrideOutputAudioPort`.** VoiceProcessingIO already manages Bluetooth and CarAudio ports.
- **No `.allowBluetoothA2DP` option.** Adding it caused a tin-can artifact. Removing it fixed it.
- **No manual resampling.** VPIO resamples 16 kHz → hardware internally, continuously, with no chunk-boundary seams.
- **The route-change listener observes. It never steers.**

Android's `AudioManager` *expects* the app to select the device. iOS does not, and VoiceProcessingIO especially does not. Carrying Android's habits across that boundary broke iOS every single time. Every time we took our hands off, it worked.

---

## Android setup

The plugin handles routing internally: priority selection (Bluetooth → BLE → wired → USB → speaker), with speaker as *fallback*, never as an override — so it will not yank audio off a user's headset.

A foreground service (`microphone` type) plus a partial wakelock keeps the mic alive when backgrounded. On Android 14+ this is mandatory: without it the microphone is **silently muted** the moment the app leaves the foreground.

Your app must request `RECORD_AUDIO`, and `POST_NOTIFICATIONS` for the foreground-service notification.

---

## The car bug

Cars are the reason this plugin exists in its current form, and the failure is worth documenting because it is not obvious.

When a car opens a Bluetooth **HFP** channel, its state machine expects to be told a **call is in progress**. Not audio — a *call*. It's listening for the telephony signal (`+CIEV: call=1`).

If iOS never sends that signal, the head unit concludes the link is dead and tears down the SCO uplink — reliably, at about **five seconds**. Audio falls back to the phone speaker, mid-sentence.

The fix is not an audio fix. It's a **declaration**:

1. Declare a real call to iOS via **CallKit** (`CXProvider`, `CXCallController`, `CXStartCallAction`).
2. Let the system activate the audio session at call priority in `provider(_:didActivate:)` — do not activate it yourself.
3. Build the audio unit *there*, once activation has actually happened.
4. Report the call connected once audio is genuinely flowing.
5. **Declare `voip` in `UIBackgroundModes`**, or CallKit refuses the whole transaction as unentitled and none of the above ever runs.

Step 5 was missing for six builds. iOS said so, in plain English, every single time — into an `os_log` that cannot be read from Windows.

---

## Diagnostics

The plugin exposes a single-line diagnostic strip over the method channel (`getDiagnostics`). It is not in the Dart facade yet; call the channel directly if you want it. It is the single most valuable thing in this repository.

A healthy automotive run:

```
callKit=active; ckActivates=1;
ckTrail=[start,req,ok,perform,ACTIVATE,audioUp]; ckError=-;
granted=16000Hz [MATCHES 16k];
input=bt-hfp; prefIn=ok; routeAtStart=bt-hfp; route=bt-hfp;
routeChanges=0; why=[];
renderCalls=5028; captureCalls=5028; captureBytes=3700608;
droppedBytes=0; maxRenderUs=28; underruns=9; interruptions=0
```

How to read it:

| Field | Meaning |
|---|---|
| `ckTrail` | **Read first.** The CallKit lifecycle, in order. The healthy chain is `[start,req,ok,perform,ACTIVATE,audioUp]`. Anything shorter names exactly where it broke. |
| `ckError` | iOS's own words when it refuses a call. `-` means no refusal. |
| `droppedBytes` | **The first audio number, always.** `>0` means the ring overflowed and later audio was discarded — a complete explanation of "degrades late, tail missing." |
| `maxRenderUs` | Render callback duration vs a ~23,000 µs deadline. Small = the callback is innocent. |
| `renderCalls` vs `captureCalls` | Should be equal. The mic fired on every render cycle. |
| `route` / `routeChanges` / `why=[]` | In a car, an **empty** `why=[]` is the goal. It means the platform was left alone to do its job. |

**Counter-intuitive, and it cost three wrong fixes:** low underruns plus an audio problem means **overflow**, not starvation. Streaming TTS delivers a turn *faster than real time*; the render callback drains at natural speech rate. The producer outruns the drain, always. Adding buffer depth or a re-buffering gate *pauses the drain* and makes it worse. Check `droppedBytes` first.

---

## Common issues

**Car hangs up after ~5 seconds (iOS).**
CallKit is not declaring a call. Check `ckTrail`. If it reads `[start,req,REFUSED]` and `ckError` says `unentitled`, add `voip` to `UIBackgroundModes`.

**Session never starts, button spins (iOS).**
Same check. `callKit=none` is ambiguous by itself — read `ckTrail` to distinguish "never requested" from "refused" from "completion never returned."

**Microphone silently dies when backgrounded (Android 14+).**
You need a foreground service of type `microphone`. The plugin ships one.

**Playback degrades late in long replies, tail missing.**
Ring overflow. `droppedBytes > 0`. Do not add priming depth — that makes it worse.

**AI transcribes its own voice.**
AEC isn't receiving the far-end signal. On Android, AEC3 needs *both* sides fed — check that playback frames are reaching it, not just the mic.

---

## Roadmap

- [ ] Expose `getDiagnostics` in the Dart facade
- [ ] Example application
- [ ] API documentation
- [ ] pub.dev release
- [ ] Configurable sample rate (currently 16 kHz mono, fixed)
- [ ] Wider device/head-unit testing

---

## Acknowledgements

WebRTC AEC3 is vendored from the WebRTC project. Copyright is retained by Google Inc., the WebRTC project authors, Mark Olesen, Takuya Ooura, and the `spl_sqrt_floor` authors. See `third_party/` for upstream licenses.

Thanks to [Stuart Gardoll](https://github.com/sgardoll) for the ElevenLabs Flutter library.

This plugin was debugged **entirely from Windows** — no Mac, no Xcode, no Instruments, no Console.app. Every iOS diagnosis had to come back over a single line of text rendered inside the app. That constraint is the reason the diagnostic strip exists, and the strip is the reason the bugs were findable at all.

If you cannot read what the platform is telling you, stop fixing and build the instrument first.

---

## Contributing

Issues, PRs, device reports, and head-unit test results are all welcome. Bluetooth and automotive audio is a long tail of specific hardware behaving specifically — every real-world data point helps.

If this saved you weeks of debugging, say so. That is exactly why it's here.

---

## License

MIT — Copyright (c) 2026 Six Pages Studio, LLC
