import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import CallKit   // BUILD 19: the missing declaration. See the header.
import os.log
import Darwin  // Build 6: OSMemoryBarrier (acquire/release fence) for the lock-free ring

// ───────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// BUILD 21: THE PLUGIN INSTANCE WAS DEAD. FOUR BUILDS DIED ON TOP OF IT.
//
// Builds 19, 19a, 19b and 20 ALL came back "no session started" on the bare iPad, with
// callKit=none and ckActivates=0. The CallKit architecture (19) was right. The Dart async
// contract (19b) was right. The reportOutgoingCall ordering (20) was right. NONE OF THEM
// EVER RAN, because the object they lived on was deallocated before it could be called.
//
//     register(with:) did:   let instance = SixPagesVoicePlugin()   <- LOCAL let
//
// addMethodCallDelegate() and setStreamHandler() BOTH take their delegate WEAKLY -- that
// is the Cocoa delegation convention, to avoid retain cycles. Nobody held a strong
// reference. ARC destroyed the plugin the instant register() returned.
//
// WHY IT NEVER MATTERED BEFORE: for eighteen builds every path was SYNCHRONOUS. handle()
// ran, startUnit() built the unit, result() fired -- all inside ONE method invocation,
// while Flutter held the object alive. NOTHING EVER NEEDED TO SURVIVE PAST THE END OF A
// METHOD CALL, so a dangling instance was completely invisible.
//
// BUILD 19 MADE THE PLUGIN ASYNCHRONOUS. Asynchronous means the object must still be
// there LATER. CXProvider holds its delegate WEAKLY; a dead delegate can never receive
// provider(didActivate:). The controller.request { [weak self] } completion block's
// `guard let self` FAILED -- which is precisely why callKitState never even advanced to
// "requested".
//
// THE STRIP SAID callKit=none AND THAT WAS THE ANSWER. Not a refused call. A DEAD OBJECT.
// The call was never refused because the call was never made, because there was nobody
// left to make it.
//
// THE FIX: one static strong reference, held for the life of the process.
//
//     private static var retainedInstance: SixPagesVoicePlugin?
//
// This is what every Flutter plugin with async callbacks does, and it is what CallKit's
// own "only create one instance of CXProvider" guidance already assumes: one provider, on
// one long-lived owner. DO NOT REMOVE IT. If it goes, CallKit goes silent again and the
// button dies with no error at all.
//
// THE LESSON, WRITTEN DOWN SO IT IS NOT RE-LEARNED: when a system goes from SYNCHRONOUS
// to ASYNCHRONOUS, object LIFETIME becomes load-bearing for the first time. Every latent
// lifetime bug that was harmless under synchrony becomes fatal under callbacks. The bug
// was eighteen builds old and only Build 19 could ever have exposed it.
//
// NOTHING ELSE MOVED. Build 20's ordering stands (and NOW IT WILL ACTUALLY RUN). CallKit
// architecture (19), async start seam + 4s deadman (19b), setPreferredInput (17), 180s
// ring (11) all intact. setActive(true) still absent from the entire file. NOTHING IN
// DART CHANGED. Android untouched.
//
// READ THE STRIP: callKit=requested or active means the object LIVED and the call was
// made. callKit=none means it is STILL dead and nothing else on the strip means anything.
//
// ───────────────────────────────────────────────────────────────────────────
//
// BUILD 20: THE CALL WAS REPORTED FROM THE WRONG PLACE. ONE VARIABLE.
//
// Build 19 was the right architecture. Build 19b fixed the Dart contract it broke. Both
// were still DEAD -- the Talk button reported "no session started" and ckActivates=0,
// meaning provider(_:didActivate:) NEVER FIRED and the VPIO unit was never built.
//
// THE BUG WAS NOT MISSING -- IT WAS MISPLACED. reportOutgoingCall() was being called
// from inside the CXCallController.request COMPLETION BLOCK in requestStartCall(). That
// is a SECOND, INDEPENDENT ASYNC PATH racing provider(_:perform: CXStartCallAction), and
// NOTHING ORDERS THEM. reportOutgoingCall(connectedAt:) could land BEFORE the action was
// fulfilled -- declaring a call CONNECTED that the provider did not yet consider live.
// The transaction never reached a state the system would elevate. No elevation, no
// didActivate. No didActivate, no audio. Dead button.
//
// Compounding it: startedConnectingAt: nil and connectedAt: nil were fired BACK TO BACK.
// nil means NOW. We declared "connecting" and "connected" in the same instant, from a
// completion block, before a single sample of audio existed.
//
// THE CORRECT SEQUENCE -- this is what every reference CallKit integration does, and the
// order is the whole point:
//
//     1. requestStartCall()                    CXStartCallAction -> CXTransaction
//     2. provider(_:perform: CXStartCallAction)
//            reportOutgoingCall(startedConnectingAt:)   <- BUILD 20: MOVED HERE
//            action.fulfill()                            <- fulfill AFTER reporting
//     3. [system elevates the session to CALL priority]
//     4. provider(_:didActivate:) -> beginAudio()
//            buildAndStartUnit()                         <- audio is REAL now
//            reportOutgoingCall(connectedAt:)            <- BUILD 20: MOVED HERE
//            resolveStart(true)                          <- and NOW Dart is answered
//
// "Connected" now means what the word means: the VPIO unit is running and audio is
// flowing. Not "a completion block returned without an error."
//
// The CXCallController completion handler now has exactly ONE job: notice a REFUSED call.
//
// WHAT DID NOT CHANGE: the CallKit architecture itself (Build 19), the async start seam
// and 4s deadman (Build 19b), setPreferredInput (Build 17), the 180s ring (Build 11).
// setActive(true) is STILL absent from the entire file. NOTHING IN DART CHANGED.
//
// voip BACKGROUND MODE: NOT ADDED, DELIBERATELY. It is chiefly required for VoIP PUSH
// wake-up and receiving calls in the background. This call is user-initiated in the
// foreground. It was the previous session's hypothesis; it is not the first variable to
// move, and editing FlutterFlow's locked Info.plist is the highest-risk edit available.
// If Build 20 comes back with ckActivates=0 STILL, that is when voip earns its turn.
//
// READ THE STRIP: ckActivates=1 means this fix landed. ckActivates=0 means it did not,
// and NO OTHER NUMBER ON THE STRIP MEANS ANYTHING.
//
// ───────────────────────────────────────────────────────────────────────────
//
// BUILD 19: CALLKIT. NOBODY WAS HANGING UP -- NOBODY EVER PICKED UP.
//
// BUILD 18 CAME BACK CASE A, AND IT WAS DECISIVE:
//     captureCalls=266; captureBytes=195776; captureFails=0
//     renderCalls=266            <- IDENTICAL. Input fired on EVERY render cycle.
//     input=bt-hfp; prefIn=ok; route=bt-hfp; routeChanges=1
//     droppedBytes=0; interruptions=0; policyApplies=0; policyFails=0
//
// 195,776 bytes = 97,888 frames @ 16 kHz mono = 6.1 SECONDS of continuous audio pulled
// from the CAR'S OWN MICROPHONE, with ZERO failures, right up to the moment the call died.
//
// THE ENTIRE AUDIO PATH IS EXONERATED. Both directions. Playback perfect, capture perfect,
// routing perfect, no interruptions, no drops, no overrides. Every audio theory is dead.
//
// THE CAR HUNG UP ON A CALL THAT WAS WORKING.
//
// ═══════════════════════════════════════════════════════════════════════════
// THE ANSWER WAS ON ANDROID THE WHOLE TIME
// ═══════════════════════════════════════════════════════════════════════════
//
// Same car. Same app. Same ElevenLabs stream. Android opens a phone call on that dash and
// the car HOLDS IT FOR AS LONG AS SHE WANTS TO TALK. iOS opens a phone call on that same
// dash and the car says "Call ended" after five seconds.
//
// The car is not confused about what we are. It does the IDENTICAL thing on both platforms.
// The difference is what each platform DECLARES.
//
// ANDROID (commit d6d95fa -- the fix that made Android hold the car):
//     requestAudioFocus(USAGE_VOICE_COMMUNICATION, AUDIOFOCUS_GAIN)
//     = "THIS IS A VOICE CALL." The Android telephony/BT stack then holds the SCO link
//       up AS A CALL, and the car is satisfied.
//
// iOS (until this build):
//     ...nothing. We set a category and opened a VPIO unit.
//
// So the Bluetooth stack negotiates HFP (we asked for it), the car opens a call channel
// and puts "Call" on the dash -- but iOS's TELEPHONY layer says NO CALL IS IN PROGRESS.
// The car's HFP state machine waits for the call-status indicator a real phone sends
// (+CIEV: call=1). It never comes. The car concludes the call it opened was never actually
// established, and tears down the orphaned SCO link. Five seconds is the HFP spec's
// answer to exactly that. The dash even says it in plain words: CALL ENDED.
//
// NOBODY WAS HANGING UP ON US. NOBODY EVER PICKED UP.
//
// WE HAVE NOW MADE THIS EXACT MISTAKE TWICE:
//     Android setCommunicationDevice()  <->  iOS setPreferredInput()   -- fixed in Build 17
//     Android requestAudioFocus()       <->  iOS CallKit               -- THIS BUILD
// Both times we built Android's half of the contract and shipped iOS without its half.
// Then spent days deleting output-side code hunting for the missing half. Read Rule 5.
//
// ═══════════════════════════════════════════════════════════════════════════
// THE CONTRACT -- APPLE, WWDC 2016 SESSION 230, VERBATIM
// ═══════════════════════════════════════════════════════════════════════════
//
//     "When using CallKit, you will NO LONGER ACTIVATE your app's audio session directly.
//      Instead you will only CONFIGURE the audio session and THE SYSTEM WILL ACTUALLY
//      ACTIVATE your app's audio session for you AT AN ELEVATED PRIORITY... our audio
//      session will be activated by the system and after that happens, we'll receive a
//      delegate callback called provider(didActivate:). AND THIS IS THE POINT WHERE WE
//      BEGIN PROCESSING OUR CALL'S AUDIO."
//
// ELEVATED PRIORITY is not a footnote. It is WHY the system holds the SCO link up for a
// CALL instead of treating us as a media app that happens to want a microphone.
//
// ═══════════════════════════════════════════════════════════════════════════
// WHAT CHANGED STRUCTURALLY -- READ THIS BEFORE EDITING startUnit()
// ═══════════════════════════════════════════════════════════════════════════
//
// startUnit() is SPLIT IN TWO, and the seam is owned by iOS, not by us:
//
//   PHASE 1 -- startUnit()  [Flutter calls "start"]
//       * configureSession()  : setCategory + mode + preferred rate. NOTHING ELSE.
//                               *** DO NOT CALL setActive(true). THAT IS NOW THE OS'S JOB. ***
//       * requestStartCall()  : CXCallController -> CXStartCallAction. THIS is the
//                               declaration we never made. iOS now drives the HFP state
//                               machine and tells the car a call is really in progress.
//       * ...and then we STOP and WAIT. No VPIO unit yet. No audio yet.
//
//   PHASE 2 -- provider(_:didActivate:)  [iOS calls US, at elevated priority]
//       * beginAudio() : NOW build the VPIO unit, NOW selectPreferredInput(), NOW start.
//                        Everything that used to live after setActive(true) moved here.
//
// isRunning does NOT become true until Phase 2 completes. Flutter's start() returns as
// soon as the call is REQUESTED -- audio follows a beat later, when iOS says go.
//
// TEARDOWN mirrors it: stopUnit() requests CXEndCallAction; audio stops in didDeactivate
// (or immediately, if there is no call to end). endAudio() is idempotent -- BOTH paths
// can reach it and it must survive being called twice.
//
// THE FIRST-LAUNCH TRAP, PRE-EMPTED: multiple Apple Forums threads report didActivate
// sometimes NEVER FIRING on the very first call after launch. Apple's own engineer's
// workaround is to configure the session BEFORE reporting the call, not inside the action
// handler. We do exactly that -- configureSession() runs in startUnit(), ahead of the
// CXStartCallAction -- so we are already on the right side of that bug. If didActivate
// still fails to arrive, callKitDidActivate=0 on the strip says so out loud.
//
// PRIVACY: includesCallsInRecents = false. This app is for someone reaching for it at 3am
// because they have nobody to call. Their reflection sessions do not belong in a call log.
//
// NEW STRIP FIELDS:
//     callKit=      requested | active | ended | none   (the call's own lifecycle)
//     ckActivates=  did provider(didActivate:) ever fire? 0 here means audio NEVER STARTED
//                   and nothing else on the strip is meaningful.
//
// EXPECTED IN THE CAR:
//     The dash call icon appears AND STAYS -- for as long as she wants to talk, exactly
//     like Android. A system call UI appears on the iPad (that is CallKit; it is correct).
//     callKit=active; ckActivates=1; input=bt-hfp; prefIn=ok; route=bt-hfp;
//     captureCalls and renderCalls both climbing; droppedBytes=0; NO override>speaker.
//     AND THE CONVERSATION SURVIVES PAST FIVE SECONDS.
//
// EXPECTED ON A BARE DEVICE (desk): unchanged behavior, plus callKit=active/ckActivates=1.
// A call UI on the iPad with no car is EXPECTED and is not a bug. If ckActivates=0 on the
// DESK, the CallKit seam itself is broken -- fix that before ever driving anywhere.
//
// ---- PRIOR ----------------------------------------------------------------
//
// BUILD 18: DIAGNOSTIC ONLY. IS THE MIC ACTUALLY RUNNING? WE HAVE NEVER LOOKED.
//
// NO BEHAVIOR CHANGE. NOT A FIX. Three counters. Read why before touching anything.
//
// BUILD 17 WORKED. Measured in the car -- the best data this project has ever produced:
//     input=bt-hfp; prefIn=ok; routeAtStart=bt-hfp; route=bt-hfp; routeChanges=1;
//     spkDefault=off; policyApplies=0; policyFails=0; droppedBytes=0;
//     interruptions=0; why=[categoryChange>bt-hfp]   <- NO override>speaker. NONE.
//
// setPreferredInput LANDED, first try. The car's HFP mic was selected. iOS moved the
// output to the matching HFP port exactly as Apple documented. The route was bt-hfp at
// start, bt-hfp at the end, and NEVER MOVED IN BETWEEN. Never interrupted. Never dropped
// a single byte.
//
// AND THE CAR STILL HUNG UP AT FIVE SECONDS.
//
// THAT KILLS EVERY ROUTING THEORY. Builds 14, 15, 16 and 17 were all, in the end, about
// WHO IS MOVING THE OUTPUT ROUTE. The answer is NOBODY. Not iOS, not us. The route is
// correct and stable from the first millisecond to the last, and the drop happens anyway.
// override>speaker -- the symptom we chased for four builds -- IS GONE, AND THE BUG IS
// NOT. It was never the cause. It was iOS calmly falling back to the built-in speaker
// AFTER the car had already hung up. Four builds spent chasing an echo.
//
// SO WHAT IS LEFT? THE UPLINK.
//
// HFP is a bidirectional CALL. The car opened the SCO channel and waits for microphone
// audio to flow UP it. A hands-free unit that receives no uplink frames ENDS THE CALL.
// That is not a bug in the car -- it is what a hands-free unit is SUPPOSED to do with a
// dead call. Five seconds is a textbook watchdog.
//
// AND HERE IS THE HOLE WE HAVE NEVER LOOKED INTO:
//
//     prefIn=ok proves we SELECTED the car's microphone.
//     It proves NOTHING about whether VPIO ever DELIVERED A SINGLE FRAME FROM IT.
//
//     SELECTION IS NOT DELIVERY.
//
// The strip has had renderCalls -- the OUTPUT side -- for ten builds. It has NEVER had a
// single counter on the CAPTURE side. Not one. VPIO's input bus could be handing us
// nothing at all from that HFP mic (never firing, or firing and failing to render) and
// EVERY NUMBER ON THE CURRENT STRIP WOULD LOOK EXACTLY AS IT DOES NOW. We could not tell.
// We cannot tell right now.
//
// Same blindness as Build 13 (the route observer discarded the reason userInfo for WEEKS)
// and Build 16 (routeName collapsed A2DP and HFP into one string, so that build could not
// measure its own hypothesis). Every time: the answer was already in the system, and we
// had no instrument pointed at it.
//
// THE THREE COUNTERS:
//     captureCalls  -- did VPIO's input callback EVER FIRE? renderCalls' missing twin.
//     captureBytes  -- did AudioUnitRender actually PRODUCE AUDIO, or empty frames?
//     captureFails  -- did AudioUnitRender RETURN AN ERROR? The loudest one. That status
//                      is currently returned up the stack and VANISHES -- no log, no
//                      counter, nothing. If VPIO cannot render from the HFP input bus, it
//                      has been failing SILENTLY, inside a real-time callback, on every
//                      drive we have ever taken, and there was NO WAY TO KNOW.
//
// SPLITS THE REMAINING SPACE IN HALF, AND NOBODY HAS TO SPEAK A WORD IN THE CAR. (Amy
// cannot: Joe starts immediately and the call dies at 5s. There is no time for a turn.
// NO TEST MAY DEPEND ON HER TAKING ONE.)
//
//   CASE A -- captureCalls climbing, captureBytes climbing, captureFails=0:
//       THE UPLINK IS ALIVE. Audio flows both ways and the car hangs up anyway. Starvation
//       is NOT the reason. Go look at SCO link LIFETIME -- activation options, .voiceChat
//       vs .videoChat, whether iOS holds SCO up at all. STOP LOOKING AT THE AUDIO PATH.
//
//   CASE B -- captureCalls=0, OR captureBytes frozen, OR captureFails>0, while renderCalls
//             climbs into the hundreds:
//       THE MIC WAS SELECTED BUT NEVER OPENED. Dead uplink. The car's watchdog kills the
//       call at 5s exactly as designed. COMPLETE EXPLANATION, and it points straight at
//       how we configure the input bus.
//
// EXPECTED ON A BARE DEVICE (desk): captureCalls AND captureBytes BOTH CLIMBING,
// captureFails=0. The built-in mic demonstrably works -- this is the CONTROL. It proves
// the counters are wired correctly BEFORE we trust them in a car. IF THE DESK SHOWS
// captureCalls=0, THE INSTRUMENT IS BROKEN, NOT THE CAR. Check that first. Every time.
//
// ---- PRIOR ----------------------------------------------------------------
//
// BUILD 17: ANSWER THE CALL. setPreferredInput -- THE API WE NEVER CALLED. CORRECT, KEPT,
// AND PROVEN IN THE CAR (prefIn=ok, input=bt-hfp, route=bt-hfp, no override anywhere). It
// did not stop the drop, but it is the reason we can now SEE that routing was never the
// problem. DO NOT REVERT IT.
//
// UNTESTED IN A CAR AS OF THIS COMMIT. Build 16's failure is what proved it necessary.
//
// ── WHAT BUILD 16 PROVED (a failure worth its build) ────────────────────────
//
// Build 16 removed .allowBluetooth and set ONLY .allowBluetoothA2DP, on the strength of
// Apple's SDK header: ".playAndRecord: AllowBluetoothA2DP ... allow[s] a paired Bluetooth
// A2DP device to appear as an available route for output, WHILE RECORDING THROUGH THE
// CATEGORY-APPROPRIATE INPUT."
//
// MEASURED: the dash showed the phone call ANYWAY, and it hung up at 5s ANYWAY.
//
// iOS FORCED HFP regardless of the option. The header and the runtime disagree, and the
// runtime wins. When an input is ACTIVE on .playAndRecord, Bluetooth MUST be HFP — A2DP
// is output-only and cannot carry duplex audio, so it is disallowed while recording.
//
// So WE CANNOT REFUSE THE CALL. Which means WE MUST ANSWER IT.
//
// ── THE DIAGNOSIS STANDS. THE FIX INVERTS. ─────────────────────────────────
//
// The car hangs up because the HFP call has a DEAD UPSTREAM. HFP is a bidirectional
// PHONE CALL: the car opens a call channel and expects microphone audio to flow UP it.
// We never sent any — VPIO captured from the BUILT-IN iPad mic while the car's call
// channel sat empty. The car's hands-free stack timed out and DISCONNECTED. Every time.
// Same 5 seconds. `override>speaker` was always the AFTERMATH: iOS falling back to the
// built-in speaker once the call died.
//
// Build 16 tried to decline the call. iOS would not let us. Build 17 PICKS UP.
//
// ── APPLE'S CONTRACT, FROM AN APPLE ENGINEER, VERBATIM ─────────────────────
//
//     "If an application is using setPreferredInput to select a Bluetooth HFP input,
//      THE OUTPUT SHOULD AUTOMATICALLY BE CHANGED TO THE BLUETOOTH HFP OUTPUT
//      CORRESPONDING WITH THAT INPUT."
//
// That is the entire mechanism in one sentence. SELECT THE MICROPHONE, AND THE ROUTE
// FOLLOWS. We never touch the output. We call no override. We select no output port.
// We pick the INPUT — and iOS moves the output to the matching HFP port itself.
//
// This is the SAME IDEA as Android's setCommunicationDevice, which we DO call, which is
// why ANDROID HAS ALWAYS WORKED and iOS never has. We built one half of the pair and
// not the other. The platforms have different APIs for the same contract; we honored
// Android's and never found iOS's.
//
// AND THE ORDERING, ALSO FROM APPLE: "To set the input, the app's session needs to be in
// CONTROL OF ROUTING." setPreferredInput MUST be called AFTER setActive(true). Called
// before activation it is a silent no-op — that is the failure mode in the Apple forum
// thread where the route "clearly has not changed."
//
// ── THIS IS NOT A ROUTE OVERRIDE. DO NOT CONFUSE IT WITH ONE. ──────────────
//
// Every route lever we ever DELETED was an OUTPUT lever: overrideOutputAudioPort
// (c95f26c) and .defaultToSpeaker-at-activation (Build 15). Deleting those was RIGHT
// and they stay deleted. setPreferredInput is an INPUT API — Apple's documented,
// sanctioned way for a .playAndRecord session to choose its microphone. Choosing the
// mic is OUR job. Choosing the output route is iOS's job, and we still do not touch it.
//
// ── WHAT THIS MEANS IN PRACTICE ────────────────────────────────────────────
//
//   - The car's MICROPHONE becomes the input. Joe hears you through the car mic, not
//     the iPad's. In a car this is BETTER: the car mic is aimed at the driver; the iPad
//     is on a seat somewhere. This is what CarPlay does. This is what every hands-free
//     voice app does. It is the correct trade, not a compromise.
//   - Automotive HFP mics are 8 kHz. VPIO resamples internally (Build 4 deleted the
//     AVAudioConverter for exactly this reason), so we still receive 16 kHz frames.
//     Joe HEARS a telephone-grade mic — same as every hands-free system on earth, and
//     what ElevenLabs' STT is built for.
//   - .allowBluetooth is RESTORED, and .allowBluetoothA2DP is KEPT alongside it. Apple:
//     when one device offers both, HFP WINS PRIORITY — which is now EXACTLY what we
//     want. HFP for the car; A2DP still available for an output-only music device.
//   - VPIO's AEC still owns both ends (car mic in, car speaker out). This is the
//     configuration VoiceProcessingIO was DESIGNED for. OPEN QUESTION, stated honestly:
//     AEC quality through a car's HFP loop is unproven for us. If Joe echoes, that is
//     the thing to look at — NOT the routing, which this build is about.
//
// ── DIAGNOSTIC FIX (Build 16 was UNREADABLE and that is on the strip's author) ──
//
// routeName() collapsed .bluetoothA2DP AND .bluetoothHFP into the single string
// "bluetooth" — to match Android's log names. So the ONE FACT Build 16 existed to test
// (which profile did we actually get?) was THE ONE FACT THE STRIP COULD NOT REPORT.
// Same class of error as Build 13's discarded userInfo: a diagnostic that cannot
// distinguish the thing it measures. Now: "bt-hfp" vs "bt-a2dp". Never merge them again.
//
// NEW STRIP FIELDS: input=, prefIn=, and route= now names the PROFILE.
//   input=      what MIC we actually ended up on (the whole ballgame)
//   prefIn=     ok | none | FAILED — did setPreferredInput take?
//
// EXPECTED IN THE CAR:
//     input=bt-hfp; prefIn=ok; route=bt-hfp (or car-audio); spkDefault=off;
//     policyApplies=0; droppedBytes=0; NO override>speaker;
//     THE CALL STAYS UP ON THE DASH AND THE CONVERSATION SURVIVES PAST 5 SECONDS.
//
//     input=mic-builtin WITH the call on the dash = setPreferredInput did not take, and
//     we are back to a dead upstream. That is the failure signature. Read input= FIRST.
//
// EXPECTED ON A BARE DEVICE (desk): unchanged.
//     input=mic-builtin; prefIn=none; route=speaker; spkDefault=on; policyApplies=0.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// BUILD 16: removed .allowBluetooth, A2DP only. iOS forced HFP anyway — the call still
// appeared and still hung up. It PROVED A2DP-output-while-recording does not hold under
// a live input, which is what forced the correct fix. Superseded.
//
// BUILD 15: decided .defaultToSpeaker BEFORE setActive(true); probed via availableInputs.
// Both changes CORRECT and KEPT. Proved .defaultToSpeaker was NOT the override source
// (spkDefault=off + policyApplies=0 + override fired anyway) — which is what pointed at
// HFP in the first place. Superseded in diagnosis, not in code.
//
// WHAT THE USER ACTUALLY SEES (this is the observation that broke the case open,
// and it was never written down until now):
//     Tap Talk -> the CAR'S DASH SHOWS AN INCOMING PHONE CALL. Joe plays through
//     the car speakers. At ~5 seconds THE CALL ENDS on the dash, and Joe continues,
//     uninterrupted, out of the iPad speaker.
//
// The car is not rejecting us. The car HANGS UP ON US. `override>speaker` is the
// AFTERMATH — iOS falling back to the built-in speaker once the call is gone. We
// spent days fixing the fallback and never asked why the call ended.
//
// THE MECHANISM:
//   .allowBluetooth requests HANDS-FREE PROFILE (HFP). HFP is a bidirectional
//   PHONE CALL. The car opens a call channel and expects microphone audio to flow
//   UP it, from the car's mic to us. We never send any: VPIO captures from the
//   BUILT-IN iPad mic. The car's hands-free stack sits on an open call with a dead
//   upstream, times out, and DISCONNECTS. Every time. At the same 5 seconds.
//
// Build 15 was CORRECT — it removed .defaultToSpeaker cleanly and PROVED it:
// spkDefault=off, policyApplies=0, and the override fired ANYWAY. That result is
// what falsified the entire "we are overriding ourselves" theory that Builds 14
// and 15 were both built on. A correct fix to the wrong bug. Its diagnostic value
// was the whole point.
//
// THE FIX — APPLE'S DOCUMENTED CONTRACT, VERBATIM FROM THE CURRENT SDK HEADER:
//
//     "AVAudioSessionCategoryPlayAndRecord: AllowBluetoothA2DP defaults to false,
//      but can be set to true, allowing a paired Bluetooth A2DP device to appear as
//      an available route for OUTPUT, WHILE RECORDING THROUGH THE CATEGORY-
//      APPROPRIATE INPUT."
//
// That is EXACTLY our use case, in Apple's own words: A2DP out, built-in mic in,
// under .playAndRecord. It is not a workaround. It is the supported configuration.
//
// And the priority rule that explains everything that came before:
//
//     "In cases where a single Bluetooth device supports both HFP and A2DP, the HFP
//      ports will be given HIGHER PRIORITY for routing."
//
// So: A2DP OUT (.allowBluetoothA2DP), HFP GONE (.allowBluetooth REMOVED). With no
// HFP there is NO CALL TO HANG UP. No dash phone icon. Nothing to time out. The car
// takes Joe as MEDIA — which is what he is — over the stereo A2DP link.
//
// STILL A REMOVAL, and the cleanest one yet: we are DELETING the request for a phone
// call we never intended to make.
//
// ── THE A2DP RECORD, CORRECTED. READ THIS BEFORE "PUTTING IT BACK." ──────────
//
// Build 10 deleted .allowBluetoothA2DP and the handoff credits that with fixing the
// "tin-can" sound. By Apple's OWN priority rule above, that attribution CANNOT be
// right: the category still contained .allowBluetooth afterward, so HFP still won,
// so the profile did not change. The tin-can sound WAS HFP — 8 kHz mono narrowband —
// and it was HFP both before and after that deletion.
//
// A2DP was ALSO blamed for the chopped/dropped Joe audio. It was not that either.
// The chop was a RING-BUFFER OVERFLOW, proven by arithmetic, in OUR OWN code:
//     ring 960,000 B + droppedBytes 645,178 B = 1,605,178 B = 50.2 s = ONE JOE TURN.
// Build 11 grew the ring to 180 s and droppedBytes went to ZERO. A2DP is DOWNSTREAM
// of the ring — it transports audio the render callback has ALREADY drained. It
// cannot reach back up the pipe and delete bytes. There is no mechanism. The two
// were never connected; they were correlated on one night when several things changed.
//
// THE HONEST POINT: we have NEVER ONCE TESTED A2DP AS THE ACTIVE PROFILE. Every
// prior run had .allowBluetooth in the category, so HFP always won on priority.
// Every conclusion drawn about "A2DP failing" was drawn from runs where A2DP WAS
// NEVER THE ROUTE. This build tests it for the first time.
//
// RISKS, NAMED (both visible in ONE drive, on the strip):
//   1. iOS may force HFP anyway when an input is active, ignoring the option. If so,
//      the dash call icon RETURNS and we are back where we started. Measurable.
//   2. droppedBytes is on the same strip. If A2DP somehow correlates with the chop —
//      it should not, per the arithmetic above — we will SEE it, not guess at it.
//
// EXPECTED IN THE CAR:
//     NO phone-call icon on the dash. NO call to end.
//     routeAtStart=bluetooth; route=bluetooth; spkDefault=off; policyApplies=0;
//     droppedBytes=0; NO override>speaker; and the conversation SURVIVES PAST 5s.
//     Joe should also sound BETTER than he ever has in the car — stereo A2DP
//     instead of an 8 kHz call channel.
//
// EXPECTED ON A BARE DEVICE (desk): unchanged from Build 15.
//     route=speaker; spkDefault=on; policyApplies=0.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// BUILD 15: decided .defaultToSpeaker BEFORE setActive(true) and probed via
// availableInputs so the output override could not corrupt the answer. Both changes
// are CORRECT and are KEPT. It proved .defaultToSpeaker was NOT the override source
// (spkDefault=off + policyApplies=0 + override fired anyway) — which is precisely
// what pointed at HFP. Superseded only in its diagnosis, not in its code.
//
// MEASURED (iPad, in a car, Build 14):
//     routeAtStart=bluetooth; route=speaker; routeChanges=2;
//     spkDefault=on; policyApplies=2; policyFails=0;
//     why=[categoryChange>bluetooth | override>speaker]
//     droppedBytes=0; interruptions=0; renderCalls=623
//
// Build 14 was RIGHT about the mechanism and WRONG about the moment. It correctly
// identified .defaultToSpeaker as the sole source of override>speaker (we make no
// overrideOutputAudioPort call — c95f26c deleted it). But it set the category with
// .defaultToSpeaker ON, called setActive(true), and only THEN ran the policy.
//
// THAT ORDERING IS THE BUG. setActive(true) with .defaultToSpeaker standing in the
// category IS what fires override>speaker. The car is taken away DURING ACTIVATION,
// before any policy can possibly run. Build 14's own comment called this "a brief
// moment on the speaker" and accepted it as the fail-safe cost. It was never brief.
// It was the entire failure.
//
// SECOND DEFECT, COMPOUNDING THE FIRST: hasExternalOutput() read currentRoute.outputs
// — THE VERY THING THE OVERRIDE STEALS. So the post-activation policy asked "is a car
// here?" AFTER the override had already answered "no," saw `speaker`, concluded we
// were alone, and LEFT .defaultToSpeaker ON. The policy read the aftermath of its own
// bug and reinforced it. A feedback loop that stabilizes on exactly the wrong state.
// That is policyApplies=2 and spkDefault=on.
//
// THE FIX — TWO PARTS, ONE IDEA: ASK THE QUESTION WHILE THE ANSWER STILL MEANS SOMETHING.
//
//   1. hasExternalOutput() now reads availableInputs FIRST. A paired car or headset
//      exposes a carAudio/bluetoothHFP INPUT port whether or not it is currently the
//      OUTPUT. availableInputs is NOT on the output path, so an output override cannot
//      corrupt it — and it is VALID BEFORE setActive(true), which currentRoute is not.
//      currentRoute.outputs is kept as an ADDITIVE second source (wired headphones have
//      no mic and expose no input). Either being true means "not alone."
//
//   2. startUnit() DECIDES .defaultToSpeaker BEFORE setActive(true), not after. If a car
//      is present, .defaultToSpeaker is never in the category at the moment the session
//      goes live. There is no override to fire and nothing to chase. The post-activation
//      applySpeakerPolicy(reason: "start") call is DELETED — it existed only to clean up
//      a mess we now never make.
//
// The route observer's applySpeakerPolicy() call STAYS. It is still correct and now
// handles the mid-drive case (car connects after Talk was tapped) with an honest probe.
//
// THE BARE-iPHONE CONSTRAINT IS UNCHANGED AND STILL BINDING:
//   - VPIO requires mode .voiceChat (platform AEC only exists in voiceChat — and AEC is
//     the entire reason this plugin exists; mode .default kills it).
//   - In .voiceChat, a bare iPhone with no accessory routes output to the RECEIVER, not
//     the speaker. .defaultToSpeaker is the ONLY thing preventing that.
//   - THE iPAD HAS NO EARPIECE. That bug is INVISIBLE on our only test device.
//   On a bare device externalAtStart=false, so .defaultToSpeaker goes into the category
//   exactly as it always has. Nothing changes for the common case.
//
// STILL A REMOVAL. We select no route and call no override. We remove OUR OWN standing
// override BEFORE it can fire, so iOS can do its job. Every iOS fix that ever worked
// was a removal. This one removes it one step earlier than Build 14 did.
//
// DANGER, UNCHANGED: setCategory() fires a routeChange(categoryChange) which RE-ENTERS
// the observer which calls the policy again. The `wanted != speakerDefaultOn` guard in
// applySpeakerPolicy is the ONLY thing that terminates that loop. DO NOT REMOVE IT.
// speakerDefaultOn is a MIRROR of the live category and is now set inside startUnit()'s
// do-block to match whatever we actually passed to setCategory. If it ever lies, the
// guard lies, and we either loop forever or no-op forever.
//
// EXPECTED IN THE CAR:
//     routeAtStart=car-audio (or bluetooth); route=car-audio (or bluetooth);
//     routeChanges=1; spkDefault=off; policyApplies=0; policyFails=0;
//     why=[categoryChange>car-audio]   and NO `override>speaker` ANYWHERE.
//
// policyApplies=0 IS THE TELL. The category was correct from the start, so the policy
// had nothing to fix. If policyApplies >= 1 we are still CHASING the route, not LEADING it.
//
// EXPECTED ON A BARE DEVICE (desk):
//     routeAtStart=speaker; route=speaker; spkDefault=on; policyApplies=0.
//     On a bare iPHONE specifically: route=speaker, NOT earpiece. This is the one
//     regression this change could cause and it CANNOT BE SEEN ON THE iPAD.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// BUILD 14: .defaultToSpeaker identified as the override source; policy re-evaluated on
// every route change. Correct mechanism, wrong moment — applied AFTER setActive(true) and
// read a currentRoute the override had already corrupted. TESTED IN CAR, FAILED. It
// retired three risks and produced the data that found the real bug. Superseded by Build 15.
//
// MEASURED (iPad, in a car):
//     routeAtStart=bluetooth; route=speaker; routeChanges=2;
//     why=[categoryChange>bluetooth | override>speaker]
//
// WE GET THE CAR. THEN WE TAKE IT AWAY FROM OURSELVES. `override` has exactly one source
// in AVFoundation, and this plugin makes no overrideOutputAudioPort call — c95f26c deleted
// it. The only remaining mechanism is the .defaultToSpeaker CATEGORY OPTION, set once in
// startUnit() and never revisited. The car finishes negotiating, iOS re-evaluates, our
// standing .defaultToSpeaker reasserts, and the car is gone. ~5 seconds in. Every time.
//
// THE FIX IS NOT TO DELETE IT. That would ship a broken iPhone, and we would never see it:
//   - VPIO requires mode .voiceChat (platform AEC only exists in voiceChat — and AEC is
//     the entire reason this plugin exists; mode .default kills it).
//   - In .voiceChat, a bare iPhone with no accessory routes output to the RECEIVER, not
//     the speaker. .defaultToSpeaker is the ONLY thing preventing that.
//   - THE iPAD HAS NO EARPIECE. The bug would be INVISIBLE on our only test device.
//
// One flag, two contradictory requirements:
//     alone               -> .defaultToSpeaker REQUIRED  (or iPhone -> earpiece)
//     car/headset present -> .defaultToSpeaker POISONOUS (it overrides the route away)
//
// A flag set ONCE cannot satisfy both. That is the bug — not the flag, but the fact that
// we set it at startup and never looked at it again. So: re-evaluate on every route change.
// Drop it when a real output device appears; restore it when we are bare again. See
// applySpeakerPolicy(). Apple's header says VPIO auto-manages CarAudio and BluetoothHFP.
// It always could. We were overriding it. Again.
//
// STILL A REMOVAL. We select no route and call no override. We remove OUR OWN standing
// override so iOS can do its job. Hands-off, correctly applied.
//
// DANGER: setCategory() fires a routeChange(categoryChange) which RE-ENTERS the observer
// which calls the policy again. The `wanted != speakerDefaultOn` guard in applySpeakerPolicy
// is the ONLY thing that terminates that loop. DO NOT REMOVE IT.
//
// New strip fields: spkDefault, policyApplies, policyFails.
// EXPECTED IN THE CAR: why=[... | categoryChange>bluetooth], route=bluetooth, spkDefault=off,
// policyApplies=1, policyFails=0, and NO `override>speaker` anywhere.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// BUILD 13: THE ROUTE OBSERVER WAS THROWING AWAY THE ANSWER.
//
// MEASURED IN THE CAR (iPad, July 12): interruptions=0; resumeFails=0; route=speaker;
// renderCalls=758; droppedBytes=0.
//
// READ THAT CAREFULLY, IT KILLS TWO THEORIES AT ONCE:
//
//   1. THE CAR DOES NOT INTERRUPT US. interruptions=0. Build 12's theory was WRONG.
//      Keep the interruption handler — Apple requires it and it will matter for phone
//      calls and Siri — but it is NOT the car mechanism. Do not rebuild that theory.
//
//   2. THE SESSION NEVER DIES. renderCalls=758, droppedBytes=0, no teardown. What the
//      user hears as "the call dropped after 5 seconds" is NOT a drop. It is a ROUTE
//      CHANGE: iOS moves the output off the car and back to the built-in speaker while
//      the session keeps happily rendering. route=speaker. The audio is fine. It is
//      just coming out of the wrong hole.
//
// It is also NOT A2DP. The car failed to hold on a build that HAD .allowBluetoothA2DP
// and on this one that does not. A2DP is not the variable. Do not put it back.
//
// SO WHY DOES iOS MOVE THE ROUTE? We have never known — because THIS FILE HAS BEEN
// DELETING THE ANSWER. The route observer took the notification as `_` and ignored
// userInfo, which carries AVAudioSessionRouteChangeReasonKey. iOS NAMES THE CAUSE of
// every route change and we threw it away every single time, then spent nights
// guessing at what it had already told us plainly.
//
// This build captures it: routeAtStart, routeChanges, and why=[reason>destination, ...]
// go ON THE STRIP — the only iOS instrument that exists in this workflow (Windows,
// TestFlight, no Mac, no Console.app). A counter that is not on the strip does not exist.
//
// The reasons are NOT equivalent and point at completely different fixes:
//   oldDeviceUnavailable        — the CAR dropped us; the fight is with its HFP link.
//   noSuitableRouteForCategory  — .playAndRecord cannot live on that route at all.
//   categoryChange              — WE did it to ourselves.
//   override                    — someone called overrideOutputAudioPort. Should be NOBODY.
// Guessing between these has already cost this project multiple nights. Stop guessing.
//
// Diagnostic-only. No behavior change. Nothing routes, nothing overrides.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// BUILD 12: INTERRUPTION HANDLING. THE CONTRACT WE NEVER IMPLEMENTED.
// (Correct and kept — but NOT the car bug. interruptions=0 in the car, measured.)
//
// Symptom: connect the iPad to a CAR over Bluetooth, the call opens and then DROPS
// about four seconds later. Android showed the same shape (see its focus commit).
//
// This file registered a route-change observer and NOTHING ELSE. It never observed
// AVAudioSession.interruptionNotification. Apple documents interruption handling as
// MANDATORY for a .playAndRecord session: on .began the OS suspends your audio unit,
// on .ended you are expected to reactivate. A car head unit negotiating HFP routinely
// fires exactly that pair within seconds of connecting. Unhandled, the OS stopped our
// unit and nobody ever restarted it — the session opened, then died. Precisely the
// reported symptom, and precisely the delay.
//
// READ THIS BEFORE CALLING IT A ROUTING CHANGE. It is not one:
//   - Route CONTROL is iOS's job. We deleted overrideOutputAudioPort (c95f26c) and
//     .allowBluetoothA2DP (Build 10) and were right both times. Hands OFF the route.
//   - Interruption RESPONSE is OUR job. Apple says so. Not implementing it is us
//     FAILING the platform's contract, not respecting it. Opposite direction, same rule.
//
// The restraint is deliberate and is the whole lesson of this repo:
//   .began  — count it, log it, do nothing. We do NOT stopUnit(): that would dispose
//             the unit and clear the 180 s ring. We want to RESUME, not restart.
//   .ended  — resume ONLY if the system grants .shouldResume. If it does not, the
//             interruptor still owns the audio session, and forcing our way back in
//             is exactly the kind of override that has broken this file before.
//             We stand down and log it.
//
// Diagnostics: interruptionCount / interruptionResumeFailures. The car drive is the
// instrument. If "Interruption BEGAN" never fires, the diagnosis was wrong and we
// look elsewhere WITH DATA instead of guessing. Unproven in a car as of this commit.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// STEP B, LAYER 14 (BUILD 11): THE RING WAS TOO SMALL FOR THE TURN.
//
// THE ANSWER, after a long night of wrong theories. It is not the route listener, not
// A2DP, not the jitter buffer, not echo, not a duplicate feed. It is the oldest and
// simplest failure in this file, and this repo has now hit it THREE times:
//
//   THE RING CANNOT HOLD A WHOLE JOE TURN, SO THE END OF THE TURN IS THROWN AWAY.
//
// MEASURED (iPad, July 12, ONE tap of Talk with Claude — confirmed against the
// ElevenLabs conversation list: 1 conversation, 1m19s, 3 messages, so NO double feed):
//   droppedBytes = 645178  -> 20.2 s of Joe's audio DELETED before it ever played
//   ring         = 960000  -> 30.0 s capacity
//   960000 + 645178 = 1605178 B = 50.2 s = EXACTLY ONE JOE TURN
//   underruns=4/3117 (0.13%, healthy).  maxRenderUs=42 vs a 23000 deadline (innocent).
//   BY EAR: playback stopped DEAD mid-sentence at "It's almost like..." — precisely
//   where 30 s of buffered audio ran out. Everything after that was already discarded.
//
// ElevenLabs ships a turn FASTER THAN REALTIME. The render callback drains at speech
// rate. So a 50 s turn pours into a 30 s ring in a few seconds; the drop-NEWEST overflow
// policy discards the excess — and drop-newest means it deletes THE END OF WHAT JOE WAS
// ABOUT TO SAY. There is no backpressure: feedPlayback is fire-and-forget by design.
//
// WHY IT LOOKED LIKE A REGRESSION AND WASN'T: nothing broke. Joe's replies simply GREW
// PAST 30 SECONDS. The July 9 "perfect" conversation had shorter turns that fit. The
// droppedBytes=0 that was treated as a baseline was never captured on that conversation
// (the app was closed before reading it) — so the buffer may have been dropping all
// along, just not enough to hear.
//
// FIX: raise the ring to 180 s (5_760_000 B, 5.49 MB). NOT 60 s — the measured turn was
// already 50 s, and a 60 s ring truncates the next slightly-longer reflection. Joe is a
// REFLECTION companion; long considered replies are the PRODUCT, not an edge case.
// 5.49 MB is trivial on an iPad and is allocated once per session.
//
// EVERYTHING ELSE IS BYTE-IDENTICAL TO 7abeb0a (the last known-good build). The prime
// cushion stays 3200 B (100 ms) — it is a min() against half the ring, so growing the
// ring does not move it. The ONE other change is an OBSERVE-ONLY route listener that
// logs and steers NOTHING.
//
// ── HARD-WON RULES. READ BEFORE CHANGING ANYTHING IN THIS FILE. ──────────────
//
// 1. DIAGNOSTIC READ ORDER: droppedBytes FIRST. >0 means OVERFLOW — the ring is too
//    small and Joe's later audio is being deleted. That is a COMPLETE explanation of
//    "degrades late in long replies" and "the ending is missing." Look no further.
//
// 2. LOW UNDERRUNS + BAD AUDIO = OVERFLOW, NOT STARVATION. This signal has now been
//    misread three times. ElevenLabs OUTRUNS the drain, always. The ring's natural
//    failure is overflow. NEVER answer it with a deeper cushion or a rebuffer gate:
//    those PAUSE THE DRAIN and make overflow WORSE. (See ea45974, tried and superseded
//    by eb1be7a; then re-made as Build 9 (01fd01a), which caused droppedBytes=913270.)
//
// 3. maxRenderUs ~25-42 against a 23000 deadline means the render callback is using
//    ~0.1% of its budget and is INNOCENT. This number exists to STOP WRONG FIXES.
//
// 4. EVERY iOS FIX THAT HAS EVER WORKED HERE WAS A REMOVAL:
//      Build 4 deleted the AVAudioConverter  — VPIO already resamples internally.
//      c95f26c deleted overrideOutputAudioPort — VPIO already manages BT/car routing.
//      Build 10 deleted .allowBluetoothA2DP  — VPIO already handles Bluetooth.
//    Android's AudioManager EXPECTS the app to drive the route. iOS does NOT. Importing
//    the Android mechanism across that boundary is what caused the ae4e8e2 regression.
//
// 5. DO NOT "optimize" the ring back down. Read droppedBytes. It must be 0.
//
// UNCHANGED and CORRECT: lock-free SPSC ring, memcpy copies, VPIO 16k internal resample,
// the priming gate, the capture path, and the ENTIRE Android side.
// ───────────────────────────────────────────────────────────────────────────
//
// Frame contract mirrors Android exactly: PCM16 / 16 kHz / mono, 640-byte
// (20 ms) frames, one frame pushed per hop to the platform thread — the iOS
// equivalent of Android's `mainHandler.post { eventSink.success(frame) }`.
//
// Deliberately ABSENT vs Android: no nativeProcessCapture, no stream-delay
// measurement, no playback-clock reads. Android needs those because WebRTC
// AEC3 must be told the render→capture delay. iOS's VoiceProcessingIO cancels
// inside the OS, so the pulled frames are already clean. This simplicity is
// the whole reason Path 1 (VoiceProcessingIO) was chosen (July 7 lock).
//
//   • start        → Layer 2 + installs the input callback; starts drain.
//   • feedPlayback → writes Joe's bytes into the playback ring buffer (Layer 2).
//   • capture      → emits clean 640-byte PCM16 frames.
//   • stop         → tears down unit, stops drain, clears both ring buffers.
//
// July 7 risk 3: AECAudioStream's input callback returns kAudio_ParamError even
// on success. We return noErr correctly on the success path.
// ───────────────────────────────────────────────────────────────────────────

