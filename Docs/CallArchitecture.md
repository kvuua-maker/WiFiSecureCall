# Call architecture: two modes that must never be mixed

Status: canonical description of how calls worked in this repository, verified
against the code at the commits below. Anything that changes a number or a file
listed under *Invariants* is a change to this document's contract.

Scope: the iPhone app (`iOS/`), the Apple Watch app (`Watch/`), the shared call
stack (`Shared/`) and the Go server in the companion repository
`kvuua-maker/WiFiSecureCallServer`.

## The two modes

| | **Mode A — our own call** | **Mode B — a phone call** |
|---|---|---|
| Path | Watch → Internet → our VPS → Internet → iPhone | Watch → watchOS Phone → iPhone/Continuity → SIM/eSIM → carrier |
| Who carries the voice | our app (`AudioEngine` + WSS) | Apple's telephony stack and the carrier |
| Does the VPS see audio | yes, it relays frames | no, it sees nothing |
| Works on different networks | yes | only inside Apple's local Continuity environment |
| Initiated by | `Call` / `Call iPhone` in the app | `Dial number` → `tel:` |

A change that mixes them — for example assuming the carrier's audio can be
captured, or routing a mode A call through the system dialler — breaks the
product. Everything below keeps them apart.

## Verified references

| What | Revision |
|---|---|
| Client, Mode A golden | `cb85c4d` — `checkpoint/build19-known-good-v2` |
| Server, Mode A golden | `d208734` |
| Client, Mode B | `3ee128b` — `checkpoint/build26-direct-system-dial-validation` |
| Client, telephony experiment | `cf113ae` — `checkpoint/build29-dual-role-cellular-probe` |

Physically verified at the time: Mode A worked in both directions with full duplex
audio between a watch and an iPhone on **different** Wi-Fi networks with Bluetooth
off; Mode B worked only while both devices shared the local network environment.

## Mode A: how a call runs

### Signalling

HTTPS REST on the VPS, account API under `/v2`:

```
POST /v2/calls                 create
GET  /v2/calls/{id}            poll
POST /v2/calls/{id}/{action}   accept / reject / cancel / end
```

Server call states: `ringing`, `accepted`, `rejected`, `cancelled`, `expired`,
`ended`. Each call carries `callID`, caller/callee account and device identifiers,
and on accept the server issues a **separate media token for each side**
(`internal/accountmedia` validates `(callID, side, token)` with `side` being
`caller` or `callee`).

Client files: `Shared/CallSignaling.swift`, `Shared/AccountAPIClient.swift`,
`Shared/CallSession.swift`.

### Waking the other device

APNs with PushKit (`PKPushType.voIP`) for the iPhone, and for the watch an alert
push first, VoIP second — `selectAccountIncomingPush` in `internal/server/v2.go`
prefers the alert token for `watchOS` when notifications are authorised. Push
tokens are registered per `accountID + deviceID`.

Client files: `iOS/IOSNotificationController.swift`,
`Watch/WatchNotificationController.swift`.

### CallKit

`CXProvider`, `CXCallController`, `CXTransaction`, `CXStartCallAction`,
`CXAnswerCallAction`, `CXEndCallAction`, `CXSetMutedCallAction`, `CXCallUpdate` on
both platforms (`Watch/WatchCallKitAdapter.swift`, `iOS/IOSCallKitAdapter.swift`).

CallKit owns the call lifecycle and the audio session. **It does not carry audio**
— the voice path is ours.

### Audio capture and playback

`Shared/AudioEngine.swift` uses `AVAudioSession` (`playAndRecord`, `voiceChat`;
iOS adds `allowBluetoothHFP` and `defaultToSpeaker`), `AVAudioEngine`,
`AVAudioSinkNode` for capture, `AVAudioPlayerNode` for playback, and two
`AVAudioConverter`s for the hardware↔network rate change.

Voice processing is **mandatory**: `setVoiceProcessingEnabled(true)` followed by a
guard on `isVoiceProcessingEnabled`, which throws if the platform refuses. This is
deliberate — a device without voice processing produced echo, so the build fails
loudly instead of shipping a bad call.

### Network audio format (the contract)

| Parameter | Value |
|---|---|
| Sample rate | 16 000 Hz |
| Channels | 1 (mono) |
| Sample type | signed Int16, interleaved |
| Samples per frame | 320 |
| Frame duration | 20 ms |
| Payload bytes | 640 |

### Wire packet

`Shared/AudioPacket.swift`: a 34-byte header — version, type (`audio = 1`,
`end = 2`, `ping = 3`), `callID` UUID, `sequence` UInt64,
`timestampMicroseconds` UInt64 — followed by exactly 640 payload bytes for audio.

