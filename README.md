# Six Pages Voice

**A Flutter plugin for real-time conversational AI.**

*Built by a paramedic who needed conversational AI to feel as natural as talking to another person.*

Full-duplex, echo-cancelled, low-latency voice — on the phone speaker, on wired headphones, on Bluetooth headsets, and in a car. Built to make an AI voice conversation feel like a phone call, because that is what it has to feel like to be worth having.

Originally developed for [Six Pages](https://thesixpages.app), a trauma-informed voice and writing companion. Extracted and open-sourced because the infrastructure shouldn't have to be rebuilt by the next person.

**[Why this exists](#why-this-exists)** · **[Architecture](#architecture)** · **[Features](#features)** · **[Install](#install)** · **[Usage](#usage)** · **[iOS setup](#ios-setup--required)** · **[Android setup](#android-setup)** · **[The car bug](#the-car-bug)** · **[Diagnostics](#diagnostics)** · **[Common issues](#common-issues)**

---

## Why this exists

Most Flutter audio packages do one thing well: record, or play, or stream, or route Bluetooth.

Very few do **all of them at once, in both directions, without the AI hearing itself** — and almost none of them survive a car.

That last part is the hard part. A conversation isn't a recording followed by a playback. It's both, continuously, with the microphone open while the speaker is talking, and something has to cancel the echo or the AI transcribes its own voice and answers itself.

This plugin is the missing bridge between Flutter and streaming conversational AI (ElevenLabs, or anything else that speaks and listens in real time).

---

## Architecture

This plugin is the two ends of the loop — everything above the dashed line and everything below it. What happens in between is yours.

```
              Microphone
                  │
                  ▼
   ┌──────────────────────────────┐
   │  Acoustic echo cancellation  │   iOS:     VoiceProcessingIO
   │                              │   Android: WebRTC AEC3
   └──────────────────────────────┘
                  │
                  ▼
           voice.captureStream          ← PCM16, 16 kHz, mono, 640-byte frames
                  │
- - - - - - - - - ┼ - - - - - - - - - - - - - - - - - - - -   your code
                  │
                  ▼
          Speech-to-text  →  LLM  →  Text-to-speech
                  │
- - - - - - - - - ┼ - - - - - - - - - - - - - - - - - - - -   plugin again
                  │
                  ▼
         voice.feedPlayback()           ← raw PCM16 in, no resampling needed
                  │
                  ▼
   ┌──────────────────────────────┐
   │   Lock-free SPSC ring        │   180 s of capacity, because TTS
   │   180 s (5,760,000 bytes)    │   arrives faster than real time
   └──────────────────────────────┘
                  │
                  ▼
   ┌──────────────────────────────┐
   │   Route selection            │   car (HFP) · headset · wired
   │                              │   USB · speaker
   └──────────────────────────────┘
                  │
                  ▼
                Output
```

The far-end signal is fed back into the canceller, which is why the AI does not transcribe itself while it is speaking.

---

## Features

- **Full-duplex streaming** — mic open while audio plays
- **Native acoustic echo cancellation**
  - Android: WebRTC **AEC3** (software; both far-end and near-end signals fed to it)
  - iOS: **VoiceProcessingIO** (system AEC)
- **CallKit integration on iOS** — the session is a real call, at call priority. This is what makes cars work.
- **Bluetooth HFP** — bidirectional, including **automotive** head units
- **Bluetooth A2DP** — output-only devices (headphones, speakers)
- **Wired headsets, USB, and speaker**, with automatic priority selection
- **Lock-free SPSC ring buffer** — 180 seconds of capacity (5,760,000 bytes), so a TTS turn delivered *faster than real time* never overflows
- **Automatic route following** — audio follows the device the user connects mid-conversation
- **Survives screen lock** — Android foreground service (`microphone` type) + partial wakelock; iOS background audio
- **Rich diagnostics** — a single-line strip that makes failures legible. This is how the car bug was found.

**Audio format:** PCM16, 16 kHz, mono. 640-byte frames (20 ms).

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
      ref: <full-40-char-commit-sha>
```

Pin a full 40-character SHA. A short hash that happens to be all digits gets parsed as a number and fails.

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

**`start()` is genuinely asynchronous on iOS.** It does not resolve until the system has activated the audio session and the audio unit is running. When it returns `true`, the engine is live and it is safe to feed playback. If it returns `false`, the session did not open — do not feed it. (There is a 4-second internal deadline, so a failure fails loudly rather than hanging forever.)

A runnable demo lives in [`example/`](example/lib/main.dart).

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

This is not a background-only concern. It gates the foreground path too. This plugin does **not** use PushKit and does not receive incoming calls; the CallKit call is outgoing, user-initiated, and foreground.

> **On App Store review:** `voip` falls under Guideline 2.5.4 — background modes must be used for their intended purpose. Apple rejects apps that declare a mode they *don't use*, not apps that aren't telephones. If your app conducts genuine real-time two-way voice over IP and needs CallKit for hands-free audio, that is a truthful and specific justification. Be ready to state it.

### The iOS audio session contract

```
Category:  .playAndRecord
Mode:      .voiceChat          (VPIO requires this for platform AEC)
Options:   [.allowBluetooth, .allowBluetoothA2DP]
           + .defaultToSpeaker — ONLY when no external output is attached
```

`.allowBluetooth` enables **HFP** (bidirectional — cars, headsets with a mic).
`.allowBluetoothA2DP` enables **A2DP** (output-only — headphones, speakers).

Both are set, deliberately. When one device offers *both* profiles, Apple gives **HFP priority** — which is what you want in a car, because HFP is the profile that carries your microphone upstream. A2DP stays in the set so output-only devices that have no HFP still work.

**These options are set in two places and must stay identical.** If `startUnit()` and the route-change handler disagree, a mid-session route change silently re-negotiates the Bluetooth profile underneath a live audio unit.

### What this plugin does NOT do on iOS

This matters more than what it does. **Most iOS fixes in this project's history were removals.**

- **No `setActive(true)`.** Anywhere — including the interruption-resume path. Under CallKit, *the system* activates the session at elevated priority in `provider(_:didActivate:)`. Activating it yourself fights that. (Apple, WWDC 2016 S230.) `setActive(false)` on teardown is retained.
- **No `overrideOutputAudioPort`.** VoiceProcessingIO already manages Bluetooth and CarAudio ports. Calling this fought VPIO and caused both a long-reply chop and a car disconnect.
- **No `AVAudioConverter`.** VPIO resamples 16 kHz → hardware internally, continuously, with no chunk-boundary seams. Manual conversion introduced artifacts at every chunk edge.
- **The route-change listener does not revert routes.** It observes, records the reason, and re-evaluates exactly one thing: whether `.defaultToSpeaker` should be on (below). It never tells iOS which device to use.

Android's `AudioManager` *expects* the app to select the device. iOS does not, and VoiceProcessingIO especially does not. Carrying Android's habits across that boundary broke iOS every time.

### The one route decision the plugin does make

`.defaultToSpeaker` is toggled based on whether an external output is attached:

- **No external device** → `.defaultToSpeaker` **ON**, so audio comes out of the speaker rather than the earpiece.
- **Headphones / Bluetooth / car attached** → `.defaultToSpeaker` **OFF**, so audio goes where the user put it.

This is re-evaluated on route change, and it is idempotent — it early-returns when the desired state already matches. That early return is the only thing preventing an infinite loop, because setting the category itself fires a route-change notification.

If `setCategory` throws mid-session, the failure is **non-fatal**: it is counted onto the diagnostic strip and the existing category is left alone. A car that will not route is annoying. A conversation that dies is unacceptable.

### `setPreferredInput`

On start, the plugin selects the preferred *input* port (for example, the car's HFP microphone). This is an input hint, not an output override — and if it throws, it is non-fatal and the session continues as-is.

---

## Android setup

Routing is handled internally, with priority selection:

```
Bluetooth SCO → BLE headset → wired headset → wired headphones → USB headset → built-in speaker
```

Speaker is a **fallback**, never an override — the plugin will not yank audio off a user's headset. `AudioManager.setCommunicationDevice()` is used, with `MODE_IN_COMMUNICATION`.

**Order matters.** The route must be asserted *after* both streams are live. Starting an audio session in `MODE_IN_COMMUNICATION` silently clobbers the route back to the earpiece, so asserting it too early does nothing at all.

The plugin ships a foreground service (`microphone` type) plus a partial wakelock. On **Android 14+ this is mandatory**: without it the microphone is *silently muted* the moment the app leaves the foreground.

The plugin's manifest declares:

```xml
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
```

**Your app must declare and request `RECORD_AUDIO` itself**, plus `POST_NOTIFICATIONS` (Android 13+) for the foreground-service notification. The plugin does not request these for you.

---

## The car bug

Cars are the reason this plugin exists in its current form, and the failure is not obvious.

When a car opens a Bluetooth **HFP** channel, its state machine expects to be told a **call is in progress**. Not audio — a *call*. It is waiting for the telephony signal (`+CIEV: call=1`).

If iOS never sends that signal, the head unit concludes the link is dead and tears down the SCO uplink — reliably, at about **five seconds**. Audio falls back to the phone speaker, mid-sentence.

The fix is not an audio fix. It is a **declaration**:

1. Declare a real call to iOS via **CallKit** (`CXProvider`, `CXCallController`, `CXStartCallAction`).
2. Report the call as *connecting* from inside `provider(_:perform: CXStartCallAction)`, **then** fulfill the action.
3. Let the system activate the audio session at call priority in `provider(_:didActivate:)`. **Do not activate it yourself.**
4. Build the audio unit *there* — once activation has actually happened.
5. Report the call **connected** only once audio is genuinely flowing.
6. **Declare `voip` in `UIBackgroundModes`**, or CallKit refuses the entire transaction as `unentitled` and none of the above ever runs.

Step 6 was missing for six builds. iOS said so, in plain English, every single time — into an `os_log` that cannot be read from Windows.

**Retain your plugin instance.** `addMethodCallDelegate` and `setStreamHandler` both hold their delegate *weakly*. That is harmless while everything is synchronous, but CallKit is callback-driven: the object must still exist when `didActivate` fires later. A `static` strong reference in `register(with:)` is required.

---

## Diagnostics

The plugin maintains a single-line diagnostic strip that makes failures legible. It is the single most valuable thing in this repository.

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
| `ckTrail` | **Read first.** The CallKit lifecycle, in order. Healthy is `[start,req,ok,perform,ACTIVATE,audioUp]`. Anything shorter names exactly where it broke. |
| `ckError` | iOS's own words when it refuses a call. `-` means no refusal. |
| `droppedBytes` | **The first audio number, always.** `>0` means the ring overflowed and later audio was discarded — a complete explanation of "degrades late, tail missing." |
| `maxRenderUs` | Render callback duration against a ~23,000 µs deadline. Small means the callback is innocent. |
| `renderCalls` vs `captureCalls` | Should be equal — the mic fired on every render cycle. |
| `granted=` | The hardware sample rate. `[MATCHES 16k]` means no resampling. A 48 kHz grant means the 16 kHz source is being upsampled. |
| `route` / `routeChanges` / `why=[]` | In a car, an **empty** `why=[]` is the goal. It means the platform was left alone. |

**Counter-intuitive, and it cost three wrong fixes:** low underruns *plus* an audio problem means **overflow**, not starvation. Streaming TTS delivers a turn *faster than real time*, while the render callback drains at natural speech rate. The producer outruns the drain, always. Adding buffer depth or a re-buffering gate **pauses the drain** and makes it worse. Check `droppedBytes` first.

**Read the strip before you tear down the session.** Teardown clears the ring and resets the primed flag; a strip captured after the conversation has ended tells you nothing about the conversation.

> ### Engineering principle
>
> **If you cannot read what the platform is telling you, stop fixing and build the instrument first.**

---

## Common issues

**Car hangs up after ~5 seconds (iOS).**
CallKit is not declaring a call. Check `ckTrail`. If it reads `[start,req,REFUSED]` and `ckError` says `unentitled`, add `voip` to `UIBackgroundModes`.

**Session never starts; the button just spins (iOS).**
Same check. `callKit=none` is ambiguous on its own — read `ckTrail` to distinguish "never requested" from "refused" from "completion never returned."

**Microphone silently dies when backgrounded (Android 14+).**
You need a foreground service of type `microphone`. The plugin ships one — make sure `RECORD_AUDIO` and `POST_NOTIFICATIONS` are granted.

**Playback degrades late in long replies; the tail is missing.**
Ring overflow. `droppedBytes > 0`. Do **not** add priming depth — that makes it worse.

**Audio sounds thin or tinny on Bluetooth headphones.**
Check `granted=`. A2DP headphones force the hardware to 48 kHz, and a 16 kHz source upsampled to 48 kHz cannot regain information it never had. In a car, HFP grants 16 kHz natively and the artifact disappears.

**The AI transcribes its own voice.**
AEC is not receiving the far-end signal. On Android, AEC3 needs *both* sides fed — verify that playback frames are reaching it, not just the mic.

---

## Roadmap

- [ ] Expose the diagnostic strip over the method channel and in the Dart facade
- [x] Example application
- [ ] API documentation
- [ ] pub.dev release
- [ ] Configurable sample rate (currently fixed at 16 kHz mono)
- [ ] Behavior when a real phone call arrives mid-session
- [ ] Android Auto (USB projection) session persistence through screen sleep
- [ ] Wider device and head-unit testing

---

## Acknowledgements

WebRTC AEC3 is vendored from the WebRTC project. Copyright is retained by Google Inc., the WebRTC project authors, Mark Olesen, Takuya Ooura, and the `spl_sqrt_floor` authors. All are BSD-style and permissive. See `third_party/` for upstream licenses.

Thanks to [Stuart Gardoll](https://github.com/sgardoll) for the ElevenLabs Flutter library.

This plugin was debugged **entirely from Windows** — no Mac, no Xcode, no Instruments, no Console. Every iOS diagnosis had to come back over a single line of text rendered inside the app. That constraint is why the diagnostic strip exists, and the strip is why the bugs were findable at all.

---

## Contributing

Issues, PRs, device reports, and head-unit test results are all welcome. Bluetooth and automotive audio is a long tail of specific hardware behaving specifically — every real-world data point helps.

If this saved you weeks of debugging, say so. That is exactly why it's here.

---

## License

MIT — Copyright (c) 2026 Six Pages Studio, LLC