// MARK: - ByteRingBuffer (Build 6 / Layer 10: LOCK-FREE SPSC)
//
// WHY THIS EXISTS (the fix that took 7 tries to reach): the render callback runs
// on the real-time audio thread with a hard ~23 ms deadline. The previous version
// guarded every read/write with an NSLock. While ElevenLabs streamed a turn,
// feedPlayback (Dart thread) hammered that lock; whenever a write held it at the
// moment the render callback needed it, the AUDIO THREAD BLOCKED WAITING → missed
// its deadline → the unit got silence → glitch. The instant the stream stopped,
// no contention, callback always got the lock → smooth. That "choppy while audio
// streams, smooth once it stops" is the textbook signature of PRIORITY INVERSION
// from taking a lock on the audio thread — documented by Ross Bencina ("Real-time
// audio programming 101"), Timur Doumler, and Android's own audio docs, which note
// it manifests as "repeated audio when circular buffers are used" (our overlap) and
// dropouts (our skip). Bigger buffers (Builds 3 & 5) only MASKED it — Android's docs
// say so explicitly. The real cure is: the audio thread must NEVER block.
//
// Android doesn't have this problem because its playback writes straight to an OS
// AudioTrack (no app-side render callback pulling from a shared ring). iOS can't
// copy that: Joe's playback MUST pass through the VoiceProcessingIO render callback
// so the OS can echo-cancel it. So iOS needs a lock-free hand-off to that callback.
//
// DESIGN — strict single-producer / single-consumer, lock-free:
//   • Playback: producer = feedPlayback (Dart thread); consumer = render callback.
//   • Capture:  producer = input callback; consumer = drain timer.
//   Both are SPSC — the ONLY safe case for a simple lock-free ring.
//   • Two free-running counters. The PRODUCER owns writeIndex and only ever
//     advances it (atomic release-store after copying data). The CONSUMER owns
//     readIndex and only ever advances it (atomic release-store after copying).
//   • Each side reads the OTHER's counter with an atomic acquire-load. Acquire/
//     release ordering guarantees the bytes are visible before the index that
//     publishes them. No thread ever waits on the other. The render callback can
//     ALWAYS make progress within its deadline.
//   • Overflow policy CHANGED from "drop oldest" to "drop NEWEST (write only what
//     fits)". Drop-oldest required the producer to advance readIndex, which would
//     violate SPSC. With Build 5's full-turn (15 s) ring, overflow effectively
//     never happens for a normal turn; if an over-long turn ever filled it,
//     discarding the newest tail is safe and glitch-free.
//
// Uses Swift's atomics via UnsafeAtomic on raw Int storage — no Foundation lock,
// nothing that can block, allocation-free on the hot path.
private final class ByteRingBuffer {
  private var storage: [UInt8]
  private let capacity: Int

