# Carrier / iCloud Calling public API surface

Authoritative interface inspection: Xcode 27.0 (27A266a), iOS SDK 27.0, watchOS SDK 27.0. Only exported headers and `.swiftinterface` declarations are treated as callable API. Symbols found only in binary/TBD data are excluded.

## Public callable APIs

- iOS 26+: `TelephonyConversationManager.startCellularConversation(_:)` with `StartCellularConversationAction`. This requests an iPhone system cellular conversation; it does not provision Wi-Fi Calling or companion calling.
- SDK 27 `CTCellularPlanStatus` authorization/status/hint methods accept an explicit E.164 number supplied by the app and require user authorization. They do not discover the active line. The probe intentionally does not request, retain, or serialize a number.
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

## Signing evidence

The byte-verified signed Build44 iPhone and Watch entitlements contain no cellular/telephony entitlement and no `com.apple.CommCenter.fine-grained` entitlement. The probe does not add any entitlement or capability.

## Result

`NO_PUBLIC_PATH_FOUND`: no public SDK 27 API or legitimately requestable entitlement found that lets an ordinary third-party app provision Wi-Fi Calling on iCloud-connected/companion devices for an existing mobile subscription. Missing public observability is reported as `UNKNOWN_PUBLIC_API_NOT_EXPOSED`, never as `NO`.
