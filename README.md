# WiFi Secure Call

## Phone-account foundation

Phone number is the account identity. A server-generated SMS OTP verifies control of the number; SMSClub only delivers the message, and Apple ID is not required. One verified phone maps to one AccountID, while one iPhone installation may securely store multiple account sessions and switch between them. Raw access and refresh tokens are stored in Keychain, not UserDefaults.

Apple Watch links to an authenticated iPhone account through the server over the Internet, so Bluetooth and WatchConnectivity are not required. Current calls still use the legacy A/B `/v1` routing during this foundation phase. Media remains protected by TLS/WSS and is not end-to-end encrypted; account-to-account routing and E2EE are later phases.

Independent iPhone and Apple Watch MVP for live Internet audio calls over HTTPS/WSS.

## Standalone SIP client on Apple Watch

The watch no longer needs an iPhone to place a call. It registers with a SIP
server itself, negotiates an audio stream and runs the media path on the watch:

| Layer | File | Responsibility |
| --- | --- | --- |
| Messages | `Shared/SIP/SIPMessage.swift` | Parses and renders SIP requests and responses, including folded headers and LF endings |
| Authentication | `Shared/SIP/SIPDigest.swift` | Answers 401 and 407 with MD5 or SHA-256 and `qop=auth` |
| Transport | `Shared/SIP/SIPTransport.swift` | SIP over a secure WebSocket (RFC 7118) with keepalives and reconnect backoff |
| Description | `Shared/SIP/SDP.swift` | Builds and reads the audio stream without touching crypto or candidate lines |
| Codec | `Shared/SIP/G711.swift` | PCMU and PCMA, the codecs every trunk supports |
| Media | `Shared/SIP/RTPMediaSession.swift` | A real UDP socket so the SDP offer names the port that is used, plus a jitter buffer |
| Audio | `Shared/SIP/SIPAudioEngine.swift` | An 8 kHz capture and playout path |
| Signalling | `Shared/SIP/SIPClient.swift` | Registration, one dialog, CANCEL, ACK for 2xx and non-2xx, BYE, DTMF over INFO |
| Session | `Watch/SIPCallSession.swift` | CallKit, the media socket and the screen state |

The SIP account is entered on the watch and stored in the keychain
(`Watch/SIPAccountStore.swift`); nothing about it comes from the paired iPhone.
A bare number is dialled at the account's domain, which is the SIP gateway that
routes it to the trunk; a full `sip:` URI is used as it stands.

Incoming calls are reported to CallKit while the app is running. Delivering an
incoming call to a watch that is not running needs a VoIP push from the server,
which is a separate piece of work and is not implemented here.

The server side of this — registrar, trunk routing and the RTP relay — is
`cmd/sipgateway` in the companion repository.

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