  // Free-running counters (monotonic, wrap via modulo on access). writeIndex is
  // written ONLY by the producer; readIndex ONLY by the consumer. Each is read by
  // the other side with acquire ordering. Stored as atomics so publication of the
  // data (release store) happens-before the other thread observes the new index.
  private let writeIndex: UnsafeMutablePointer<Int>
  private let readIndex: UnsafeMutablePointer<Int>

  // Build 7: total bytes DROPPED because the ring was full when a write arrived
  // (drop-newest overflow). Producer-only writes; read for diagnostics. If this is
  // > 0 after a turn, the ring filled mid-turn and discarded Joe's later audio —
  // the direct measure of "starts great, stumbles mid/late." Plain counter (coarse
  // diagnostic, not correctness-critical).
  private let droppedBytesPtr: UnsafeMutablePointer<Int>
  var droppedBytes: Int { return droppedBytesPtr.pointee }

  init(capacityBytes: Int) {
    self.capacity = capacityBytes
    self.storage = [UInt8](repeating: 0, count: capacityBytes)
    self.writeIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    self.readIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    self.droppedBytesPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    self.writeIndex.initialize(to: 0)
    self.readIndex.initialize(to: 0)
    self.droppedBytesPtr.initialize(to: 0)
  }

  deinit {
    writeIndex.deinitialize(count: 1); writeIndex.deallocate()
    readIndex.deinitialize(count: 1); readIndex.deallocate()
    droppedBytesPtr.deinitialize(count: 1); droppedBytesPtr.deallocate()
  }

