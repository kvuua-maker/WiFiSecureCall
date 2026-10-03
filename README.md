# WiFi Secure Call

## Phone-account foundation

Phone number is the account identity. A server-generated SMS OTP verifies control of the number; SMSClub only delivers the message, and Apple ID is not required. One verified phone maps to one AccountID, while one iPhone installation may securely store multiple account sessions and switch between them. Raw access and refresh tokens are stored in Keychain, not UserDefaults.

Apple Watch links to an authenticated iPhone account through the server over the Internet, so Bluetooth and WatchConnectivity are not required. Current calls still use the legacy A/B `/v1` routing during this foundation phase. Media remains protected by TLS/WSS and is not end-to-end encrypted; account-to-account routing and E2EE are later phases.

Independent iPhone and Apple Watch MVP for live Internet audio calls over HTTPS/WSS.

## Local configuration

Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` and replace both values with distinct random 256-bit bearer tokens. The file is intentionally ignored by Git. Matching values are supplied to the server as protected environment variables.

The MVP protects signaling and media in transit with system TLS/WSS. It does not claim end-to-end encryption or server-blind media.

## GitHub Actions and TestFlight

`.github/workflows/ios-build.yml` runs on the `xcode-27` image, the same Swift 6.4 toolchain CircleCI uses, because the carrier probe compiles behind `#if compiler(>=6.4)`.

| Job | Runs on | Purpose |
| --- | --- | --- |
| `validate` | pull requests, pushes | Unsigned Debug build that compiles the iPhone target and the embedded Apple Watch target |
| `release` | pushes to `main`, `v*` tags, manual dispatch | Signed Release archive, then the TestFlight submission |
| `github-release` | tags, manual dispatch | Attaches the archive to a GitHub Release using `GH_PAT` |

Repository secrets: `IOS_BEARER_TOKEN` and `WATCH_BEARER_TOKEN` write `Config/Secrets.xcconfig`, which the Release build phases require. `APPLE_DISTRIBUTION_CERT_P12` (base64) with `APPLE_DISTRIBUTION_CERT_PASSWORD`, plus `APPLE_PROFILE_IOS` and `APPLE_PROFILE_WATCH` (base64 of `WiFiSecureCallAppStoreD24.mobileprovision` and `WiFiSecureCallWatchAppStore.provisionprofile`), provide the manual signing the Release target configurations pin. `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and `APP_STORE_CONNECT_PRIVATE_KEY` authenticate the upload itself. `GH_PAT` is a GitHub token and cannot authenticate against App Store Connect, so it is only used to publish the release. Without the Apple secrets the workflow still compiles both platforms and reports what is missing instead of failing.
