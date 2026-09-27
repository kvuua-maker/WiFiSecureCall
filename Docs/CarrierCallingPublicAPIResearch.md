# Carrier / iCloud Calling public API surface

Authoritative interface inspection: Xcode 27.0 (27A266a), iOS SDK 27.0, watchOS SDK 27.0. Only exported headers and `.swiftinterface` declarations are treated as callable API. Symbols found only in binary/TBD data are excluded.

## Public callable APIs

- iOS 26+: `TelephonyConversationManager.startCellularConversation(_:)` with `StartCellularConversationAction`. This requests an iPhone system cellular conversation; it does not provision Wi-Fi Calling or companion calling.
- iOS 27 `CTCellularPlanStatus.authorizationStatus(forPhoneNumber:)`, `requestAuthorization(forPhoneNumber:)`, and `hint(forPhoneNumber:)` accept an explicit E.164 number supplied by the person. The public authorization cases are `notAuthorized`, `authorized`, `restricted`, and `notSupported`; the hint returns `available`/`unavailable` plus `low`/`high` confidence. `unavailable` is not treated as proof of no matching line. The API does not discover the active line; the probe keeps the number only in transient view/request memory, clears the input when the view closes, and never persists or serializes it.
- watchOS: `WKApplication.openSystemURL(_:)` can request a `tel:` handoff. The probe reports availability but never calls it.
- `NWPathMonitor` and `WCSession` provide network-path and app-to-app companion reachability observations.

## Public read-only APIs

- iOS 26+: `TelephonyConversationManager.cellularServices`, with public `CellularService.id` and `CellularService.label`. Service access may depend on default-calling-app status; an empty array is not evidence that no cellular subscription exists.
- `CTTelephonyNetworkInfo.serviceCurrentRadioAccessTechnology` exposes radio technology without revealing service identifiers in this probe.
- `CTTelephonyNetworkInfo.serviceSubscriberCellularProviders` is deprecated with no replacement on iOS 16; the probe reports only any non-placeholder provider labels still returned.
- `CTCellularData.restrictedState` exposes cellular-data restriction state, not IMS or Wi-Fi Calling registration.
- `WCSession` exposes activation/reachability and companion-app installation state. It does not expose a companion as a telephony participant.
- Network and AVFAudio expose network-path and audio-route metadata, not carrier calling provisioning.

## Not publicly exposed

The inspected SDK 27 public interfaces do not expose a third-party API for:

- active Wi-Fi Calling state for the line;
- Wi-Fi Calling on iCloud-connected devices;
- VoWiFi-for-iCloud-device entitlement state;
- Thumper/iCloud Calling provisioning state;
- IMS registration state or credentials;
- current active cellular-line selection;
- companion Apple devices as cellular telephony participants;
- provisioning the current subscription for companion Wi-Fi Calling.

NetworkExtension documentation mentions IMS/Wi-Fi Calling traffic only to describe VPN exclusion behavior; it is not a state or provisioning API. CallKit coordinates call UI/lifecycle and does not expose these carrier states.

## Observation limits

The in-memory BEFORE/AFTER snapshots compare only public network, cellular-service, radio, provider, TelephonyConversationManager, WCSession, and existing safe Watch handoff observations. A change or lack of change is not evidence of IMS, Thumper, VoWiFi, or iCloud-device Calling state; those remain `UNKNOWN_PUBLIC_API_NOT_EXPOSED`.

## Signing evidence

Offline inspection of the byte-verified signed Build44 iPhone and Watch bundles found no cellular/telephony entitlement and no `com.apple.CommCenter.fine-grained` entitlement. That historical result is labeled `BUILD44_OFFLINE_VERIFIED_COMM_CENTER_FINE_GRAINED_ABSENT`. There is no suitable public App-Store-safe API for measuring that entitlement in the currently running build, so runtime UI reports `UNKNOWN_PUBLIC_API_NOT_EXPOSED`. The probe adds no entitlement or capability.

## Result

`NO_PUBLIC_PATH_FOUND`: no public SDK 27 API or legitimately requestable entitlement found that lets an ordinary third-party app provision Wi-Fi Calling on iCloud-connected/companion devices for an existing mobile subscription. Missing public observability is reported as `UNKNOWN_PUBLIC_API_NOT_EXPOSED`, never as `NO`.