  // Bytes currently available to read. Safe to call from either thread.
  var count: Int {
    let w = _load(writeIndex)
    let r = _load(readIndex)
    return w - r
  }

  // ── Atomic helpers (acquire load / release store) ─────────────────────────
  // OSAtomic is deprecated but the memory-barrier free-functions remain the
  // simplest portable acquire/release primitives available without importing the
  // Swift Atomics package (which the plugin does not depend on). A full barrier
  // is stronger than needed but always correct and costs a single fence.
  @inline(__always) private func _load(_ p: UnsafeMutablePointer<Int>) -> Int {
    let v = p.pointee
    OSMemoryBarrier() // acquire: no later read/write is reordered before this
    return v
  }
  @inline(__always) private func _store(_ p: UnsafeMutablePointer<Int>, _ v: Int) {
    OSMemoryBarrier() // release: all prior writes (the data) publish before index
    p.pointee = v
  }

  /// Producer: append bytes. On overflow, drop the NEWEST excess (write only what
  /// fits) so the producer never touches readIndex — preserving SPSC safety.
  func write(_ bytes: UnsafeRawBufferPointer) {
    let n = bytes.count
    guard n > 0 else { return }
    write(from: bytes.baseAddress!, count: n)
  }

  /// Producer variant writing from a raw pointer + length (used by the input
  /// callback, which holds an AudioBuffer's mData/mDataByteSize).
  func write(from ptr: UnsafeRawPointer, count n: Int) {
    guard n > 0 else { return }
    let src = ptr.assumingMemoryBound(to: UInt8.self)
    let w = writeIndex.pointee          // producer owns writeIndex — plain read ok
    let r = _load(readIndex)            // acquire the consumer's progress
    let used = w - r
    let free = capacity - used
    if free <= 0 {
      droppedBytesPtr.pointee += n   // fully full: entire write dropped
      return
    }
    let toCopy = min(n, free)
    if toCopy < n { droppedBytesPtr.pointee += (n - toCopy) } // partial drop
    let wi = w % capacity
    // Build 8: bulk memcpy instead of byte-by-byte. Circular buffer may wrap, so
    // copy in up to two contiguous segments. memcpy on the audio-adjacent path is
    // far faster than a Swift per-byte loop — the loop could blow the render
    // deadline deep in a long turn.
    let firstLen = min(toCopy, capacity - wi)
    storage.withUnsafeMutableBytes { dstRaw in
      let dst = dstRaw.baseAddress!
      memcpy(dst.advanced(by: wi), src, firstLen)
      if toCopy > firstLen {
        memcpy(dst, src.advanced(by: firstLen), toCopy - firstLen)
      }
    }
    _store(writeIndex, w + toCopy)      // release: publish data, then new index
  }

  /// Consumer: pull up to `count` bytes into `dest`. Returns bytes provided.
  func read(into dest: UnsafeMutableRawPointer, count: Int) -> Int {
    let r = readIndex.pointee           // consumer owns readIndex — plain read ok
    let w = _load(writeIndex)           // acquire the producer's progress
    let available = min(count, w - r)
    if available <= 0 { return 0 }
    let d = dest.assumingMemoryBound(to: UInt8.self)
    let ri = r % capacity
    // Build 8: bulk memcpy, up to two segments for the circular wrap. This runs on
    // the REAL-TIME audio thread every render callback — a per-byte loop here was
    // the suspected cause of chop late in long turns (loop time growing with the
    // copy size until it exceeded the ~23 ms deadline). memcpy is O(n) but orders
    // of magnitude faster in constant terms.
    let firstLen = min(available, capacity - ri)
    storage.withUnsafeBytes { srcRaw in
      let base = srcRaw.baseAddress!
      memcpy(d, base.advanced(by: ri), firstLen)
      if available > firstLen {
        memcpy(d.advanced(by: firstLen), base, available - firstLen)
      }
    }
    _store(readIndex, r + available)    // release: publish consumption
    return available
  }

  /// Consumer variant: pull exactly `n` bytes as a Data if available, else nil.
  /// Used by the capture drain to emit whole 640-byte frames only.
  func readFrame(_ n: Int) -> Data? {
    let r = readIndex.pointee
    let w = _load(writeIndex)
    guard (w - r) >= n else { return nil }
    var out = Data(count: n)
    out.withUnsafeMutableBytes { raw in
      let d = raw.bindMemory(to: UInt8.self).baseAddress!
      let ri = r % capacity
      let firstLen = min(n, capacity - ri)
      storage.withUnsafeBytes { srcRaw in
        let base = srcRaw.baseAddress!
        memcpy(d, base.advanced(by: ri), firstLen)
        if n > firstLen {
          memcpy(d.advanced(by: firstLen), base, n - firstLen)
        }
      }
    }
    _store(readIndex, r + n)
    return out
  }

  /// Reset. NOT lock-free-safe against concurrent access — only call when the
  /// audio unit is stopped (start()/stop() paths), never mid-stream. Matches the
  /// previous clear()'s contract (it was only called from stop/start).
  func clear() {
    _store(writeIndex, 0)
    _store(readIndex, 0)
    droppedBytesPtr.pointee = 0
  }
}

public class SixPagesVoicePlugin: NSObject, FlutterPlugin {

  private static let log = OSLog(subsystem: "com.sixpages.six_pages_voice", category: "SixPagesVoice")

  private var ioUnit: AudioUnit?
  private var isRunning = false

  // ══ BUILD 19: CALLKIT ═════════════════════════════════════════════════════
  // The declaration we never made. Android says "this is a voice call" via
  // requestAudioFocus(USAGE_VOICE_COMMUNICATION). iOS says it via CallKit. Without it,
  // the car opens an HFP call, waits for a call-status indicator that never arrives, and
  // tears down the orphaned SCO link after five seconds. See the header.
  private var callProvider: CXProvider?
  private var callController: CXCallController?
  private var currentCallUUID: UUID?

  /// Lifecycle of the CALL, not of the audio. Distinct from isRunning on purpose:
  /// between "requested" and "active" the call exists and the audio does NOT.
  private var callKitState = "none"        // none | requested | active | ended
  private var callKitActivateCount = 0     // did provider(didActivate:) EVER fire?

  // ══ BUILD 19b: THE ASYNC SEAM ═════════════════════════════════════════════
  // Build 19 BROKE THE DART CONTRACT and it took a dead button to find out.
  //
  // Dart's voiceSendMic() does:  final bool ok = await _voice.start();
  //                              if (!ok) { ...bail... }
  // and then voiceConnectTest() immediately sets _voicePlaybackReady = true and starts
  // shoving Joe's audio at feedPlayback().
  //
  // That contract is: WHEN start() RESOLVES TRUE, THE ENGINE IS RUNNING.
  //
  // For eighteen builds startUnit() was SYNCHRONOUS and honored it. Build 19 made it
  // ASYNCHRONOUS -- it now configures the session, asks CallKit for a call, and RETURNS,
  // with the VPIO unit built later inside provider(didActivate:). But it still answered
  // result(true) immediately. So Dart was told "engine ready," began feeding a plugin
  // with NO AUDIO UNIT, and captureStream had nothing to emit. Dead button.
  //
  // I changed the lifecycle and never checked the caller. That is the whole bug.
  //
  // THE FIX -- HONOR THE CONTRACT INSTEAD OF REWRITING DART TO MATCH MY MISTAKE:
  // hold the FlutterResult and do not answer it until didActivate has actually fired and
  // beginAudio() has the unit running. start() becomes genuinely async on the wire, and
  // Dart's `await` does exactly what it always did. NOTHING IN DART CHANGES.
  //
  // A TIMEOUT IS MANDATORY, NOT OPTIONAL. If didActivate never arrives -- the documented
  // first-launch CallKit bug -- an unanswered FlutterResult hangs the Dart future FOREVER
  // and the button is dead with no error. Fail LOUDLY at 4s: result(false), which Dart
  // already knows how to handle ("plugin start() returned FALSE - engine did NOT open").
  private var pendingStartResult: FlutterResult?
  private var startTimeoutWork: DispatchWorkItem?

  /// Answer Dart EXACTLY ONCE. didActivate, the timeout, and the failure path can all
  /// race to get here; whichever arrives first wins and the rest are no-ops.
  private func resolveStart(_ value: Bool) {
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    guard let pending = pendingStartResult else { return }
    pendingStartResult = nil
    os_log("start: resolving Dart future -> %{public}@",
           log: SixPagesVoicePlugin.log, type: .info, value ? "TRUE" : "FALSE")
    pending(value)
  }

  /// Lazily built, held for the life of the plugin. CXProvider must not be recreated per
  /// call -- Apple: "Only create one instance of CXProvider."
  private func ensureCallKit() {
    if callProvider == nil {
      // BUILD 19 FIX: CXProviderConfiguration() -- the NO-ARGUMENT init -- is iOS 14+ only,
      // and this plugin's deployment target is below that. Codemagic caught it:
      // "'init()' is only available in iOS 14.0 or newer."
      //
      // The localizedName init has existed since CallKit shipped in iOS 10 and is available
      // on every version we support. The name is what the system call UI displays, so this
      // is not a workaround -- it is the init we should have used in the first place.
      let config = CXProviderConfiguration(localizedName: "Six Pages")
      config.supportsVideo = false
      config.maximumCallGroups = 1
      config.maximumCallsPerCallGroup = 1
      config.supportedHandleTypes = [.generic]
      // PRIVACY, DELIBERATE: this app exists for someone with nobody to call. Their
      // reflection sessions do not belong in the iOS call log.
      config.includesCallsInRecents = false

      let provider = CXProvider(configuration: config)
      provider.setDelegate(self, queue: nil)
      callProvider = provider
      os_log("CallKit: provider created (recents=off)",
             log: SixPagesVoicePlugin.log, type: .info)
    }
    if callController == nil { callController = CXCallController() }
  }

  /// PHASE 1. Declare the call. iOS drives the HFP state machine from here and tells the
  /// car a call is genuinely in progress -- which is the entire point of this build.
  /// Audio does NOT start here. It starts in provider(_:didActivate:).
  private func requestStartCall() {
    ensureCallKit()
    guard let controller = callController else { return }

    let uuid = UUID()
    currentCallUUID = uuid

    // .generic, not .phoneNumber: there is no number here, and we are not pretending
    // there is. The car only needs to know a CALL EXISTS.
    let handle = CXHandle(type: .generic, value: "Claude")
    let action = CXStartCallAction(call: uuid, handle: handle)
    action.isVideo = false

    let transaction = CXTransaction(action: action)
    controller.request(transaction) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        // The call was refused. Audio will never start, because didActivate will never
        // fire. Fail LOUDLY rather than sitting in a silent dead state.
        self.callKitState = "none"
        self.currentCallUUID = nil
        os_log("CallKit: CXStartCallAction FAILED -- %{public}@",
               log: SixPagesVoicePlugin.log, type: .error, error.localizedDescription)
        return
      }
      self.callKitState = "requested"
      os_log("CallKit: call requested -- waiting for didActivate",
             log: SixPagesVoicePlugin.log, type: .info)

