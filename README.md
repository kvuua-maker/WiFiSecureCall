# WiFi Secure Call

## Phone-account foundation

Phone number is the account identity. A server-generated SMS OTP verifies control of the number; SMSClub only delivers the message, and Apple ID is not required. One verified phone maps to one AccountID, while one iPhone installation may securely store multiple account sessions and switch between them. Raw access and refresh tokens are stored in Keychain, not UserDefaults.

Apple Watch links to an authenticated iPhone account through the server over the Internet, so Bluetooth and WatchConnectivity are not required. Current calls still use the legacy A/B `/v1` routing during this foundation phase. Media remains protected by TLS/WSS and is not end-to-end encrypted; account-to-account routing and E2EE are later phases.

Independent iPhone and Apple Watch MVP for live Internet audio calls over HTTPS/WSS.

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

Signing is automatic. `Config/Base.xcconfig` sets `CODE_SIGN_STYLE = Automatic` and pins no certificate or profile, and the `testflight` job passes `-allowProvisioningUpdates` with the API key, so `xcodebuild` creates or refreshes the Apple Distribution certificate and both provisioning profiles itself. Nothing to upload but the key: no `.p12`, no password and no `.mobileprovision`.

`APPSTORE_PRIVATE_KEY` accepts the contents of `AuthKey_<KEY_ID>.p8` pasted as PEM, as base64, or as one line with `\n` escapes, so it does not matter how the secret was filled in. The key must belong to a role with the Developer role in App Store Connect, and it is the only secret that leaves Apple; `xcodebuild` reuses it for the upload.

Before it builds anything, the `testflight` job signs a real JWT with the key and asks App Store Connect who it is. That check exists because `xcodebuild` reports every credential problem identically, as `Communication with Apple failed: a non-HTTP 200 response was received (401)`, without saying which of the three secrets is wrong, and a 401 that is really a mismatched key looks exactly like a 401 that is really an expired one. The check separates them:

| Result | What it settles |
| --- | --- |
| `200` | The signature is accepted for `/v1/apps`. Nothing more: automatic signing rights and the profiles are still unconfirmed, so a failure after this line is not a credential problem. |
| `401` | Apple refused the request. That does not identify which secret is at fault, if any, and does not establish the cause: the issuer may belong to another team, the key may be revoked or inactive, `APPSTORE_KEY_ID` may not belong to this `.p8`, or the run may differ from another in clock or conditions. |
| `403` | The request was refused, which says nothing about the signature. Usually a role or app scope matter. |

If the `.p8` is lost there is nothing to re-download: Apple serves the private key once, at creation. Create a new API key and replace `APPSTORE_PRIVATE_KEY`, `APPSTORE_KEY_ID` and `APPSTORE_ISSUER_ID` together.

The job also reports two lengths for the key: the size its ASN.1 structure declares, and the size of a canonical PKCS#8 re-export. Both are shapes, not provenance. A minimal `prime256v1` PKCS#8 structure declares 138 bytes, while a key downloaded from App Store Connect declares 150, because that file also carries the public key. So a length other than either is worth looking at, but a length is not evidence of where a key came from and it is not evidence of a cause for a `401`.

The job prints a SHA-256 of the canonical PKCS#8 DER, and the same digest can be produced from a downloaded file with:

```
openssl pkcs8 -topk8 -nocrypt -in AuthKey_<KEY_ID>.p8 -outform DER | openssl dgst -sha256
```

Matching digests show that the secret and that file hold the same key. They show nothing further: Apple returns no digest to compare against, so a match does not establish that the key is the one Apple has on record for this key id. Note that `openssl pkey -outform DER` writes the SEC1 structure instead, which is a different byte sequence and digests to something not comparable.