## Build48 `cellularServices` empty-list review

Evidence checked against Xcode 27.0 (27A266a), iOS SDK 27.0 exported interfaces and Apple's public documentation:

- `$SDKROOT/System/Library/Frameworks/LiveCommunicationKit.framework/Modules/LiveCommunicationKit.swiftmodule/arm64e-apple-ios.swiftinterface`
- `$SDKROOT/System/Library/Frameworks/UIKit.framework/Headers/UIApplication.h`

```swift
final class TelephonyConversationManager: Sendable {
    static let sharedInstance: TelephonyConversationManager
    final var cellularServices: [CellularService] { get }
    final func startCellularConversation(_ action: StartCellularConversationAction) async throws
}

struct CellularService: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let label: String
}

init(_ handle: Handle, cellularService: CellularService? = nil)
```

The exported `TelephonyConversationManager` surface has no public initializer, refresh/request-access method, delegate, notification, publisher, or asynchronous service-catalog accessor. The app's use of `sharedInstance` and a synchronous read of the read-only `cellularServices` getter therefore matches the public lifecycle contract. The diagnostic performs one bounded getter read per explicit refresh; it does not poll or wait for an undocumented update.

Apple documents that access to the cellular-service accounts requires the app to be the default calling app. Apple separately documents the dialing-app entitlement as required for `TelephonyConversationManager` and `StartCellularConversationAction`, and distinguishes the default calling role from the default dialer role. The public SDK does not expose a calling/dialer category through `UIApplication.isDefault(_:)`: the SDK 27 `UIApplication.Category` public surface lists only `webBrowser`. Consequently the current calling/dialer role cannot be measured by this app and remains `UNKNOWN_PUBLIC_API_NOT_EXPOSED`; an empty getter result is not converted to `NOT_DEFAULT`, `PERMISSION_DENIED`, or `NO_SIM`.

Apple also documents EU account/device conditions for testing default-dialer behavior. That is a prerequisite to consider, not proof of the cause of this specific physical empty result.

Answers to the focused review questions:

- Required role/rights: default calling role for service-account access; dialing-app entitlement for the manager/action. The public contract distinguishes calling and dialer.
- Public role check: none for calling or dialer in SDK 27; `UIApplication.isDefault(_:)` cannot legitimately be called with a fabricated category.
- Population/update contract: synchronous read-only array; no public asynchronous initial-population or update channel is declared.
- Current manager lifecycle: correct use of the public shared singleton and current returned `CellularService` objects.
- Additional public getter setup missing in source: none documented. The signed Build48 app already contains calling-app, dialing-app, Apple Sign In, and production APNs entitlements.

Root cause of the physical empty list: **UNKNOWN**. Confirmed source defect repaired in the diagnostic: catalog acquisition had been incorrectly gated on an app account even though the system catalog is independent of app account identity. Catalog acquisition is now independent, while the selected UUID remains account-scoped and is reapplied on account changes. Empty, available, unsupported, and error results are reported separately with read time, method, actual count, and stored-ID match state. This is a functional isolation repair plus targeted evidence collection; it does not claim that the physical SIM list is restored.

Build48 signed-byte recheck: IPA SHA-256 `06a36796136f76d89a52cf50ac45b173332626e217efc3c83c1ff56bd164642e`; effective iPhone entitlements contain `com.apple.developer.calling-app = true`, `com.apple.developer.dialing-app = true`, `com.apple.developer.applesignin = [Default]`, and production APNs. `UIBackgroundModes` remains `audio`, `remote-notification`, and `voip`.

Public references:

- <https://developer.apple.com/documentation/livecommunicationkit/telephonyconversationmanager/cellularservices>
- <https://developer.apple.com/documentation/livecommunicationkit/telephonyconversationmanager>
- <https://developer.apple.com/documentation/livecommunicationkit/preparing-your-app-to-be-the-default-dialer-app>
- <https://developer.apple.com/documentation/uikit/uiapplication/isdefault(_:)>
- <https://developer.apple.com/documentation/uikit/uiapplication/category>
