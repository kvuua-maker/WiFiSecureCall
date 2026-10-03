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
| `testflight` | manual dispatch only | Optional signed build and TestFlight submission, needs the Apple credentials listed below |

The default path needs no Apple certificate, no provisioning profile and no App Store Connect key, and no secret at all: the release upload uses the built-in `GITHUB_TOKEN`. Without `IOS_BEARER_TOKEN` and `WATCH_BEARER_TOKEN` the artifact is built in the Debug configuration, because the Release build phases validate those tokens; with them it is built in the Release configuration.

**The published `.ipa` is unsigned.** It contains the iPhone app and its embedded Apple Watch app, and it proves the build was compiled for both platforms, but Apple only accepts signed bundles on a device. Re-sign it with your own certificate, or configure the credentials below and use the `testflight` job.

Repository secrets, all optional for the default path:

| Secret | Used for |
| --- | --- |
| `IOS_BEARER_TOKEN`, `WATCH_BEARER_TOKEN` | write `Config/Secrets.xcconfig`, which the Release build phases require, and enable the Release configuration |
| `APPLE_DISTRIBUTION_CERT_P12` (base64) + `APPLE_DISTRIBUTION_CERT_PASSWORD` | Apple Distribution certificate for the `testflight` job |
| `APPLE_PROFILE_IOS`, `APPLE_PROFILE_WATCH` (base64 of `WiFiSecureCallAppStoreD24.mobileprovision` and `WiFiSecureCallWatchAppStore.provisionprofile`) | the manual signing the Release target configurations pin |
| `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY` (base64 of the `.p8`) | authenticating the TestFlight submission |
| `GH_PAT` | optional, only to publish the release with a personal token instead of `GITHUB_TOKEN` |
