# Watch audio architecture: what watchOS actually allows

Status: engineering analysis for the call path in this repository. Scope: the Apple Watch target
(`WiFiSecureCallWatch`), the shared call stack in `Shared/`, and the iPhone app in `iOS/`.

## Result

**Audio-only-on-Apple-Watch is architecturally possible and does not require the iPhone app to carry the
media.** The claim that "Apple does not allow the audio stream on Apple Watch" is not correct for this
product's calling path. The previous implementation did not fail because of an Apple restriction; it failed
because of four concrete engineering defects and one routing decision that made the iPhone look mandatory.

What *is* genuinely unavailable to a third-party app is the opposite direction: making the **carrier's**
Wi-Fi Calling / IMS stack on an iCloud-connected device join a call. That part of the earlier research
(`Docs/CarrierCallingPublicAPIResearch.md`, `NO_PUBLIC_PATH_FOUND`) remains correct and is unrelated to where
the microphone and speaker run.

## Why watchOS audio is allowed

| Capability | watchOS status | Use in this project |
| --- | --- | --- |
| `CallKit` (`CXProvider`, `CXCallController`, CallKit UI, system call recents) | Supported, watchOS 2+ | `Watch/WatchCallKitAdapter.swift` |
| `AVAudioSession` category `.playAndRecord` + mode `.voiceChat` | Supported | `Shared/AudioEngine.swift` |
| `AVAudioEngine` + `AVAudioPlayerNode` capture/playback of a live call | Supported (this is how Apple's own Phone app renders cellular and Wi-Fi calls on the watch) | `Shared/AudioEngine.swift` |
| Microphone permission (`AVAudioApplication` / `AVAudioSession.recordPermission`) | Supported | `AudioEngine.ensureRecordPermission()` |
| `PushKit` VoIP push + reporting an incoming call | Supported | `Watch/WatchNotificationController.swift` |
| Background audio during a call | `UIBackgroundModes` = `audio` (declared in `Watch/Info.plist`) | required so the app is not suspended when the wrist drops |

Nothing in the watchOS application sandbox prevents this app from capturing the microphone and rendering a
remote voice track on the watch. No `WatchConnectivity` and no paired-iPhone process is involved: signaling and
media are HTTPS/WSS to the server, and each device owns its own media leg.

`LiveCommunicationKit` (watchOS 10.4+) is Apple's newer system VoIP stack, and it is *not* required here: it is
for apps that hand call control to the system VoIP service, whereas this app runs its own media pipeline.
A WebRTC engine would also work on watchOS in principle, but it adds a second, redundant media stack; the
existing PCM-over-WSS path is sufficient and is what was hardened below.

## Why audio did not work on the watch

### 1. Voice-processing I/O was mandatory (fatal on any platform that lacks it)

`startOnControlQueue` used to do:

```swift
try input.setVoiceProcessingEnabled(true)
guard input.isVoiceProcessingEnabled, output.isVoiceProcessingEnabled else { throw ... }
```

Echo cancellation / noise suppression are a quality feature, not a correctness requirement. Treating them as a
hard precondition means that any device or OS build where VPIO is unavailable throws `CallFailure.audioFailed`
and the call never reaches `.active`. Voice processing is now best-effort: the app tries to enable it, emits
`voice_processing_enabled` / `voice_processing_disabled` with the real flags, and continues with the plain
input node when it is not available.

### 2. Audio-session interruptions were logged and ignored

A cellular call, Siri, or an alarm interrupts the session. The observer only wrote a diagnostic, so capture and
playback kept running against a dead I/O path, producing silence for the rest of the call. Interruption
handling now pauses the capture worker, the player and the engine on `.began`, and on `.ended` reactivates the
session, restarts the graph and resumes the capture worker when the system reports `.shouldResume`. If the
restart fails, the existing one-shot audio recovery budget takes over. Frames that arrive during the pause are
dropped rather than reported as playback failures, otherwise an interruption would burn the recovery budget
and could fail an otherwise healthy call.

### 3. Route changes were logged and ignored

Connecting AirPods or a hearing aid mid-call changes the hardware output format; the conversion ratio built at
call setup is then wrong and playback goes silent or distorted. The engine now remembers the hardware output
sample rate and reports a configuration change when it actually changes, which routes into the existing
one-shot recovery that rebuilds the graph. Cosmetic route notifications no longer consume that budget.

### 4. The audio session was never deactivated

`stop()` tore down the graph but left the session active, so other apps' audio stayed interrupted after a call
ended. Teardown now deactivates the session with `.notifyOthersOnDeactivation`, and the session category is
re-applied on every start so a stale category from an interruption cannot survive into the next call.

### 5. Routing, not platform policy, put the call on the iPhone

`WatchRootView` called `startPreferredCall(targetPlatform: "iOS")`, which resolves the *other* device of the
same account and requires exactly one match, and the device filter excluded this installation. The result was
that the only "own account" call the watch could place was a call whose peer had to be an iPhone. Cross-user
calls were already watch-local (`MediaPeerIdentity.account(side)` is derived from the local side), but they
were not the visible primary action.

`NotificationRuntime.startLocalPeerCall(accountID:)` now expresses "this device keeps its own media leg":
it prefers a ready peer on the same platform, falls back to the other platform, and only the *remote* leg
needs another registered device. `startPreferredCall(targetPlatform:accountID:)` keeps its exact previous
semantics (single-platform filter, `targetUnavailable` / `targetAmbiguous`) so existing contracts are unchanged.

## The real watchOS constraint: TN3135

Apple's technical note TN3135 ("Low-level networking on watchOS") classifies networking as:

* **High-level** — HTTP/HTTPS in `URLSession`. Allowed for all apps.
* **Low-level** — Network framework, `Stream`, and explicitly `URLSessionStreamTask` and
  `URLSessionWebSocketTask`.

watchOS permits low-level networking only for an app that is *actively streaming audio*. Outside that case
`NWPathMonitor` stays `.unsatisfied` and connections fail with `ENETDOWN`. Since watchOS 9 the restriction is
enforced reliably.

`WebSocketMediaTransport` is built on `URLSessionWebSocketTask`, so the media path is low-level on both
platforms. On watchOS it is legal only while call audio is running, and developers report the path being
withdrawn and restored on a roughly 36-39 second cycle even with an active audio session. Two consequences are
handled in code:

* Media reconnect on watchOS uses a wider budget (`CallTimeouts.mediaReconnectTotal` = 45 s versus 10 s on
  iOS) so an expected path revocation heals inside the call instead of failing it with `networkLost`.
* Call audio must actually be running for the media path to exist at all, which is another reason the audio
  graph must start reliably rather than being abandoned at the first failure.

If a future revision of the server can expose media over plain HTTPS, switching the watch transport to
high-level networking removes this class of risk entirely. That requires a server-side change, so it is not
done here.

## Watch-side call routing after this change

| Watch action | Media leg on the watch | Peer required |
| --- | --- | --- |
| `Call number` (new secure dialer, `Watch/WatchSecureDialerView.swift`) | yes, local | the resolved number must be reachable over the app's own service |
| `Call user` | yes, local | the target user |
| `Call linked device` (`startLocalPeerCall`) | yes, local | one ready device on the server, watch preferred, iPhone accepted |
| `Cellular call` (`WatchSystemDialerView`) | no, hands off to the system Phone app | carrier |

Incoming calls on the watch report through `WatchCallKitAdapter` and start their own local media leg on
answer, so the ringing side is not dependent on the iPhone either.

## iPhone side

The iPhone app shares `AudioEngine`, so the interruption, route-change and session-deactivation fixes apply to
it as well. Additionally, `IOSNotificationController` now re-reads the notification authorization on every
activation and re-uploads the device capabilities when it changed; before this, a user who granted permission
after launch kept a stale `alertPush`/`notificationsAuthorized` capability on the server, so the device list
looked ready while incoming calls were not routed there.

## Latency

`AudioPlayoutController` buffered 100 ms before starting playout with a 240 ms ceiling. That is 200 ms of
round-trip delay for no benefit on a healthy network. The controller now uses 60 ms initial and 120 ms maximum
with the unchanged two-tick late-arrival grace, which removes 40 ms of added delay while keeping the same
underrun concealment behaviour.

## Open items that need hardware or a product decision

1. `Watch/Info.plist` declares `UIBackgroundModes` with `audio`, `remote-notification` and `voip`. Apple documents
   `audio` for watchOS; `remote-notification` and `voip` are documented for iOS only. They were left in place
   because removing them cannot be validated without a watch and could change how VoIP pushes wake the app.
   Confirm with App Store Connect validation and on-device incoming-call delivery before touching them.
2. The media transport on watchOS is a low-level WebSocket and therefore depends on the TN3135 audio-streaming
   exception. If periodic path revocations prove unacceptable, move the media API to HTTPS long-polling; that
   needs a server change.
3. Apple requires a VoIP push to be reported to CallKit even when the receiving account cannot join the call.
   This codebase deliberately ignores such a push (`new_call_blocked` / `account_missing`) because
   `testIncomingV2MissingAccountIgnoredAndSignedInAccountUsesSameProvider` locks that behaviour in. If the
   server can push to devices that have no linked account, that test contract has to change first.
4. CallKit occasionally omits `didActivate` on recent iOS versions. The current design treats that as an
   activation timeout and fails the call cleanly. A future revision could fall back to activating the session
   itself, but that must not start audio before activation, which several tests explicitly forbid.

## Verification status

These changes were reviewed statically; `xcodebuild` and the XCTest suite were executed by CI on the
`xcode-27` image through `.github/workflows/ios-build.yml`. Device-only behaviour still needs confirmation:

1. Watch-only outgoing call reaches `.active` with non-zero capture and playback metrics
   (`first_mic_nonzero_signal`, `first_network_audio_nonzero_sent`, `first_remote_audio_nonzero`).
2. The call survives a background/lock cycle on the watch.
3. An incoming call on the watch can be answered with audio on the watch and ended from CallKit.
4. `audio_reconnect` events show up if the media path is revoked mid-call, and the call does not fail.