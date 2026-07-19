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
   │   Ring buffer                │   180 s of capacity, because TTS
   │   180 s (5,760,000 bytes)    │   arrives faster than real time
   │                              │   iOS:     lock-free SPSC
   │                              │   Android: writer thread + ring
   └──────────────────────────────┘
                  │
                  ▼
   ┌──────────────────────────────┐
   │   Route ownership            │   iOS:     CallKit + VoiceProcessingIO
   │                              │   Android: Jetpack Core-Telecom
   └──────────────────────────────┘
                  │
                  ▼
                Output
```

On **both** platforms the session is registered as a real call, and the *platform* owns audio routing — the plugin does not drive `setCommunicationDevice` or `overrideOutputAudioPort`. The car, the headset, the speaker: the OS routes to them because it is holding a call, not because the plugin forced a device. That single decision — declare a call, then get out of the way — is what makes cars work and what stopped the routing from fighting itself.

`feedPlayback()` is **fire-and-forget on both platforms**: it hands bytes to the ring and returns immediately. It never blocks the caller, so a long TTS turn cannot freeze your UI. On iOS a render callback drains the ring; on Android a dedicated writer thread does. Different mechanisms, same contract — and on Android that is not a port of the iOS design but the pattern Android's own documentation calls for, since `AudioTrack.write()` blocks and is thread-safe with respect to `stop()`.

The far-end signal is fed back into the canceller, which is why the AI does not transcribe itself while it is speaking.

---

## Features

- **Full-duplex streaming** — mic open while audio plays
- **Native acoustic echo cancellation**
  - Android: WebRTC **AEC3** (software; both far-end and near-end signals fed to it)
  - iOS: **VoiceProcessingIO** (system AEC)
- **The session is a real call, on both platforms** — CallKit on iOS, Jetpack Core-Telecom on Android. Registered at call priority, which is what makes cars, headsets, and screen-off survival work.
- **Bluetooth HFP** — bidirectional, including **automotive** head units
- **Bluetooth A2DP** — output-only devices (headphones, speakers)
- **Wired headsets, USB, and speaker** — the platform selects; the plugin does not override
- **180-second ring buffer** (5,760,000 bytes) — so a TTS turn delivered *faster than real time* never overflows. Lock-free SPSC on iOS; writer thread plus ring on Android.
- **`feedPlayback()` never blocks the caller** — on both platforms it enqueues and returns. Your UI stays responsive for the whole of a reply, which means a stop or mute control is still pressable *while the AI is speaking*.
- **Automatic route following** — audio follows the device the user connects mid-conversation, because the platform owns the route
- **Survives screen lock** — Android foreground service (`microphone` type) + partial wakelock, alongside the Core-Telecom call; iOS background audio
- **Rich diagnostics** — a single-line strip that makes failures legible. This is how the car bug was found.

**Audio format:** PCM16, 16 kHz, mono. 640-byte frames (20 ms).

---

## Platforms

| Platform | Status | AEC | Call framework | Bluetooth HFP | Car |
|---|---|---|---|---|---|
| Android | Supported | WebRTC AEC3 | Jetpack Core-Telecom | Yes | Proven (final routing verification in progress) |
| iOS | Supported | VoiceProcessingIO | CallKit | Yes | Proven |

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

Android routing is owned by **Jetpack Core-Telecom** (`androidx.core:core-telecom`). The session is registered as a real VoIP call via `CallsManager.addCall`, and from that point the framework owns audio mode, focus, and route. The plugin does **not** call `setCommunicationDevice`, does **not** set `MODE_IN_COMMUNICATION`, and does **not** request audio focus — Google's own guidance is explicit that doing so *while a Telecom call is active* causes audio issues, and it did: it produced a constant route-arbitration war where the framework yanked the route back to the earpiece every few seconds.

The rule is the same one that makes iOS work: **declare a call, then get out of the way.** Route selection — car, headset, wired, speaker — is the library's job. Audio follows the endpoint the framework hands us, observed through the `availableEndpoints` / `currentCallEndpoint` flows.

**The one nudge.** There is exactly one place the plugin steers, and it is surgical. Telecom's default for an in-app conversation with nothing else connected is the **earpiece** — correct for a phone call, wrong for a hands-down companion conversation. So when (and only when) the *current* endpoint is the earpiece, the plugin makes a single `requestEndpointChange` to the speaker, once, through Telecom's own sanctioned API. It keys on the *current* endpoint, never on what is merely *available* — an idle smartwatch sitting in the endpoint list as a Bluetooth device is not the route and is correctly ignored. When the car or a headset is the active route, the current endpoint is that device, not the earpiece, so the nudge never fires and the car is never stolen from.

**API floor.** Core-Telecom's `CallsManager` is `@RequiresApi(O)` — API 26. On **API 26+** the Telecom path above owns everything. On **API 24–25** (below the library's floor) there is no Telecom call; the plugin falls back to the legacy `setCommunicationDevice` / `MODE_IN_COMMUNICATION` path, gated, exactly as it worked before. No device loses voice.

**The foreground service.** The plugin ships a `LifecycleService` (so the call's coroutine scope is bound to the service lifetime) that promotes to the foreground with the `microphone` type. On **Android 14+ this is mandatory** — without it the microphone is *silently muted* the moment the app leaves the foreground. The service promotes with `microphone` **only**; Core-Telecom handles the `phoneCall` foreground promotion itself once the call is added. (Asserting `phoneCall` in `startForeground` before the call exists makes Android's `validateForegroundServiceType` reject it and crashes the app — the library owns that promotion, not the app.)

The plugin's manifest declares:

```xml
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
```

`MANAGE_OWN_CALLS` is required by `CallsManager.addCall`. The `phoneCall` and `connectedDevice` foreground types are **declared** so the library can promote them; the plugin's own `startForeground` call still passes `microphone` only.

**Playback runs on its own thread.** `AudioTrack.write()` on a `MODE_STREAM` track is documented **blocking** — it returns only once the bytes are queued to the audio sink, so when the track buffer is full (which, against faster-than-real-time TTS, is most of a turn) the calling thread stalls. If that caller is the Flutter main thread, the UI freezes for the length of the reply: no scroll, no taps, and no way to press a stop or mute control until the audio finishes on its own.

So `feedPlayback()` only enqueues. A dedicated `SixPagesVoicePlayback` thread owns every `write()`. This is Android's own contract, not a design borrowed from iOS: `write()` is thread-safe with respect to `stop()`, and because `write()` blocks it does not make sense to call `pause()` from the writing thread. A writer thread, with `play` / `pause` / `flush` / `stop` driven from another thread, is the sanctioned arrangement — and it is what makes the immediate-stop teardown below actually reachable.

Two details on that thread are load-bearing, and both are about AEC3:

- **`nativeProcessRender` moved with the write, not with the enqueue.** The far-end reference has to reach AEC3 immediately before the bytes reach the speaker. Left on the calling thread it would run ahead of playback by the whole ring depth.
- **`framesWritten` is incremented *after* the write, counting only bytes actually accepted.** It feeds `inFlight = framesWritten - framesPlayed` into `setStreamDelayMs`. Increment it at enqueue time and that figure inflates by the ring depth, sails past the sanity check, and silently corrupts cancellation — no crash, no error, just worse echo.

Teardown order is therefore: stop the writer, clear the ring, join the thread, then `pause()` → `flush()` → `stop()` on the track. `flush()` is a documented no-op unless the track is stopped or paused, so `pause()` must come first; reversing those two lines restores the old "the AI finishes its sentence after you hang up" behaviour and looks like the fix was never made.

**Your app must declare and request `RECORD_AUDIO` itself**, plus `POST_NOTIFICATIONS` (Android 13+) for the foreground-service notification. The plugin does not request these for you.

---

## The car bug

Cars are the reason this plugin exists in its current form, and the failure is not obvious.

When a car opens a Bluetooth **HFP** channel, its state machine expects to be told a **call is in progress**. Not audio — a *call*. It is waiting for the telephony signal (`+CIEV: call=1`).

If the phone never sends that signal, the head unit concludes the link is dead and tears down the SCO uplink — reliably, at about **five seconds**. Audio falls back to the phone speaker, mid-sentence.

The fix is not an audio fix on either platform. It is a **declaration**: tell the OS a real call is happening, and let the OS carry the telephony signaling and own the route.

**On iOS**, that declaration is CallKit:

1. Declare a real call to iOS via **CallKit** (`CXProvider`, `CXCallController`, `CXStartCallAction`).
2. Report the call as *connecting* from inside `provider(_:perform: CXStartCallAction)`, **then** fulfill the action.
3. Let the system activate the audio session at call priority in `provider(_:didActivate:)`. **Do not activate it yourself.**
4. Build the audio unit *there* — once activation has actually happened.
5. Report the call **connected** only once audio is genuinely flowing.
6. **Declare `voip` in `UIBackgroundModes`**, or CallKit refuses the entire transaction as `unentitled` and none of the above ever runs.

Step 6 was missing for six builds. iOS said so, in plain English, every single time — into an `os_log` that cannot be read from Windows.

**Retain your plugin instance.** `addMethodCallDelegate` and `setStreamHandler` both hold their delegate *weakly*. That is harmless while everything is synchronous, but CallKit is callback-driven: the object must still exist when `didActivate` fires later. A `static` strong reference in `register(with:)` is required.

**On Android**, that declaration is Jetpack Core-Telecom. `CallsManager.addCall` registers the VoIP call and the framework does the same job CallKit does on iOS: it holds the call, carries the telephony signaling to the head unit, and owns the route. The car's **End Call** button reaches the app through the `onDisconnect` lambda — a remote surface (head unit, Bluetooth headset, Android Auto) controlling a real call, which is only possible because the OS knows it *is* a call.

This is the same lesson on both platforms, and it is worth stating plainly: **the earlier Android approach tried to drive the route by hand (`setCommunicationDevice` under `MODE_IN_COMMUNICATION`) and lost.** It lost the same way an iOS app loses when it activates its own audio session — it was fighting the system for something the system will only give to a declared call. Declaring the call, on both platforms, is what stopped the fight.

---

## Diagnostics

The plugin maintains a single-line diagnostic strip that makes failures legible. It is the single most valuable thing in this repository.

The strip below is the **iOS** one — CallKit-centric, read back over the method channel because iOS has no console you can reach from Windows. **Android** exposes the equivalent through `logcat` (filter to `SixPagesVoice`): the same discipline — capture state at the moment of a failure — applied to the platform you can actually `adb` into. On the Telecom path, watch `availableEndpoints` / `currentEndpoint` (what the framework offers and routes to) and the `2B-nudge` lines (the one speaker steer), the way you watch `ckTrail` on iOS.

`droppedBytes` exists on **both** platforms now. Android reports it two ways: a throttled warning (~1/sec) while an overflow is actually happening, and a frozen read at teardown before the counter is wiped —

```
SESSION_END playback ring: droppedBytes=0 (no overflow)
```

Also watch the `measured stream delay = N ms (source=TS|HEAD|FALLBACK)` line. It should tick roughly once per second *throughout* a turn, including while the AI is speaking. If it stalls whenever audio plays, something is holding the playback lock across a blocking call and AEC3 is running on a stale delay estimate — which sounds like stuttering and slurring, not like a lock bug.

A healthy automotive run (iOS):

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

**App crashes instantly on session start (Android 14+).**
`validateForegroundServiceType` is rejecting a `phoneCall` foreground promotion made before a Telecom call exists. Do not pass `FOREGROUND_SERVICE_TYPE_PHONE_CALL` to your own `startForeground` — Core-Telecom promotes the call foreground itself. Promote with `microphone` only.

**Audio keeps snapping back to the earpiece; the route fights itself (Android).**
You are driving `setCommunicationDevice` / `MODE_IN_COMMUNICATION` while a Telecom call is active. Don't — the framework owns the route for a declared call, and it will win the arbitration every time. Observe `availableEndpoints` / `currentCallEndpoint` and, if you must steer, use `requestEndpointChange`.

**Audio comes up on the earpiece in-app when it should be the speaker (Android).**
That is Telecom's default for a call with nothing else connected. Nudge to the speaker with a single `requestEndpointChange` keyed on the *current* endpoint being the earpiece — not on what is merely available. An idle smartwatch shows up as an available Bluetooth endpoint and will block a naive "is Bluetooth present" check.

**Playback degrades late in long replies; the tail is missing.**
Ring overflow. `droppedBytes > 0`. Do **not** add priming depth — that makes it worse.

**The UI freezes while the AI is speaking; the stop button cannot be pressed (Android).**
Something is calling `AudioTrack.write()` on the main thread. It blocks — for the length of the reply, against faster-than-real-time TTS. The button is not broken, it is unreachable. Move every `write()` to a dedicated thread and make the enqueue path return immediately.

**Stuttering or slurring on Android, with no dropped bytes and no network fault.**
Check whether the playback lock is held across the `write()`. If it is, the delay measurement on the capture thread blocks behind it for most of every turn, and AEC3 spends the turn working from a stale `setStreamDelayMs`. Hold that lock for the counter update only — never across the blocking call. Confirm with the `measured stream delay` cadence in `logcat`: steady ticks during playback, not silence.

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