      // ╔═══════════════════════════════════════════════════════════════════════╗
      // ║ BUILD 20: reportOutgoingCall() IS GONE FROM HERE. THIS WAS THE BUG.  ║
      // ╚═══════════════════════════════════════════════════════════════════════╝
      //
      // Build 19b reported the call FROM THIS COMPLETION BLOCK. That is a second,
      // INDEPENDENT async path racing provider(_:perform: CXStartCallAction), and
      // nothing orders them. reportOutgoingCall(connectedAt:) could therefore land
      // BEFORE the action was fulfilled -- i.e. we told CallKit the call had already
      // connected on a call the provider did not yet consider live. The transaction
      // never reached a state the system would elevate, so provider(_:didActivate:)
      // NEVER FIRED, the VPIO unit was never built, the 4s deadman resolved false,
      // and the Talk button was dead. ckActivates=0.
      //
      // It was also reporting startedConnectingAt: nil and connectedAt: nil back to
      // back. nil means NOW. We were declaring "connecting" and "connected" in the
      // same instant, before any audio existed. That is not the lifecycle CallKit
      // models and it is not what the call's duration timer is for.
      //
      // The reporting now lives where every Apple-sanctioned reference puts it:
      //   startedConnectingAt -> provider(_:perform: CXStartCallAction), before fulfill()
      //   connectedAt         -> beginAudio(), AFTER didActivate, when audio is REAL
      //
      // This completion handler now does exactly one job: notice a REFUSED call.
    }
  }

  /// Ends the call with the system. Safe to call when there is no call.
  private func requestEndCall() {
    guard let uuid = currentCallUUID, let controller = callController else {
      callKitState = "none"
      return
    }
    let action = CXEndCallAction(call: uuid)
    let transaction = CXTransaction(action: action)
    controller.request(transaction) { [weak self] error in
      if let error = error {
        os_log("CallKit: CXEndCallAction failed -- %{public}@",
               log: SixPagesVoicePlugin.log, type: .error, error.localizedDescription)
      }
      self?.callKitState = "ended"
    }
    currentCallUUID = nil
  }

  /// Live only for the duration of a session; removed in stopUnit().
  private var routeObserver: NSObjectProtocol?

  /// Live only for the duration of a session; removed in stopUnit().
  private var interruptionObserver: NSObjectProtocol?

  /// Diagnostics. Proves whether the car actually interrupted the session.
  private var interruptionCount = 0
  private var interruptionResumeFailures = 0

  /// Build 13 diagnostics: WHY did iOS move the route?
  /// The route observer has existed for weeks and has been THROWING THE ANSWER AWAY —
  /// it ignored the notification's userInfo, which carries AVAudioSessionRouteChangeReasonKey.
  /// That reason names the cause outright. It is the single most diagnostic fact in the
  /// car problem and it has never once been readable, because it only ever went to os_log.
  private var routeChangeCount = 0
  private var routeAtStart = "?"
  /// Build 17: did setPreferredInput take? ok | none | FAILED. Survives teardown so the
  /// strip can be read after the fact; reset only in startUnit().
  private var preferredInputState = "none"

  /// BUILD 18: THE CAPTURE SIDE. Ten builds of OUTPUT instrumentation and ZERO on the mic.
  /// Written from the audio thread (inputCallback), read from the platform thread (strip).
  /// Same discipline as renderCalls/droppedBytes: plain counters, no locks, no allocation
  /// inside the callback. A torn read is harmless -- we are looking for "zero versus
  /// climbing," never an exact value. Reset ONLY in startUnit(), so a strip read after
  /// teardown still reports what the session actually did.
  private var captureCallCount = 0
  private var captureByteCount = 0
  private var captureFailCount = 0
  private var lastCaptureStatus: OSStatus = 0
  private var routeHistory: [String] = []   // reason>route, capped; the whole story in one field

  /// Build 14: speaker-policy state. See applySpeakerPolicy().
  /// `speakerDefaultOn` mirrors whether .defaultToSpeaker is CURRENTLY in the category
  /// options. It exists so the policy can be idempotent — re-setting an unchanged
  /// category fires ANOTHER routeChange(categoryChange), which re-enters this handler.
  /// Without this guard that is an infinite loop. This is the single most dangerous
  /// line in the build; do not remove it.
  private var speakerDefaultOn = true
  private var policyApplyCount = 0
  private var policyFailCount = 0

  private static let targetSampleRate: Double = 16000.0

  // Frame contract (mirrors Android): 640 bytes = 20 ms of 16 kHz mono PCM16.
  private static let frameBytes = 640

  // Playback ring: sized to hold the LONGEST turn Joe can produce, without overflow.
  //
  // ElevenLabs synthesizes a whole turn in a few seconds and streams it to us FASTER
  // THAN REALTIME. The render callback drains at natural speech rate (~1 s of audio per
  // 1 s). So the ring must hold an ENTIRE turn — whatever arrives beyond its capacity is
  // discarded by the drop-newest overflow policy, which silently deletes the END of what
  // Joe was about to say. There is no backpressure to fall back on: feedPlayback is
  // fire-and-forget across the method channel, by design.
  //
  // SIZING HISTORY — this has now been raised THREE times, and each time the reason was
  // the same: a real reply outgrew the ring.
  //   Build 5  (eb1be7a):  15 s (480000 B)  — "sentences piling on top of each other"
  //   Build 7  (b99678b):  30 s (960000 B)  — "starts great, stumbles mid/late"
  //   Build 11 (this):    180 s (5760000 B) — playback died mid-sentence at ~30 s
  //
  // MEASURED, July 12 (iPad, one turn, ONE tap — verified against the ElevenLabs
  // conversation list, so no duplicate feed):
  //   renderCalls=3117 (~73 s session); droppedBytes=645178 (20.2 s of audio DELETED);
  //   underruns=4 (0.13% — healthy); maxRenderUs=42 (deadline 23000 — callback innocent).
  //   960000 (held) + 645178 (dropped) = 1605178 B = 50.2 s — EXACTLY one Joe turn.
  //   By ear: playback stopped dead mid-sentence at "It's almost like..." — the point
  //   where 30 s of buffered audio ran out. Everything after it was already discarded.
  //
  // WHY 180 s AND NOT 60 s: the measured turn was already 50 s. A 60 s ring passes that
  // test with 10 s to spare and truncates the next slightly-longer reflection. Joe is a
  // REFLECTION companion — long, considered replies are the PRODUCT, not an edge case.
  // 5.49 MB is trivial on an iPad and is allocated ONCE per session, not per turn. This
  // is a place where "too big" costs nothing and "too small" costs a lost conversation.
  //
  // DO NOT "optimize" this back down. Read droppedBytes instead: it must be 0.
  private static let playbackBufferBytes = 5_760_000   // 180 s of 16 kHz mono PCM16
  private let playback = ByteRingBuffer(capacityBytes: playbackBufferBytes)

  // Capture ring: ~500 ms of clean mic audio waiting to drain up to Dart.
  private static let captureBufferBytes = 16000
  private let capture = ByteRingBuffer(capacityBytes: captureBufferBytes)

  // Scratch AudioBufferList the input callback renders mic frames into.
  private var captureScratch: UnsafeMutablePointer<Int16>?
  private var captureScratchFrameCap = 0

  // Drain: pushes whole 640-byte frames up on the platform thread.
  private var drainTimer: DispatchSourceTimer?

  private var captureSink: FlutterEventSink?

  // Build 1 diagnostics: startUnit() fills this with the actual granted rate and
  // negotiated formats so the app can read it via getDiagnostics (we have no
  // Mac/Console). Plain string, human-readable.
  private var lastDiagnostics: String = "no session started yet"

  // Build 1: the render callback (audio thread) updates these so getDiagnostics
  // can report REAL underrun behavior — the direct measure of the chop. If
  // underrunFrames is high relative to renderCalls, the buffer is starving.
  // Plain Ints updated on one thread and read on another; acceptable for a
  // coarse diagnostic (not a correctness-critical value).
  fileprivate var renderCalls: Int = 0
  fileprivate var underrunEvents: Int = 0
  fileprivate var lastRenderBytesRequested: Int = 0
  fileprivate var lastInputFrames: Int = 0

  // Build 8: max time a single render callback took, in microseconds. If a
  // per-byte copy (now memcpy) or anything else made the callback exceed the
  // ~23 ms (23000 µs) hardware deadline late in a long turn, we'd see this spike.
  // maxRenderMicros near the deadline = the callback is the chop; staying tiny =
  // the callback is fine and the long-turn break-up is UPSTREAM (socket/feed).
  // mach_absolute_time is cheap and real-time safe; converted to µs via timebase.
  fileprivate var maxRenderMicros: Int = 0
  fileprivate var machTimebaseNumer: UInt32 = 0
  fileprivate var machTimebaseDenom: UInt32 = 0

  // Build 3 (Layer 7): playback priming state. `primed` gates the render
  // callback — while false, it emits silence (NOT counted as underrun) until
  // the ring accumulates `primeThresholdBytes`. `reprimeEvents` counts how many
  // times a mid-stream full-drain forced a re-prime (network stalls). These are
  // read by getDiagnostics so the next device test proves the cushion filled.
  fileprivate var primed = false
  fileprivate var primeThresholdBytes = 0   // set in startUnit from hwRate (~100 ms)
  fileprivate var reprimeEvents = 0

  // Build 4: actual hardware sample rate read at start (e.g. 48000), kept ONLY
  // for the diagnostic string. Playback no longer converts to it — the output
  // bus is 16 kHz and VoiceProcessingIO resamples 16k→hardware internally.
  private var hwRate: Double = SixPagesVoicePlugin.targetSampleRate

  // ╔═════════════════════════════════════════════════════════════════════════════╗
  // ║ BUILD 21: THE PLUGIN INSTANCE WAS BEING DEALLOCATED. THIS IS THE BUG.       ║
  // ╚═════════════════════════════════════════════════════════════════════════════╝
  //
  // Builds 19, 19a, 19b and 20 were ALL dead on the iPad -- callKit=none, ckActivates=0,
  // "no session started." Four builds. The CallKit architecture was correct. Build 20's
  // reportOutgoingCall ordering was correct. Neither of them ever RAN, because the object
  // they lived on WAS ALREADY GONE.
  //
  // register(with:) did this:
  //
  //     let instance = SixPagesVoicePlugin()          <- a LOCAL let
  //     registrar.addMethodCallDelegate(instance, ...) <- takes its delegate WEAKLY
  //     captureChannel.setStreamHandler(instance)      <- takes its handler WEAKLY
  //
  // NOBODY held a strong reference. Delegation across Cocoa is weak by convention, to
  // avoid retain cycles -- a weak reference does not keep a strong hold and does not stop
  // ARC from deallocating. So the plugin was destroyed the instant register() returned.
  //
  // WHY EIGHTEEN BUILDS NEVER NOTICED: every path was SYNCHRONOUS. handle() ran,
  // startUnit() built the unit, result(true) fired -- all inside ONE method invocation,
  // during which Flutter held the object alive. Nothing ever needed to SURVIVE past the
  // end of a method call, so a dangling instance was invisible.
  //
  // CALLKIT IS ASYNCHRONOUS, AND ASYNCHRONOUS REQUIRES THE OBJECT TO STILL EXIST LATER:
  //   * CXProvider.setDelegate(self, queue:) holds its delegate WEAKLY. Dead delegate =
  //     provider(didActivate:) can NEVER be called. There is nothing to call it on.
  //   * controller.request { [weak self] ... } -- `guard let self` FAILS, which is exactly
  //     why callKitState never even reached "requested". THE STRIP SAID callKit=none AND
  //     THAT WAS THE TELL: not a refused call -- a DEAD OBJECT.
  //   * callProvider and callController are STORED PROPERTIES on that instance. They died
  //     with it.
  //
  // CXProvider.init(configuration:) opens an XPC connection to callservicesd on a
  // secondary thread and calls back later, from out of process. CallKit is fundamentally
  // callback-driven. Nothing else in this plugin ever was.
  //
  // THE FIX, ONE LINE: hold the instance for the life of the process. This is what every
  // Flutter plugin with asynchronous callbacks does, and it is what CallKit's own "only
  // create one instance of CXProvider" guidance already implies -- one provider, on one
  // long-lived owner.
  //
  // DO NOT REMOVE THIS. If it goes, CallKit goes silent again and the button dies with no
  // error, exactly as it did for four builds.
  private static var retainedInstance: SixPagesVoicePlugin?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let controlChannel = FlutterMethodChannel(
      name: "six_pages_voice/control", binaryMessenger: messenger)
    let captureChannel = FlutterEventChannel(
      name: "six_pages_voice/capture", binaryMessenger: messenger)

    let instance = SixPagesVoicePlugin()

    // BUILD 21: THE STRONG REFERENCE. Everything below this line takes `instance` WEAKLY.
    // Without this, `instance` is deallocated the moment this method returns and CallKit
    // has no delegate to call back into.
    SixPagesVoicePlugin.retainedInstance = instance

    registrar.addMethodCallDelegate(instance, channel: controlChannel)
    captureChannel.setStreamHandler(instance)
    os_log("register: control + capture channels registered (instance retained)",
           log: log, type: .info)
  }

  // MARK: - MethodChannel (control)

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      // BUILD 19b: DO NOT ANSWER result() HERE. See resolveStart() and the comment block
      // on pendingStartResult. Under CallKit the engine does not exist yet at this point
      // -- iOS builds it for us, later, in provider(didActivate:). Answering true now
      // tells Dart "engine ready" while there is no audio unit, and Dart then feeds Joe
      // into nothing. That was the dead button.
      //
      // The FlutterResult is HELD and answered from resolveStart(), called either from
      // beginAudio() on success or from the 4-second timeout on failure.
      if isRunning {
        // Already running. Answer immediately; do not re-enter the CallKit dance.
        result(true)
        return
      }
      if pendingStartResult != nil {
        // A start is already in flight. Refuse the second one rather than orphaning the
        // first FlutterResult -- an unanswered result hangs a Dart future forever.
        os_log("start: IGNORED — a start is already awaiting didActivate",
               log: SixPagesVoicePlugin.log, type: .error)
        result(false)
        return
      }

      pendingStartResult = result

      // THE DEADMAN. If didActivate never arrives (the documented first-launch CallKit
      // bug), this is the ONLY thing standing between the user and a permanently dead
      // button. Fail loudly, in a way Dart already handles.
      let timeout = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        guard self.pendingStartResult != nil else { return }
        os_log("start: TIMED OUT — provider(didActivate:) never fired in 4s. ckActivates=%d. Audio never started.",
               log: SixPagesVoicePlugin.log, type: .error, self.callKitActivateCount)
        self.stopUnit()
        self.resolveStart(false)
      }
      startTimeoutWork = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: timeout)

      do {
        try startUnit()
        os_log("start: session configured + call requested — Dart is WAITING for didActivate",
               log: SixPagesVoicePlugin.log, type: .info)
      } catch {
        os_log("start: FAILED — %{public}@", log: SixPagesVoicePlugin.log, type: .error,
               String(describing: error))
        stopUnit()
        resolveStart(false)
      }
    case "stop":
      stopUnit()
      os_log("stop: unit torn down", log: SixPagesVoicePlugin.log, type: .info)
      result(nil)
    case "getDiagnostics":
      // Build 1: return granted rate + negotiated formats + LIVE render/underrun
      // counts. Underrun ratio is the direct measure of the chop: if
      // underrunEvents is a large fraction of renderCalls, the buffer starves.
      // lastRenderBytesRequested vs lastInputFrames reveals rate/frame shape.
      // Build 3: append priming state (primed / reprimes / threshold) so we can
      // prove the cushion filled and underruns collapsed toward 0.
      // Build 12: interruptions + live route. The STRIP IS THE ONLY iOS INSTRUMENT.
      // os_log is unreadable in this workflow (Windows + TestFlight, no Mac), so a
      // counter that is not on this line does not exist. The car-drop diagnosis
      // lives or dies on interruptions= — if the car never interrupts us, the
      // theory is wrong and we look elsewhere WITH DATA. route= is here because
      // the very next question after that is "what did iOS actually pick."
      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
      let liveRoute = outputs.first.map { routeName($0.portType) } ?? "none"
      let live = "renderCalls=\(renderCalls); underruns=\(underrunEvents); "
        + "lastReqBytes=\(lastRenderBytesRequested); lastInputFrames=\(lastInputFrames); "
        + "primed=\(primed); reprimes=\(reprimeEvents); primeThresh=\(primeThresholdBytes)B; "
        + "droppedBytes=\(playback.droppedBytes); maxRenderUs=\(maxRenderMicros); "
        + "interruptions=\(interruptionCount); resumeFails=\(interruptionResumeFailures); "
        // BUILD 17: input= IS THE FIRST NUMBER TO READ IN A CAR. The car hangs up when
        // the HFP call has no upstream — i.e. when input=mic-builtin while a call is
        // open. input=bt-hfp means we answered it. prefIn= says whether the set took.
        // BUILD 19: CALLKIT GOES FIRST. It now GATES EVERYTHING. If ckActivates=0 then
        // provider(didActivate:) never fired, the VPIO unit was never built, and NO OTHER
        // NUMBER ON THIS STRIP MEANS ANYTHING. Read it before you read anything else.
        + "callKit=\(callKitState); ckActivates=\(callKitActivateCount); "
        // BUILD 18: THE CAPTURE COUNTERS GO FIRST, AHEAD OF input=. In a car, "did the
        // mic actually RUN" now outranks "which mic did we PICK" -- Build 17 already
        // proved we pick the right one and the car hangs up on us anyway.
        + "captureCalls=\(captureCallCount); captureBytes=\(captureByteCount); "
        + "captureFails=\(captureFailCount)"
        + (lastCaptureStatus != 0 ? " [status=\(lastCaptureStatus)]" : "")
        + "; "
        + "input=\(currentInputName()); prefIn=\(preferredInputState); "
        + "routeAtStart=\(routeAtStart); route=\(liveRoute); "
        + "routeChanges=\(routeChangeCount); spkDefault=\(speakerDefaultOn ? "on" : "off"); "
        + "policyApplies=\(policyApplyCount); policyFails=\(policyFailCount); "
        + "why=[\(routeHistory.joined(separator: " | "))]"
      result(lastDiagnostics + live)

    case "feedPlayback":
      if let typed = call.arguments as? FlutterStandardTypedData {
        // Build 4: write Joe's raw 16 kHz PCM16 straight to the ring. NO manual
        // conversion — the output bus is 16 kHz and VoiceProcessingIO resamples
        // 16k→hardware internally, continuously, with no chunk-boundary seams.
        typed.data.withUnsafeBytes { raw in playback.write(raw) }
        result(nil)
      } else {
        result(FlutterError(code: "BAD_ARG",
                            message: "feedPlayback expected raw bytes (FlutterStandardTypedData)",
                            details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Audio unit lifecycle

  private enum AudioError: Error {
    case session(String)
    case osStatus(String, OSStatus)
    case noComponent
  }

  // MARK: - Audio route (OBSERVE-ONLY)
  //
  // This listener REPORTS where audio went. It does NOT steer. Ever.
  //
  // Apple's documented contract, three points, each sufficient alone:
  //   1. "Apps should treat these changes as authoritative. They should NEVER
  //      immediately attempt to revert the change."
  //   2. The notification is POSTED ON A SECONDARY THREAD — acting on it touches
  //      session state at an unpredictable moment relative to the running unit.
  //   3. DECISIVE: with kAudioUnitSubType_VoiceProcessingIO, "the system will
  //      automatically manage this for the application. In particular, ports of
  //      type AVAudioSessionPortBluetoothHFP and AVAudioSessionPortCarAudio."
  //      VPIO ALREADY handles Bluetooth and car routing. There is nothing to fix.
  //
  // A previous build (ae4e8e2) called overrideOutputAudioPort(.speaker) from inside
  // this listener. It caused the long-reply chop and the car drop. DO NOT RE-ADD IT.
  //
  // NOTE the asymmetry with Android, and that it is CORRECT: Android's AudioManager
  // DOES expect the app to select the device, and there we re-assert deliberately.
  // iOS does not. Importing the Android mechanism across that boundary was the bug.
  // Symmetry in the LOGS is good. Symmetry in the MECHANISM is not.

  // MARK: - Speaker policy (Build 14) — THE CAR FIX
  //
  // MEASURED (iPad, in a car, July 12):
  //     routeAtStart=bluetooth; route=speaker; routeChanges=2;
  //     why=[categoryChange>bluetooth | override>speaker]
  //
  // We GET the car. Then WE TAKE IT AWAY FROM OURSELVES. `override` has exactly one
  // source in AVFoundation — the output port being overridden to the speaker — and this
  // plugin makes no overrideOutputAudioPort call (c95f26c deleted it). The only remaining
  // mechanism in our code is the .defaultToSpeaker CATEGORY OPTION, set once at startUnit()
  // and never revisited. When the car finishes negotiating, iOS re-evaluates the route,
  // our standing .defaultToSpeaker reasserts itself, and the car is gone. ~5 seconds in.
  //
  // Apple's AVAudioSession header, on our exact audio unit:
  //   "if using Apple's Voice Processing I/O unit (kAudioUnitSubType_VoiceProcessingIO),
  //    the system will automatically manage this for the application. In particular,
  //    ports of type AVAudioSessionPortBluetoothHFP and AVAudioSessionPortCarAudio..."
  // VPIO ALREADY KNOWS HOW TO HANDLE THE CAR. We were overriding it. Again.
  //
  // ── WHY WE CANNOT SIMPLY DELETE .defaultToSpeaker ─────────────────────────────
  //
  // Because it is LOAD-BEARING, and deleting it would ship a broken iPhone.
  //
  // With mode .voiceChat (which VPIO REQUIRES — platform AEC is only enabled in
  // AVAudioSessionModeVoiceChat, and AEC is the entire reason this plugin exists),
  // a bare iPhone with no accessory routes output to the RECEIVER (the earpiece),
  // not the speaker. Joe would be inaudible unless the phone were held to an ear.
  // .defaultToSpeaker is what prevents that. The iPad HAS NO EARPIECE, so this bug
  // would have been INVISIBLE on our only test device and would have shipped.
  //
  // (Do not "fix" it by switching to mode .default either. That kills platform AEC.
  //  Twilio tried exactly that and reported the echo cancellation gone.)
  //
  // ── THE ACTUAL CONSTRAINT ─────────────────────────────────────────────────────
  //
  // One flag, two contradictory requirements, decided by what is plugged in:
  //     NO external device  -> .defaultToSpeaker REQUIRED   (or iPhone -> earpiece)
  //     car/headset present -> .defaultToSpeaker POISONOUS  (it overrides the route away)
  //
  // A flag set once at startup CANNOT satisfy both. That is the bug. Not the flag —
  // the fact that we set it once and never looked at it again.
  //
  // So: re-evaluate it whenever the route changes. Drop .defaultToSpeaker when a real
  // output device is present (and let VPIO do the CarAudio/HFP management Apple says it
  // already does), restore it when we are back to the bare device.
  //
  // This is NOT us steering the route. We select nothing. We call no override. We are
  // REMOVING OUR OWN STANDING OVERRIDE so that iOS can do its job — which is the
  // hands-off rule correctly applied, not a violation of it. Every iOS fix that has
  // worked in this repo was a removal; this one is a removal that knows when to apply.
  //
  // Expected behavior, and the spec this was written against:
  //   driving, get in car, car connects  -> oldDevice/newDevice fires -> policy drops
  //                                         .defaultToSpeaker -> VPIO takes CarAudio
  //   park, shut the car off             -> oldDeviceUnavailable fires -> policy restores
  //                                         .defaultToSpeaker -> audio returns to speaker
  // i.e. it behaves like a phone call. Which is what it is.

  /// Ports that mean "a real output device the user chose." If any of these is the
  /// current output, .defaultToSpeaker must be OFF or it will override the route away.
  /// carAudio and bluetoothHFP are the two Apple explicitly names as VPIO-managed.
  private static let externalOutputPorts: Set<AVAudioSession.Port> = [
    .carAudio,
    .bluetoothHFP,
    .bluetoothA2DP,
    .bluetoothLE,
    .headphones,
    .headsetMic,
    .usbAudio,
    .airPlay,
    .lineOut,
    .HDMI
  ]

  /// BUILD 15: the INPUT side is the honest witness.
  ///
  /// External devices that can STEAL THE OUTPUT ROUTE. Reading currentRoute.outputs to
  /// decide whether .defaultToSpeaker belongs is circular: .defaultToSpeaker OVERRIDES
  /// currentRoute.outputs. Asking it "is a car here?" AFTER the override has fired
  /// returns `speaker` and answers NO — so the policy sees the aftermath of its own bug
  /// and reinforces it. Measured in the car as policyApplies=2, spkDefault=on.
  ///
  /// availableInputs is not on the output path. An output override CANNOT corrupt it.
  /// A paired car or headset exposes a carAudio/bluetoothHFP/headsetMic INPUT whether or
  /// not it is currently the OUTPUT. It is also VALID BEFORE setActive(true) — which
  /// currentRoute is not — and that is what lets startUnit() decide the category BEFORE
  /// activating, instead of cleaning up afterward.
  ///
  /// currentRoute.outputs is kept as an ADDITIVE second source, not a replacement: wired
  /// headphones have no microphone and expose no input port. Either source being true
  /// means "not alone." Neither alone is sufficient.
  private static let externalInputPorts: Set<AVAudioSession.Port> = [
    .carAudio,
    .bluetoothHFP,
    .bluetoothLE,
    .headsetMic,
    .usbAudio,
    .lineIn
  ]

  /// BUILD 16 — WHY THE INPUT PROBE IS NO LONGER SUFFICIENT ON ITS OWN.
  ///
  /// Build 15 leaned on availableInputs because currentRoute.outputs was being
  /// corrupted by our own .defaultToSpeaker override. That reasoning was sound and
  /// the probe STAYS. But it was built for a world where we requested HFP — and an
  /// HFP car exposes a bluetoothHFP INPUT port, which is what made the probe work.
  ///
  /// We no longer request HFP. An A2DP car is OUTPUT-ONLY BY DEFINITION: it exposes
  /// a bluetoothA2DP output port and NO input port at all. So on the very device
  /// this build exists to fix, availableInputs now returns NOTHING useful.
  ///
  /// The output probe carries it instead — and it is now TRUSTWORTHY, because Build
  /// 15 already removed the override that was poisoning it. .defaultToSpeaker is
  /// decided BEFORE setActive and never re-applied behind our back. Nothing steals
  /// currentRoute.outputs anymore.
  ///
  /// Keep BOTH. Either one being true means "not alone." Neither alone is enough:
  ///   - A2DP car / A2DP headphones  -> OUTPUT port only, no input.
  ///   - Wired headset with a mic     -> input port, and an output port.
  ///   - Wired headphones (no mic)    -> OUTPUT port only, no input.
  /// The union is the honest answer. This is a widening, not a replacement.

  private func hasExternalOutput() -> Bool {
    let session = AVAudioSession.sharedInstance()

    // FIRST, and this ordering matters: the input side cannot be stolen by an override.
    if let inputs = session.availableInputs {
      for port in inputs {
        if SixPagesVoicePlugin.externalInputPorts.contains(port.portType) { return true }
      }
    }

    // SECOND, additive: catches mic-less outputs (wired headphones, AirPlay, HDMI, lineOut).
    for port in session.currentRoute.outputs {
      if SixPagesVoicePlugin.externalOutputPorts.contains(port.portType) { return true }
    }

    return false
  }

  /// Re-evaluate whether .defaultToSpeaker belongs in the category options RIGHT NOW.
  ///
  /// IDEMPOTENT BY CONSTRUCTION. setCategory() itself fires a routeChange(categoryChange),
  /// which re-enters the route observer, which calls this again. If this method set the
  /// category unconditionally, that is an INFINITE LOOP. The `wanted == speakerDefaultOn`
  /// early return is the only thing standing between us and that loop. Leave it alone.
  ///
  /// FAILURE IS NON-FATAL AND MUST STAY THAT WAY. If setCategory throws mid-session
  /// (it can — a live VPIO unit is not guaranteed to accept a category change), we log,
  /// count it onto the strip, and LEAVE THE EXISTING CATEGORY ALONE. A car that will not
  /// route is annoying. A conversation that dies is unacceptable. Joe keeps talking no
  /// matter what the routing does.
  private func applySpeakerPolicy(reason: String) {
    let external = hasExternalOutput()
    let wanted = !external   // .defaultToSpeaker ON only when we are alone

    guard wanted != speakerDefaultOn else {
      os_log("Speaker policy (%{public}@): unchanged (defaultToSpeaker=%{public}@)",
             log: SixPagesVoicePlugin.log, type: .info,
             reason, speakerDefaultOn ? "on" : "off")
      return
    }

    // BUILD 17: .allowBluetooth RESTORED alongside .allowBluetoothA2DP. Must match
    // startUnit() EXACTLY — if these two sites disagree, a mid-session route change
    // silently re-negotiates the Bluetooth profile under a live VPIO unit.
    //
    // Apple: when ONE device offers both HFP and A2DP, HFP WINS PRIORITY. That is now
    // exactly what we want — we ANSWER the call (see selectPreferredInput) instead of
    // refusing it. A2DP stays in the set for output-only devices that have no HFP.
    var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    if wanted { options.insert(.defaultToSpeaker) }

    do {
      // Category only. Mode stays .voiceChat — VPIO requires it for platform AEC.
      // We do NOT deactivate/reactivate the session: the unit is running, the ring is
      // full of Joe, and tearing the session down mid-turn would lose audio.
      try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord, mode: .voiceChat, options: options)
      speakerDefaultOn = wanted
      policyApplyCount += 1
      os_log("Speaker policy (%{public}@): defaultToSpeaker -> %{public}@ (external=%{public}@)",
             log: SixPagesVoicePlugin.log, type: .info,
             reason, wanted ? "ON" : "OFF", external ? "yes" : "no")
    } catch {
      // Do NOT touch speakerDefaultOn — it still describes the category actually in force.
      policyFailCount += 1
      os_log("Speaker policy (%{public}@): setCategory FAILED — %{public}@",
             log: SixPagesVoicePlugin.log, type: .error,
             reason, error.localizedDescription)
    }
  }

  /// Build 13: iOS names the cause of every route change. Decode it.
  ///
  ///   oldDeviceUnavailable  — the car/headset WENT AWAY. iOS had no choice.
  ///   override              — SOMEONE called overrideOutputAudioPort. Should be nobody: we deleted it.
  ///   categoryChange        — the session category/options were changed mid-flight.
  ///   routeConfigChange     — the route's configuration changed underneath us.
  ///   newDeviceAvailable    — something new appeared and iOS preferred it.
  ///   noSuitableRouteForCategory — .playAndRecord could not be satisfied by the current device.
  ///
  /// For the car, these are NOT equivalent and they point at completely different fixes.
  /// oldDeviceUnavailable means the CAR dropped us and the fight is with the car's HFP link.
  /// noSuitableRouteForCategory means .playAndRecord cannot live on that route at all.
  /// categoryChange means WE did it to ourselves. Guessing between these has cost us nights.
  private func routeChangeReasonName(_ raw: UInt) -> String {
    guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "unknown(\(raw))" }
    switch reason {
    case .unknown:                    return "unknown"
    case .newDeviceAvailable:         return "newDeviceAvailable"
    case .oldDeviceUnavailable:       return "oldDeviceUnavailable"
    case .categoryChange:             return "categoryChange"
    case .override:                   return "override"
    case .wakeFromSleep:              return "wakeFromSleep"
    case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
    case .routeConfigurationChange:   return "routeConfigChange"
    @unknown default:                 return "unhandled(\(raw))"
    }
  }

  private func registerRouteListener() {
    guard routeObserver == nil else { return }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      self.routeChangeCount += 1

      // THE LINE THAT WAS MISSING. The old observer took `_` and discarded userInfo,
      // throwing away the reason on every single route change since this file was written.
      //
      // Read it as NSNumber, which is the DOCUMENTED type in the header:
      //   "value is an NSNumber representing an AVAudioSessionRouteChangeReason"
      // `as? UInt` is the common idiom and does work, but NSNumber->uintValue is the
      // type Apple actually promises. A diagnostic that silently reports the WRONG
      // reason is worse than none at all: this strip gets read once, in a car, after
      // a drive. It does not get a second chance. No fallback sentinel, no ambiguity.
      let reason: String
      if let num = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber {
        reason = self.routeChangeReasonName(UInt(num.uintValue))
      } else {
        // Should be impossible. If this EVER appears on the strip, the notification
        // shape changed and nothing below it can be trusted.
        reason = "NO-REASON-KEY"
      }

      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
      let now = outputs.first.map { self.routeName($0.portType) } ?? "none"

      // Compact, strip-readable trail: reason>destination, oldest first.
      // Capped so a long drive cannot push the rest of the strip off screen.
      if self.routeHistory.count < 6 {
        self.routeHistory.append("\(reason)>\(now)")
      }

      os_log("Route change #%d: reason=%{public}@ -> %{public}@",
             log: SixPagesVoicePlugin.log, type: .info,
             self.routeChangeCount, reason, now)

      // Build 14: re-evaluate .defaultToSpeaker for the route we are NOW on.
      // Only while running — a route change after teardown must not resurrect anything.
      // NOTE: this can itself fire a categoryChange route notification and re-enter here.
      // applySpeakerPolicy() is idempotent; that is what makes the re-entry terminate.
      if self.isRunning {
        self.applySpeakerPolicy(reason: reason)
      }
    }
  }

  private func unregisterRouteListener() {
    if let observer = routeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeObserver = nil
    }
  }

  // MARK: - Interruption handling (REQUIRED by Apple for .playAndRecord)
  //
  // This is NOT a routing override and does not violate the hands-off rule above.
  // Route CONTROL is iOS's job — we deleted overrideOutputAudioPort and were right to.
  // Interruption RESPONSE is OUR job, and Apple documents it as mandatory:
  //
  //   "Your app must respond to an interruption [...] and, when the interruption ends,
  //    reactivate the audio session."   — AVAudioSession: Handling Audio Interruptions
  //
  // We never implemented it. That is a contract we OWE the platform, not one we are
  // imposing on it. Every phone call, Siri invocation, alarm — and the reason we
  // found this, every CAR BLUETOOTH CONNECT — can interrupt a .playAndRecord session.
  // A car head unit negotiating HFP commonly fires .began then .ended within seconds
  // of connecting. Unhandled, the OS suspends our AudioUnit and NOBODY restarts it.
  // The session "opens, then dies four seconds later." That is the exact symptom.
  //
  //   .began — the OS has ALREADY stopped the unit. Do not fight it. Count it, wait.
  //            We deliberately do NOT call stopUnit(): that would dispose the unit and
  //            clear the ring. We want to RESUME, not restart from nothing.
  //   .ended — reactivate and restart the unit, but ONLY if the system grants
  //            .shouldResume. If it does not, the interruptor still owns audio and
  //            forcing our way back in is exactly the kind of override that has
  //            broken this plugin before. We stand down and log it.
  private func registerInterruptionListener() {
    guard interruptionObserver == nil else { return }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      self?.handleInterruption(note)
    }
  }

  private func unregisterInterruptionListener() {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
  }

  private func handleInterruption(_ note: Notification) {
    // NSNumber is the documented type here too. Same reasoning as the route observer:
    // interruptions=0 must mean "the car did not interrupt us", NEVER "the cast failed
    // and we silently returned." That number was used to KILL a theory. It has to be real.
    guard
      let info = note.userInfo,
      let num = info[AVAudioSessionInterruptionTypeKey] as? NSNumber,
      let type = AVAudioSession.InterruptionType(rawValue: UInt(num.uintValue))
    else {
      os_log("Interruption notification with NO TYPE KEY — notification shape changed",
             log: SixPagesVoicePlugin.log, type: .error)
      return
    }

    switch type {
    case .began:
      interruptionCount += 1
      os_log("Interruption BEGAN (count=%d) - OS has suspended the audio unit",
             log: SixPagesVoicePlugin.log, type: .info, interruptionCount)

    case .ended:
      var shouldResume = false
      if let optsNum = info[AVAudioSessionInterruptionOptionKey] as? NSNumber {
        shouldResume = AVAudioSession.InterruptionOptions(rawValue: UInt(optsNum.uintValue))
          .contains(.shouldResume)
      }
      os_log("Interruption ENDED (shouldResume=%{public}@)",
             log: SixPagesVoicePlugin.log, type: .info, shouldResume ? "true" : "false")

      guard shouldResume else {
        interruptionResumeFailures += 1
        os_log("Interruption ENDED without shouldResume - standing down (failures=%d)",
               log: SixPagesVoicePlugin.log, type: .info, interruptionResumeFailures)
        return
      }
      guard isRunning else {
        os_log("Interruption ENDED but no session is running - nothing to resume",
               log: SixPagesVoicePlugin.log, type: .info)
        return
      }

      do {
        // ╔═══════════════════════════════════════════════════════════════════════╗
        // ║ BUILD 19: setActive(true) REMOVED HERE TOO. Under CallKit the SYSTEM  ║
        // ║ re-activates the session after an interruption and tells us via       ║
        // ║ provider(_:didActivate:). Calling setActive ourselves here fights     ║
        // ║ CallKit for ownership of the session and can drop us back to MEDIA    ║
        // ║ priority -- which is precisely the state the car hangs up on.         ║
        // ║                                                                       ║
        // ║ We only restart the UNIT. The SESSION is not ours to activate.        ║
        // ╚═══════════════════════════════════════════════════════════════════════╝
        if let unit = ioUnit {
          let status = AudioOutputUnitStart(unit)
          if status == noErr {
            // The ring survived; the unit did not. Re-prime so playback does not
            // resume into a half-empty buffer and immediately underrun.
            primed = false
            os_log("Interruption resume OK - unit restarted, re-priming",
                   log: SixPagesVoicePlugin.log, type: .info)
          } else {
            interruptionResumeFailures += 1
            os_log("Interruption resume FAILED - AudioOutputUnitStart status=%d",
                   log: SixPagesVoicePlugin.log, type: .error, Int(status))
          }
        }
      } catch {
        interruptionResumeFailures += 1
        os_log("Interruption resume FAILED - setActive threw: %{public}@",
               log: SixPagesVoicePlugin.log, type: .error, error.localizedDescription)
      }
      logCurrentRoute(prefix: "Route after interruption")

    @unknown default:
      break
    }
  }

  private func logCurrentRoute(prefix: String = "Route") {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    let name = outputs.first.map { routeName($0.portType) } ?? "none"
    os_log("%{public}@ -> %{public}@", log: SixPagesVoicePlugin.log, type: .info, prefix, name)
  }

  /// BUILD 17: HFP AND A2DP ARE NO LONGER THE SAME WORD.
  ///
  /// This function used to map BOTH .bluetoothA2DP and .bluetoothHFP to "bluetooth" so
  /// the logs would read identically to Android's. That cosmetic symmetry made Build 16
  /// UNREADABLE: Build 16 existed to answer "which Bluetooth profile did iOS actually
  /// give us?" and the strip was structurally incapable of saying. We had to look at the
  /// CAR'S DASHBOARD to learn what our own diagnostic should have told us.
  ///
  /// Same class of error as Build 13's discarded userInfo: an instrument that cannot
  /// distinguish the thing it is pointed at. HFP vs A2DP is now THE central distinction
  /// in this entire bug. NEVER MERGE THEM AGAIN, for any amount of log symmetry.
  private func routeName(_ port: AVAudioSession.Port) -> String {
    switch port {
    case .bluetoothHFP:                 return "bt-hfp"      // the CALL profile — duplex
    case .bluetoothA2DP:                return "bt-a2dp"     // the MEDIA profile — out only
    case .bluetoothLE:                  return "bt-le"
    case .headphones:                   return "wired-headphones"
    case .headsetMic:                   return "wired-headset-mic"
    case .usbAudio:                     return "usb-audio"
    case .carAudio:                     return "car-audio"
    case .builtInSpeaker:               return "speaker"
    case .builtInReceiver:              return "earpiece"
    case .builtInMic:                   return "mic-builtin"
    default:                            return port.rawValue
    }
  }

  /// BUILD 17: THE MOST IMPORTANT LINE ON THE STRIP.
  ///
  /// Which MICROPHONE are we actually on? The car hangs up when the HFP call has no
  /// upstream audio — i.e. when the input is the BUILT-IN mic while an HFP call is open.
  /// So `input=` is the direct read of whether this build's fix took hold.
  ///
  ///     input=bt-hfp     -> we answered the call. The upstream is live.
  ///     input=mic-builtin WITH a call on the dash -> DEAD UPSTREAM. The bug is back.
  private func currentInputName() -> String {
    let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
    return inputs.first.map { routeName($0.portType) } ?? "none"
  }

  /// BUILD 17: SELECT THE CAR'S MICROPHONE. THE OUTPUT FOLLOWS ON ITS OWN.
  ///
  /// Apple, verbatim: "If an application is using setPreferredInput to select a Bluetooth
  /// HFP input, the output should automatically be changed to the Bluetooth HFP output
  /// corresponding with that input."
  ///
  /// So this function NEVER touches the output. It picks a MIC. iOS does the rest. That
  /// is the contract, and it is the entire reason this is not a route override: every
  /// output lever we ever deleted (overrideOutputAudioPort, .defaultToSpeaker at
  /// activation) STAYS deleted. Input selection is the app's job. Output routing is iOS's.
  ///
  /// MUST BE CALLED AFTER setActive(true). Apple: "To set the input, the app's session
  /// needs to be in control of routing." Before activation this is a SILENT NO-OP — the
  /// call succeeds, returns no error, and changes nothing. That is the trap in the Apple
  /// forum thread where the route "clearly has not changed."
  ///
  /// FAILURE IS NON-FATAL. If there is no HFP input, or the set throws, we log it, count
  /// it, and leave the session exactly as it was. A car that will not route is annoying.
  /// A conversation that dies is unacceptable. Joe keeps talking no matter what.
  ///
  /// Preference order matters: .carAudio FIRST (a true car head unit, if the system
  /// enumerates it as one), then .bluetoothHFP (what our test car actually reports),
  /// then a wired headset mic. We do NOT select .builtInMic — that is already the
  /// default, and selecting it explicitly is what KILLS the HFP upstream.
  private static let preferredInputPorts: [AVAudioSession.Port] = [
    .carAudio,
    .bluetoothHFP,
    .headsetMic,
    .usbAudio
  ]

  private func selectPreferredInput() {
    let session = AVAudioSession.sharedInstance()

    guard let inputs = session.availableInputs, !inputs.isEmpty else {
      preferredInputState = "none"
      os_log("Preferred input: availableInputs EMPTY — nothing to select",
             log: SixPagesVoicePlugin.log, type: .info)
      return
    }

    // Log what the system is actually offering. When a car enumerates as some port type
    // we did not anticipate, THIS LINE is the only way we will ever find out.
    for port in inputs {
      os_log("Preferred input: OFFERED %{public}@ (%{public}@)",
             log: SixPagesVoicePlugin.log, type: .info,
             routeName(port.portType), port.portName)
    }

    var chosen: AVAudioSessionPortDescription? = nil
    outer: for wanted in SixPagesVoicePlugin.preferredInputPorts {
      for port in inputs where port.portType == wanted {
        chosen = port
        break outer
      }
    }

    guard let target = chosen else {
      // No external mic on offer. The built-in mic is already the default; leave it.
      preferredInputState = "none"
      os_log("Preferred input: no external mic offered — leaving built-in default",
             log: SixPagesVoicePlugin.log, type: .info)
      return
    }

    do {
      try session.setPreferredInput(target)
      preferredInputState = "ok"
      os_log("Preferred input: SELECTED %{public}@ (%{public}@) — output should follow",
             log: SixPagesVoicePlugin.log, type: .info,
             routeName(target.portType), target.portName)
    } catch {
      preferredInputState = "FAILED"
      os_log("Preferred input: setPreferredInput THREW — %{public}@ (non-fatal, session left as-is)",
             log: SixPagesVoicePlugin.log, type: .error,
             error.localizedDescription)
    }
  }

  /// BUILD 19 -- PHASE 1. CONFIGURE AND DECLARE. DO NOT ACTIVATE. DO NOT START AUDIO.
  ///
  /// Apple, WWDC 2016 S230: "When using CallKit, you will NO LONGER ACTIVATE your app's
  /// audio session directly. Instead you will only CONFIGURE the audio session and the
  /// system will actually activate it FOR you, AT AN ELEVATED PRIORITY."
  ///
  /// That elevated priority is what holds the car's SCO link up as a CALL. It is the
  /// whole reason this build exists. Taking setActive(true) back would undo it.
  ///
  /// Audio starts in provider(_:didActivate:) -> beginAudio(). Not here. Never here.
  private func startUnit() throws {
    if isRunning { return }

    callKitActivateCount = 0
    callKitState = "none"

    // Session config FIRST, call SECOND. This ordering is Apple's own documented
    // workaround for the known first-launch bug where didActivate never fires: configure
    // the session BEFORE reporting the call, not inside the action handler.
    try configureSession()

    // THE DECLARATION. Everything else in this build is scaffolding around this line.
    requestStartCall()

    // And now we WAIT. iOS will call provider(_:didActivate:) when the session is live at
    // call priority, and THAT is where the VPIO unit gets built. isRunning stays false
    // until then -- there is genuinely no audio engine yet.
    os_log("start: session configured, call requested -- awaiting didActivate",
           log: SixPagesVoicePlugin.log, type: .info)
  }

  /// Category, mode, preferred rate. NOTHING ELSE. Explicitly NO setActive(true).
  private func configureSession() throws {
    let session = AVAudioSession.sharedInstance()
    do {
      // BUILD 15: DECIDE .defaultToSpeaker BEFORE setActive(true). NOT AFTER.
      //
      // Build 14 set the category with .defaultToSpeaker ON, activated, and THEN ran the
      // policy to take it back off. That ordering IS the bug. setActive(true) with
      // .defaultToSpeaker standing in the category is EXACTLY what fires override>speaker.
      // The car is taken away DURING ACTIVATION — before any policy can run. Build 14
      // called that "a brief moment on the speaker" and accepted it as the fail-safe cost.
      // It was never brief. It was the whole failure: why=[categoryChange>bluetooth |
      // override>speaker], route=speaker, every time, ~5 seconds in.
      //
      // hasExternalOutput() now reads availableInputs, which is VALID BEFORE ACTIVATION and
      // cannot be corrupted by an output override. So we can ask the question HERE, while
      // the answer still means something, and never create the mess in the first place.
      //
      // Fail-safe direction is UNCHANGED: if no external device is detected we set
      // .defaultToSpeaker, exactly as before. A bare iPhone still cannot reach the earpiece.
      let externalAtStart = hasExternalOutput()

      // BUILD 17: .allowBluetooth IS BACK. Build 16 tried to remove it and iOS forced
      // HFP anyway (the dash showed the call, and it still hung up at 5s). A2DP cannot
      // carry duplex audio, so with a LIVE INPUT on .playAndRecord, Bluetooth MUST be
      // HFP. We cannot refuse the call. So we ANSWER it — see selectPreferredInput()
      // below, which picks the car's MIC and lets iOS move the output to match.
      //
      // Both options set. Apple: HFP wins priority when one device offers both — which
      // is what we now WANT. A2DP remains for output-only devices with no HFP at all.
      var startOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
      if !externalAtStart { startOptions.insert(.defaultToSpeaker) }

      try session.setCategory(.playAndRecord, mode: .voiceChat, options: startOptions)
      try session.setPreferredSampleRate(SixPagesVoicePlugin.targetSampleRate)

      // ╔═══════════════════════════════════════════════════════════════════════╗
      // ║ BUILD 19: setActive(true) IS GONE FROM HERE. THIS IS THE POINT OF THE ║
      // ║ BUILD. DO NOT PUT IT BACK.                                            ║
      // ║                                                                       ║
      // ║ Apple, WWDC 2016 S230: "When using CallKit, you will no longer        ║
      // ║ activate your app's audio session directly. Instead you will only     ║
      // ║ CONFIGURE the audio session and the system will actually ACTIVATE it  ║
      // ║ for you AT AN ELEVATED PRIORITY."                                     ║
      // ║                                                                       ║
      // ║ That elevated priority is what makes iOS hold the car's SCO link up   ║
      // ║ as a CALL. Activating it ourselves gets us a media session that       ║
      // ║ happens to want a microphone -- which is exactly what the car has     ║
      // ║ been hanging up on for eighteen builds.                               ║
      // ╚═══════════════════════════════════════════════════════════════════════╝

      // speakerDefaultOn MIRRORS the live category. It MUST equal what we just passed to
      // setCategory or the idempotence guard in applySpeakerPolicy() believes a lie — and
      // that guard is the only thing terminating the categoryChange re-entry loop.
      // Set here, inside the do-block, so it can never drift from the actual call above.
      speakerDefaultOn = !externalAtStart

      os_log("Category configured: defaultToSpeaker=%{public}@ (externalAtStart=%{public}@)",
             log: SixPagesVoicePlugin.log, type: .info,
             externalAtStart ? "OFF" : "ON", externalAtStart ? "yes" : "no")
    } catch {
      throw AudioError.session(error.localizedDescription)
    }
  }

  /// BUILD 19 -- PHASE 2. THE SYSTEM SAID GO.
  ///
  /// Called from provider(_:didActivate:) ONLY. By the time we are here, iOS has activated
  /// our audio session AT CALL PRIORITY and the car's SCO link is being held up as a real
  /// call. Everything that used to sit after setActive(true) in startUnit() lives here now.
  ///
  /// Idempotent: didActivate can fire more than once (route changes, interruption
  /// recovery). The isRunning guard is what makes a second call harmless.
  private func beginAudio() {
    if isRunning {
      // didActivate can fire again (route change, interruption recovery). Harmless — but
      // if Dart is somehow still waiting, release it rather than leaving it hung.
      resolveStart(true)
      return
    }
    do {
      try buildAndStartUnit()
      os_log("beginAudio: VPIO unit running at CALL priority",
             log: SixPagesVoicePlugin.log, type: .info)

      // ╔═══════════════════════════════════════════════════════════════════════╗
      // ║ BUILD 20: THE CALL IS *CONNECTED* HERE. NOT ONE INSTRUCTION EARLIER.  ║
      // ╚═══════════════════════════════════════════════════════════════════════╝
      //
      // buildAndStartUnit() has returned, so the VPIO unit is running and audio is
      // genuinely flowing in both directions. THAT is what "connected" means. Build 19b
      // claimed it from a completion block before any audio existed at all.
      //
      // This is also what settles the CallKit UI off "connecting..." and starts the call
      // duration timer -- and, per the Build 19 theory, what the car's HFP state machine
      // is waiting to be told.
      if let provider = self.callProvider, let uuid = self.currentCallUUID {
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        os_log("CallKit: reported CONNECTED -- audio is live",
               log: SixPagesVoicePlugin.log, type: .info)
      }

      // BUILD 19b: NOW, and only now, is the engine actually running. THIS is the moment
      // Dart's `await _voice.start()` was always waiting for. Honor the old contract.
      resolveStart(true)
    } catch {
      os_log("beginAudio: FAILED -- %{public}@", log: SixPagesVoicePlugin.log, type: .error,
             String(describing: error))
      endAudio()
      resolveStart(false)
    }
  }

  /// Tear the audio engine down WITHOUT touching the call. Idempotent -- both the
  /// didDeactivate path and the explicit stop path can reach it, and it must survive
  /// being called twice.
  private func endAudio() {
    tearDownUnit()
  }

  private func buildAndStartUnit() throws {
    // BUILD 19 FIX: `session` used to be a local `let` inside startUnit()'s do-block. The
    // Phase 1 / Phase 2 split left that binding behind in configureSession(), and this
    // function -- which reads session.sampleRate, session.ioBufferDuration and
    // session.currentRoute -- was orphaned from it. Codemagic caught it three times:
    // "Cannot find 'session' in scope."
    //
    // sharedInstance() is a singleton, so this is the SAME session configureSession()
    // just set up and the SAME one iOS activated at call priority. Re-binding it here is
    // correct, not a patch over a lifetime problem.
    let session = AVAudioSession.sharedInstance()

    // Observe-only: report the route, steer nothing. See the comment block above.
    registerRouteListener()
    // Apple REQUIRES this for .playAndRecord. Its absence is the car-drop suspect.
    registerInterruptionListener()
    interruptionCount = 0
    interruptionResumeFailures = 0
    routeChangeCount = 0
    routeHistory = []
    // BUILD 15: speakerDefaultOn is set in the do-block above, mirroring the category we
    // ACTUALLY passed to setCategory. Do NOT reassign it to `true` here — that was the
    // Build 14 line, and it is only correct when we are alone. In a car it would overwrite
    // `false` with `true`, the guard would lie, and the policy would no-op forever.
    policyApplyCount = 0
    policyFailCount = 0
    preferredInputState = "none"
    // BUILD 18: reset the capture counters HERE, in startUnit, beside every other
    // per-session counter -- NEVER in stopUnit. Hard Rules #6: stopUnit clears state, so a
    // post-teardown strip is meaningless. These must survive teardown by construction.
    captureCallCount = 0
    captureByteCount = 0
    captureFailCount = 0
    lastCaptureStatus = 0

    // ── BUILD 17: ANSWER THE CALL ─────────────────────────────────────────────
    // MUST be here — AFTER setActive(true). Apple: "To set the input, the app's session
    // needs to be in control of routing." Before activation this is a silent no-op.
    //
    // This selects the car's MICROPHONE. Per Apple, iOS then moves the OUTPUT to the
    // matching HFP port on its own. We never touch the output. That is the whole fix:
    // the HFP call finally has audio flowing UP it, so the car has no reason to hang up.
    //
    // Non-fatal by construction. If it fails, Joe still talks — out of the iPad.
    selectPreferredInput()

    // Where did we BEGIN? route= on the strip is post-hoc and only says where we ENDED.
    // Without this, "route=speaker" cannot distinguish "never got the car" from
    // "got the car and lost it" — two different bugs.
    // NOTE: read AFTER selectPreferredInput() so it reflects the route we asked for.
    let startOutputs = session.currentRoute.outputs
    routeAtStart = startOutputs.first.map { routeName($0.portType) } ?? "none"
    logCurrentRoute(prefix: "Route at start")
    os_log("Input at start -> %{public}@ (prefIn=%{public}@)",
           log: SixPagesVoicePlugin.log, type: .info,
           currentInputName(), preferredInputState)

    // BUILD 15: THE "start" POLICY CALL IS DELETED. DO NOT PUT IT BACK.
    //
    // Build 14 called applySpeakerPolicy(reason: "start") right here, after setActive(true),
    // to strip .defaultToSpeaker if a car was already attached. Two things were wrong with
    // that and both are measured, not theorized:
    //
    //   1. TOO LATE. The override had ALREADY fired during setActive(true). The car was
    //      gone before this line was ever reached.
    //   2. IT READ A CORRUPTED ROUTE. hasExternalOutput() looked at currentRoute.outputs,
    //      which the override had just rewritten to `speaker`. It concluded we were alone
    //      and left .defaultToSpeaker ON — cementing the very state it existed to prevent.
    //
    // The category is now decided BEFORE activation, from availableInputs, in the do-block
    // above. There is nothing left for a start-time policy call to fix, and re-adding one
    // would only reintroduce a read of the route at the one moment it is least trustworthy.
    //
    // policyApplies=0 on the strip is the PROOF this worked. It means the category was
    // right from the start. Any nonzero value means we are chasing the route again.

    // ── Layer 4 instrumentation: what rate did the hardware ACTUALLY grant? ───
    // This is the risk-1 verdict. If actualRate == 16000, our clean path is
    // correct and NO converter is needed. If it differs, the frames the unit
    // handles are NOT 16 kHz and a targeted converter is required — but we do
    // not write that until a real device logs the mismatch here.
    let grantedRate = session.sampleRate
    let ioBufDuration = session.ioBufferDuration
    if abs(grantedRate - SixPagesVoicePlugin.targetSampleRate) < 1.0 {
      os_log("SR-CHECK: session granted %{public}.0f Hz — MATCHES 16 kHz. Clean path valid, no converter needed.",
             log: SixPagesVoicePlugin.log, type: .info, grantedRate)
    } else {
      os_log("SR-CHECK: session granted %{public}.0f Hz — DOES NOT MATCH 16 kHz. Converter WILL be required (risk 1 confirmed on this device).",
             log: SixPagesVoicePlugin.log, type: .error, grantedRate)
    }
    os_log("SR-CHECK: ioBufferDuration = %{public}.4f s", log: SixPagesVoicePlugin.log,
           type: .info, ioBufDuration)

    // Build 1: begin building the app-readable diagnostic string.
    let rateVerdict = abs(grantedRate - SixPagesVoicePlugin.targetSampleRate) < 1.0
      ? "MATCHES 16k" : "MISMATCH (converter needed)"
    lastDiagnostics = "granted=\(Int(grantedRate))Hz [\(rateVerdict)]; "
      + "ioBuf=\(String(format: "%.4f", ioBufDuration))s; "

    // ── Build 4: no manual conversion. Record hwRate for diagnostics only. ────
    // The output bus is set to 16 kHz (below); VoiceProcessingIO resamples
    // 16k→hardware internally. Joe's feed enters the ring as raw 16 kHz bytes.
    hwRate = grantedRate
    lastDiagnostics += "playbackPath=VPIO-internal-resample(16k→\(Int(hwRate))Hz); "

    // ── Build 3: compute the priming cushion (~100 ms). Playback is now 16 kHz
    // (the render callback consumes 16 kHz bytes; the unit resamples downstream),
    // so the cushion is 100 ms of 16 kHz mono PCM16 = 16000 * 2 * 0.1 = 3200 B.
    let hundredMs = Int(SixPagesVoicePlugin.targetSampleRate * 2.0 * 0.1)
    primeThresholdBytes = min(hundredMs, SixPagesVoicePlugin.playbackBufferBytes / 2)
    primed = false
    reprimeEvents = 0
    os_log("Build3: primeThresholdBytes = %d (≈100 ms at %{public}.0f Hz)",
           log: SixPagesVoicePlugin.log, type: .info, primeThresholdBytes, hwRate)

    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_VoiceProcessingIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { throw AudioError.noComponent }

    var unitOptional: AudioUnit?
    try checkStatus("AudioComponentInstanceNew", AudioComponentInstanceNew(comp, &unitOptional))
    guard let unit = unitOptional else { throw AudioError.noComponent }
    self.ioUnit = unit

    let inputBus: AudioUnitElement = 1
    let outputBus: AudioUnitElement = 0

    var enableFlag: UInt32 = 1
    try checkStatus("enable input",
      AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                           inputBus, &enableFlag, UInt32(MemoryLayout<UInt32>.size)))
    try checkStatus("enable output",
      AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                           outputBus, &enableFlag, UInt32(MemoryLayout<UInt32>.size)))

    // Input bus (mic → app): keep 16 kHz. Capture is proven clean; leave it.
    var inFormat = AudioStreamBasicDescription(
      mSampleRate: SixPagesVoicePlugin.targetSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

    // Output bus (app → speaker): Build 4 — set 16 kHz CLIENT format. The unit
    // accepts it and resamples 16k→hardware(48k) internally and continuously.
    // This is the documented VPIO behavior (Apple Dev Forums thread/20187): as
    // long as the AU doesn't reject the format, rate conversion is automatic.
    var outFormat = AudioStreamBasicDescription(
      mSampleRate: SixPagesVoicePlugin.targetSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

    try checkStatus("set input-bus client format",
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                           inputBus, &inFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
    try checkStatus("set output-bus client format",
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                           outputBus, &outFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

    var bypass: UInt32 = 0
    try checkStatus("AEC on (bypass=0)",
      AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global,
                           0, &bypass, UInt32(MemoryLayout<UInt32>.size)))

    // Render callback (playback) — Layer 2.
    var renderCallback = AURenderCallbackStruct(
      inputProc: SixPagesVoicePlugin.renderCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    try checkStatus("set render callback",
      AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                           outputBus, &renderCallback,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

    // ── Layer 3: install the INPUT callback (fires when mic frames are ready) ─
    var inputCallback = AURenderCallbackStruct(
      inputProc: SixPagesVoicePlugin.inputCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    try checkStatus("set input callback",
      AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                           inputBus, &inputCallback,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

    // Allocate the scratch buffer the input callback renders into. Sized for a
    // generous callback (VoiceProcessingIO can deliver ~960–1440 frames); we
    // cap at 4096 frames (8192 bytes) which comfortably covers observed sizes.
    captureScratchFrameCap = 4096
    captureScratch = UnsafeMutablePointer<Int16>.allocate(capacity: captureScratchFrameCap)

    playback.clear()
    capture.clear()
    // Build 2: reset diagnostic counters so each session reports fresh numbers
    // (lets us verify underruns drop toward 0 after the fix).
    renderCalls = 0
    underrunEvents = 0
    lastRenderBytesRequested = 0
    lastInputFrames = 0
    // Build 8: reset render-time max and read the mach timebase once (used to
    // convert render-callback ticks → microseconds on the audio thread).
    maxRenderMicros = 0
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    machTimebaseNumer = tb.numer
    machTimebaseDenom = tb.denom

    try checkStatus("AudioUnitInitialize", AudioUnitInitialize(unit))

    // ── Layer 4 instrumentation: what formats did the unit NEGOTIATE? ────────
    // We set 16 kHz client formats on both buses. Read them back to confirm the
    // unit accepted them (vs silently coercing to hardware rate). This is the
    // second half of the risk-1 verdict: even if the session rate differs, the
    // unit may still honor a 16 kHz CLIENT format and convert internally — in
    // which case our rings are fed 16 kHz and no converter is needed.
    logNegotiatedFormat(unit, scope: kAudioUnitScope_Output, bus: inputBus,
                        label: "input-bus client (mic→app)")
    logNegotiatedFormat(unit, scope: kAudioUnitScope_Input, bus: outputBus,
                        label: "output-bus client (app→spk)")

    try checkStatus("AudioOutputUnitStart", AudioOutputUnitStart(unit))
    isRunning = true

    startDrain()
  }

  /// BUILD 19: STOP THE CALL, then the audio. Order matters.
  ///
  /// requestEndCall() tells iOS the call is over, which releases the SCO link cleanly and
  /// lets the car return to what it was doing. iOS then calls provider(_:didDeactivate:),
  /// where the audio engine is torn down.
  ///
  /// We ALSO tear down directly here rather than trusting didDeactivate to arrive. If the
  /// call never started (CXStartCallAction failed) there will be no didDeactivate at all,
  /// and a session that never dies is worse than a redundant teardown. tearDownUnit() is
  /// idempotent, so the double path is safe by construction.
  private func stopUnit() {
    requestEndCall()
    tearDownUnit()
  }

  private func tearDownUnit() {
    // BUILD 19b: never leave a Dart future hanging. If teardown happens while a start is
    // still in flight (stop tapped fast, CallKit refused the call, provider reset), the
    // held FlutterResult must be answered or the Dart side waits forever.
    resolveStart(false)

    stopDrain()
    if let unit = ioUnit {
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
      ioUnit = nil
    }
    isRunning = false
    playback.clear()
    capture.clear()
    // Build 3: reset priming state so a fresh session re-primes cleanly.
    primed = false
    if let scratch = captureScratch {
      scratch.deallocate()
      captureScratch = nil
      captureScratchFrameCap = 0
    }
    // Drop the route listener BEFORE deactivating the session, so a deactivation-
    // triggered route change cannot call back into a half-torn-down engine.
    unregisterRouteListener()
    unregisterInterruptionListener()
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  // MARK: - Capture drain (platform thread → Dart)
  //
  // Pushes whole 640-byte frames up via captureSink, one per available frame.
  // Runs on a serial queue and marshals the sink call — FlutterEventSink must
  // not be invoked from the audio thread. A short interval keeps latency low
  // while emitting Android-identical 640-byte frames. (This is the iOS analog
  // of Android's per-frame `mainHandler.post { eventSink.success(frame) }`.)
  private func startDrain() {
    let queue = DispatchQueue(label: "com.sixpages.voice.capture-drain")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      // Emit every whole frame currently available.
      while let frame = self.capture.readFrame(SixPagesVoicePlugin.frameBytes) {
        let sink = self.captureSink
        DispatchQueue.main.async {
          sink?(FlutterStandardTypedData(bytes: frame))
        }
      }
    }
    drainTimer = timer
    timer.resume()
  }

  private func stopDrain() {
    drainTimer?.cancel()
    drainTimer = nil
  }

  private func checkStatus(_ what: String, _ status: OSStatus) throws {
    if status != noErr {
      os_log("audio: %{public}@ failed (OSStatus %d)",
             log: SixPagesVoicePlugin.log, type: .error, what, status)
      throw AudioError.osStatus(what, status)
    }
  }

  /// Layer 4: read back and log the format the unit actually negotiated on a
  /// given scope/bus. Non-throwing — instrumentation must never break start().
  private func logNegotiatedFormat(_ unit: AudioUnit,
                                   scope: AudioUnitScope,
                                   bus: AudioUnitElement,
                                   label: String) {
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      scope, bus, &asbd, &size)
    if status == noErr {
      let rateMatches = abs(asbd.mSampleRate - SixPagesVoicePlugin.targetSampleRate) < 1.0
      os_log("FMT-CHECK [%{public}@]: %{public}.0f Hz, %d ch, %d-bit — %{public}@",
             log: SixPagesVoicePlugin.log, type: rateMatches ? .info : .error,
             label, asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mBitsPerChannel,
             rateMatches ? "16 kHz honored (rings fed correctly)"
                         : "NOT 16 kHz — converter needed on this bus")
      // Build 1: append to app-readable diagnostics.
      lastDiagnostics += "\(label)=\(Int(asbd.mSampleRate))Hz/\(asbd.mChannelsPerFrame)ch; "
    } else {
      os_log("FMT-CHECK [%{public}@]: read failed (OSStatus %d)",
             log: SixPagesVoicePlugin.log, type: .error, label, status)
      lastDiagnostics += "\(label)=readFail(\(status)); "
    }
  }

  // MARK: - Render callback (playback, audio thread) — Layer 2 + Build 3 priming
  //
  // Build 3: gate consumption on a startup cushion. While NOT primed, output
  // clean silence and DO NOT count an underrun (priming is not starving) until
  // the ring holds primeThresholdBytes (~100 ms). Once primed, read normally.
  // If a normal read returns 0 on a nonzero request (mid-stream stall drained
  // the ring), drop back to unprimed and count a re-prime so the gap re-buffers
  // silently instead of chopping through it.
  private static let renderCallback: AURenderCallback = {
    (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let plugin = Unmanaged<SixPagesVoicePlugin>.fromOpaque(inRefCon).takeUnretainedValue()
    let renderStart = mach_absolute_time()  // Build 8: time this callback
    guard let abl = ioData else {
      ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
      return noErr
    }
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    plugin.renderCalls &+= 1

    // Build 3: priming gate. If not yet primed, wait for the cushion. Emit clean
    // silence and return WITHOUT counting an underrun — this is intentional
    // buffering, not a starve.
    if !plugin.primed {
      if plugin.playback.count >= plugin.primeThresholdBytes {
        plugin.primed = true   // cushion built; fall through to normal read
      } else {
        for buffer in buffers {
          if let mData = buffer.mData {
            memset(mData, 0, Int(buffer.mDataByteSize))
          }
        }
        ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        plugin.recordRenderTime(since: renderStart) // Build 8
        return noErr
      }
    }

    for buffer in buffers {
      guard let mData = buffer.mData else { continue }
      let bytesRequested = Int(buffer.mDataByteSize)
      plugin.lastRenderBytesRequested = bytesRequested
      let provided = plugin.playback.read(into: mData, count: bytesRequested)
      if provided < bytesRequested {
        plugin.underrunEvents &+= 1
        memset(mData.advanced(by: provided), 0, bytesRequested - provided)
        // Build 3: a FULL drain (nothing at all provided) on a nonzero request
        // means the ring emptied mid-stream — a network stall. Re-prime so the
        // gap re-buffers rather than chopping through the burst gap.
        if provided == 0 && bytesRequested > 0 {
          plugin.primed = false
          plugin.reprimeEvents &+= 1
        }
      }
    }
    plugin.recordRenderTime(since: renderStart) // Build 8
    return noErr
  }

  // Build 8: convert elapsed mach ticks → microseconds and keep the session max.
  // Runs on the audio thread; timebase is read once at start. Cheap arithmetic
  // only — no allocation, no locks.
  @inline(__always)
  fileprivate func recordRenderTime(since start: UInt64) {
    let elapsedTicks = mach_absolute_time() - start
    if machTimebaseDenom == 0 { return }
    let micros = Int((elapsedTicks * UInt64(machTimebaseNumer))
                     / (UInt64(machTimebaseDenom) * 1000))
    if micros > maxRenderMicros { maxRenderMicros = micros }
  }

  // MARK: - Input callback (mic, audio thread) — Layer 3
  //
  // Fires when the unit has AEC'd mic frames ready. Unlike the render callback,
  // the input side must PULL: call AudioUnitRender to render `inNumberFrames`
  // into our scratch AudioBufferList, then copy those (already-clean) bytes
  // into the capture ring buffer. The drain (platform thread) emits them.
  private static let inputCallback: AURenderCallback = {
    (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let plugin = Unmanaged<SixPagesVoicePlugin>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = plugin.ioUnit, let scratch = plugin.captureScratch else { return noErr }

    let frames = Int(inNumberFrames)
    // BUILD 18: the callback FIRED. Counted BEFORE the early-return below, so that
    // "VPIO is calling us but the frames are unusable" stays distinguishable from
    // "VPIO never called us at all." Different bugs, different fixes.
    plugin.captureCallCount += 1

    plugin.lastInputFrames = frames
    if frames <= 0 || frames > plugin.captureScratchFrameCap { return noErr }

    let byteCount = frames * 2 // Int16 mono

    // Build an AudioBufferList pointing at our scratch buffer for the render.
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(byteCount),
        mData: UnsafeMutableRawPointer(scratch)))

    let status = AudioUnitRender(unit,
                                 ioActionFlags,
                                 inTimeStamp,
                                 inBusNumber,
                                 inNumberFrames,
                                 &bufferList)
    if status != noErr {
      // A render error here is a real failure; report it (do NOT swallow it as
      // noErr — but also do NOT inherit AECAudioStream's inverse bug of
      // returning an error on SUCCESS. This branch is genuine failure only).
      //
      // BUILD 18: AND COUNT IT. Until now this status went up the stack and VANISHED --
      // no log, no counter, nothing on the strip. If VPIO cannot render from the car's
      // HFP input bus, it has been failing SILENTLY, inside a real-time audio callback,
      // on every drive we have ever taken.
      //
      // captureFails > 0 in the car WITH renderCalls climbing = the mic was SELECTED but
      // never OPENED. Dead uplink. The car's watchdog then hangs up at 5s exactly as it is
      // designed to. That is the whole bug, and lastCaptureStatus names the OSStatus.
      //
      // NO os_log HERE. Real-time callback; logging can block the render deadline. The
      // counters ARE the report. That is what they are for.
      plugin.captureFailCount += 1
      plugin.lastCaptureStatus = status
      return status
    }

    // Copy the clean frame into the capture ring; drain emits it as 640-byte
    // frames. Variable inNumberFrames is fine — the ring is byte-oriented and
    // the drain reassembles fixed 640-byte frames (July 7 risk 2: buffer-
    // agnostic drain, never assume a fixed callback frame size).
    plugin.capture.write(from: UnsafeRawPointer(scratch), count: byteCount)

    // BUILD 18: bytes that ACTUALLY REACHED the capture ring. The substitution standard
    // for the uplink: not "the callback ran" (captureCalls), not "it did not error"
    // (captureFails), but REAL AUDIO ARRIVED. Prove the right thing appeared -- never
    // merely the absence of the wrong thing.
    plugin.captureByteCount += byteCount

    return noErr // July 7 risk 3: return noErr on success.
  }
}

// MARK: - EventChannel (capture)

extension SixPagesVoicePlugin: FlutterStreamHandler {
  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.captureSink = events
    os_log("capture onListen: stream connected", log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.captureSink = nil
    os_log("capture onCancel: stream released", log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// BUILD 19: CXProviderDelegate -- THE SEAM IOS OWNS
//
// This is the half of the contract we never wrote. iOS activates our audio session at
// CALL priority and calls didActivate; THAT is when audio may begin. Apple, WWDC 2016
// S230: "this is the point where we begin processing our call's audio."
//
// DO NOT start audio anywhere else. DO NOT call setActive(true) anywhere. The elevated
// priority granted here is the entire reason the car holds the SCO link open, which is
// the entire reason this build exists.
// ══════════════════════════════════════════════════════════════════════════════
extension SixPagesVoicePlugin: CXProviderDelegate {

  /// The system tore down all calls (e.g. the provider was reset). Everything must stop.
  public func providerDidReset(_ provider: CXProvider) {
    os_log("CallKit: providerDidReset -- tearing everything down",
           log: SixPagesVoicePlugin.log, type: .info)
    currentCallUUID = nil
    callKitState = "none"
    endAudio()
  }

  /// Our CXStartCallAction is being performed. Apple: CONFIGURE the session here, do NOT
  /// activate it, and do NOT start call audio here -- audio may only begin once the system
  /// has activated the session at elevated priority in didActivate. We already configured
  /// the session in startUnit() (ahead of the call, which is Apple's own workaround for the
  /// first-launch didActivate bug), so there is nothing left to configure.
  ///
  /// BUILD 20: BUT THERE IS SOMETHING LEFT TO REPORT, AND ITS ABSENCE IS WHY 19b WAS DEAD.
  ///
  /// The outgoing call MUST be reported as connecting from INSIDE this delegate method,
  /// BEFORE fulfill(). Build 19b fulfilled bare and reported from the CXCallController
  /// completion block instead -- a separate async path with no ordering guarantee against
  /// this one. The call could be reported connected before it was fulfilled, the system
  /// never elevated the session, and provider(_:didActivate:) never fired.
  ///
  /// The order below is the one every reference CallKit implementation uses:
  ///     report startedConnecting  ->  fulfill  ->  (system elevates)  ->  didActivate
  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    os_log("CallKit: CXStartCallAction performed -- reporting connecting, then fulfilling",
           log: SixPagesVoicePlugin.log, type: .info)

    // BUILD 20: report on THIS path, in THIS order, before fulfill(). Not from the
    // controller's completion block. nil == now, which is honest here: we ARE beginning
    // to connect at this instant.
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)

    action.fulfill()
  }

  /// The user (or we) ended the call. Stop the audio; do not re-request an end.
  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    os_log("CallKit: CXEndCallAction performed",
           log: SixPagesVoicePlugin.log, type: .info)
    callKitState = "ended"
    currentCallUUID = nil
    endAudio()
    action.fulfill()
  }

  /// ★ THE MOMENT THE WHOLE BUILD TURNS ON. ★
  ///
  /// iOS has activated our session AT CALL PRIORITY. The car's SCO link is now being held
  /// up as a genuine call -- the declaration Android has always made via requestAudioFocus
  /// and iOS never made at all. NOW we build the VPIO unit and start the audio.
  ///
  /// If this never fires, ckActivates=0 on the strip and NO AUDIO EVER STARTS. That is the
  /// known first-launch bug, and it is the first thing to check if the desk test is silent.
  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    callKitActivateCount += 1
    callKitState = "active"
    os_log("CallKit: didActivate -- session live at CALL priority. Starting audio.",
           log: SixPagesVoicePlugin.log, type: .info)
    beginAudio()
  }

  /// iOS deactivated the session. The call is over; the audio engine goes with it.
  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    os_log("CallKit: didDeactivate -- stopping audio",
           log: SixPagesVoicePlugin.log, type: .info)
    endAudio()
  }
}