### Transport

`Shared/WebSocketMediaTransport.swift` — WSS via `URLSessionWebSocketTask`,
`Authorization: Bearer <mediaToken>`, query `callID`, `side` (legacy `role`) and
`protocolVersion=2`, endpoint `/media`.

At Build19 the transport is protected by TLS only. Application-level encryption
(`Shared/EncryptedAudioPacket.swift`, `CallAudioCryptor`, AES-GCM with a 2048-entry
replay window) was added later in `3893eab`; it is not part of the Build19 golden
path and should not be attributed to it.

### Server media

`internal/media` (legacy A/B) and `internal/accountmedia` (account calls): a room
per `callID`, both sockets authenticated with their own token, frames relayed
verbatim between the two sides. The server never decodes audio.

### Jitter and reconnect

`JitterBuffer` defaults: initial 100 ms, maximum 240 ms, late grace 20 ms, playout
tick 20 ms via `DispatchSourceTimer`. It reorders, drops duplicates and late
frames, rebases on large sequence jumps and inserts silence for a gap.

`ReconnectSchedule`: 0.25 s, doubling to a 2 s cap, total budget 10 s. The socket
sends a ping every 25 s.

## Why Mode A worked across networks

Both devices connect **outbound** to the same VPS; the server pairs their media
sockets. Nothing depends on the devices sharing a network, on Bluetooth, or on
iCloud. This is the property that Mode B lacks.

## Mode B: how a phone call runs

`WatchSystemDialerView` builds `tel:+380…` and calls
`WKApplication.shared().openSystemURL(url)`. From that moment the app is no longer
the media engine: watchOS hands the call to the system Phone, Apple's Continuity
relay reaches the iPhone, and the carrier places the call on the active SIM/eSIM.

Coordination only — never audio — runs over WatchConnectivity
(`WatchSystemDialCoordinator`, `IOSSystemDialCoordinator`) with messages
`prepareSystemDial`, `prepareSystemDialReply`, `systemDialHandoff`,
`systemDialResult`, plus `CXCallObserver` for observing that an outgoing carrier
call appeared, connected and ended. `CXCallObserver` exposes **state only**: no PCM.

Caller ID on the far end is the carrier line's identity, not our `accountID`.

The physical result observed at the time — same network passes, different networks
fail — is a property of Apple's relay, not of our code: nothing in Mode B reads the
local network.

## Build29: what the telephony experiment proved

`cf113ae` uses `TelephonyConversationManager.sharedInstance.startCellularConversation`
to start a native cellular conversation, with calling/dialing entitlements. It
proved the app can ask the system to start a carrier call and that the call connects
with two-way native audio and working mute.

It did **not** prove that the app can read the carrier downlink PCM and forward it —
that remains unavailable to third-party apps. Build29 therefore does not replace
either mode.

## Accounts and watch pairing

`POST /v2/auth/phone/start` → `POST /v2/auth/phone/verify` produce `accountID` plus
access/refresh tokens. Tokens live in the Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; only non-secret metadata goes to
`UserDefaults`.

Watch pairing: `POST /v2/watch-link/start` returns a six-digit code, the iPhone
claims it with `POST /v2/watch-link/claim`, the watch polls
`POST /v2/watch-link/status`, then stores its own session. One account then has two
registered devices.

## Invariants

These are the values a change must not silently alter. `Tests/CallArchitectureInvariantTests.swift`
and `scripts/check-architecture.sh` enforce them in CI.

1. Network audio format: 16 000 Hz, mono, Int16, 320 samples, 640 bytes, 20 ms.
2. `AudioPacket.headerSize == 34`, audio payload exactly 640 bytes.
3. `JitterBuffer` defaults 100 / 240 / 20 ms with a 20 ms playout tick.
4. `ReconnectSchedule` starts at 0.25 s, caps at 2 s, budget 10 s; ping every 25 s.
5. Mode A media goes over WSS to our own `/media`; Mode B goes over `tel:`.
6. No SIP, WebRTC, LiveKit, Twilio or other third-party media/SDK dependency.
7. WatchConnectivity carries commands and diagnostics, never audio.

## Known limits

- The carrier's PCM is not available to a third-party app. No free, public bridge
  between our Mode A audio and the Mode B carrier leg exists.
- Making Apple's Continuity relay work outside the local environment is not
  controllable from an app.
- A free path to PSTN therefore requires terminating the call ourselves, which
  needs a paid gateway — out of scope for this repository.
