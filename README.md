# WiFi Secure Call

## Phone-account foundation

Phone number is the account identity. A server-generated SMS OTP verifies control of the number; SMSClub only delivers the message, and Apple ID is not required. One verified phone maps to one AccountID, while one iPhone installation may securely store multiple account sessions and switch between them. Raw access and refresh tokens are stored in Keychain, not UserDefaults.

Apple Watch links to an authenticated iPhone account through the server over the Internet, so Bluetooth and WatchConnectivity are not required. Current calls still use the legacy A/B `/v1` routing during this foundation phase. Media remains protected by TLS/WSS and is not end-to-end encrypted; account-to-account routing and E2EE are later phases.

Independent iPhone and Apple Watch MVP for live Internet audio calls over HTTPS/WSS.

## Calling from the watch, through the iPhone

The watch no longer places its own call. It hands the number to the paired iPhone
over WatchConnectivity, and the iPhone owns the call: it resolves the number,
starts the call through the existing call stack and the CallKit session, and
reports every state change back to the wrist.

```
Watch dialpad ──WCSession──▶ iPhone: resolve ──▶ CallKit call ──▶ server
      ▲                          │
      └──────── call.state ──────┘
```

| File | Role |
| --- | --- |
| `Shared/WatchBridge/WatchBridgeMessage.swift` | Property-list message format shared by both sides |
| `Watch/WatchCallBridge.swift` | Activation, a durable outbox, delivery and retries |
| `iOS/IOSWatchCallBridge.swift` | Session lifecycle, request handling, state reporting |
| `iOS/IOSCallKeepAlive.swift` | Keeps the iPhone awake while a call is up |

### Why a call used to be lost after the screen went dark

Three separate things caused it, and each one is addressed:

1. **The iOS session deactivated and never came back.** `WCSession` is deactivated
   when the watch link is rebuilt and when the watch switches. Nobody reactivated
   it, so the bridge worked once after launch and then stopped.
   `sessionDidDeactivate` now calls `activate()` again, and activation state is
   reflected in the UI instead of being assumed.
2. **A dial request only existed in memory.** The watch is suspended seconds after
   the wrist goes down, so a request that was not delivered was gone.
   `WatchCallOutbox` writes it to disk before anything is attempted, retries it on
   activation, on reachability changes and on foreground, expires it after five
   minutes so an old request cannot ring later, and deduplicates by request id so
   a retry cannot call twice.
3. **`sendMessage` was used whether or not the peer was awake.** It only works
   while both apps are running. When the watch is asleep the request now goes out
   as `transferUserInfo`, which the system delivers when the iPhone next runs,
   and the iPhone answers through `updateApplicationContext`, which survives the
   watch waking later.

### Incoming calls

The server sends a VoIP push to the iPhone. PushKit wakes the app, the existing
CallKit path reports the call, and `IOSWatchCallBridge.notifyIncoming` mirrors it
to the watch. The watch does not create a second CallKit call of its own: the
system already rings the paired watch for a call reported by the iPhone, and a
second report would ring twice. The watch shows the caller and points at the
system banner.

### Keeping the session alive

`IOSCallKeepAlive` holds a background task and pings the watch every ten seconds
**while a call is in progress** — that is the window in which Apple's rules allow
an app to stay resident, because the call owns the audio session.

There is deliberately no always-on silent audio stream. A silent stream used only
to stay alive is rejected under App Review guideline 2.5.4 and is stopped by the
system as soon as the audio session stops producing sound, so it would not fix the
symptom it pretends to fix. Between calls the app is woken by a VoIP push, which
is the supported mechanism and the one that works after hours of sleep.

## Call audio on Apple Watch

Call audio runs on the device that places or answers the call. On the watch that means the microphone capture
and the remote voice track are produced by the Apple Watch itself, with CallKit for the system call UI and
PushKit for incoming calls; no paired iPhone process participates in the media path. The watch app exposes a
secure dialer for numbers, a user call, and a linked-device call that keeps the local media leg on the watch.

watchOS constraints and the reasoning behind the current media transport are documented in
`Docs/WatchAudioArchitecture.md`. Carrier Wi-Fi Calling provisioning for the companion device remains
unavailable to third-party apps, see `Docs/CarrierCallingPublicAPIResearch.md`.

## Local configuration

Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` and replace both values with distinct random 256-bit bearer tokens. The file is intentionally ignored by Git. Matching values are supplied to the server as protected environment variables.

The MVP protects signaling and media in transit with system TLS/WSS. It does not claim end-to-end encryption or server-blind media.

## GitHub Actions and TestFlight

`.github/workflows/ios-build.yml` runs on the `xcode-27` image, the same Swift 6.4 toolchain CircleCI uses, because the carrier probe compiles behind `#if compiler(>=6.4)`.

| Job | Runs on | Purpose |
| --- | --- | --- |
| `validate` | pull requests, pushes | Unsigned build that compiles the iPhone target and the embedded Apple Watch target |
| `package` | pushes to `main`, tags, manual dispatch | Builds the app bundle without signing and packs it as `WiFiSecureCall-<configuration>-<build>-unsigned.ipa` |
| `publish` | after `package` | Attaches the `.ipa` to a GitHub Release: the tag name for `v*` tags, otherwise the rolling `ci-latest` release, replaced on every run |
| `testflight` | manual dispatch only | Optional signed build and TestFlight submission, needs only the App Store Connect API key listed below |
| `watch-build.yml` | changes to `Watch` or `Shared/WatchBridge` | Compiles the watch target on its own |
| `secrets.yml` | push, pull request, weekly | gitleaks over the full history; `.gitleaks.toml` records the reviewed false positives |

The default path needs no Apple certificate, no provisioning profile and no App Store Connect key, and no secret at all: the release upload uses the built-in `GITHUB_TOKEN`. Without `IOS_BEARER_TOKEN` and `WATCH_BEARER_TOKEN` the artifact is built in the Debug configuration, because the Release build phases validate those tokens; with them it is built in the Release configuration.

**The published `.ipa` is unsigned.** It contains the iPhone app and its embedded Apple Watch app, and it proves the build was compiled for both platforms, but Apple only accepts signed bundles on a device. Re-sign it with your own certificate, or configure the credentials below and use the `testflight` job.

Repository secrets, all optional for the default path:

| Secret | Used for |
| --- | --- |
| `IOS_BEARER_TOKEN`, `WATCH_BEARER_TOKEN` | write `Config/Secrets.xcconfig`, which the Release build phases require, and enable the Release configuration |
| `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_PRIVATE_KEY` | the App Store Connect API key, the only Apple credential the `testflight` job needs |
| `GH_PAT` | optional, only to publish the release with a personal token instead of `GITHUB_TOKEN` |

Signing is automatic. The project pins manual signing in its Release configurations, but the `testflight` job overrides that from the command line and passes `-allowProvisioningUpdates` with the API key, so `xcodebuild` creates or refreshes the Apple Distribution certificate and both provisioning profiles itself. Nothing to upload but the key: no `.p12`, no password and no `.mobileprovision`.

`APPSTORE_PRIVATE_KEY` accepts the contents of `AuthKey_<KEY_ID>.p8` pasted as PEM, as base64, or as one line with `\n` escapes, so it does not matter how the secret was filled in. The key must belong to a role with the Developer role in App Store Connect, and it is the only secret that leaves Apple; `xcodebuild` reuses it for the upload.
