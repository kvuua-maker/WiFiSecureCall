import Foundation
import XCTest

@MainActor
private final class CarrierPlanClientSpy: CarrierCellularPlanStatusChecking {
    var authorizationResult: CarrierCellularPlanAuthorizationResult
    var requestResult: CarrierCellularPlanAuthorizationResult
    var hintResult: CarrierCellularPlanAvailabilityResult
    private(set) var authorizationCalls = 0
    private(set) var requestCalls = 0
    private(set) var hintCalls = 0

    init(
        authorization: CarrierCellularPlanAuthorizationResult = .authorized,
        request: CarrierCellularPlanAuthorizationResult = .authorized,
        hint: CarrierCellularPlanAvailabilityResult = .availableHighConfidence
    ) {
        authorizationResult = authorization
        requestResult = request
        hintResult = hint
    }

    func authorizationStatus(for phoneNumber: String) async -> CarrierCellularPlanAuthorizationResult {
        authorizationCalls += 1
        return authorizationResult
    }

    func requestAuthorization(for phoneNumber: String) async -> CarrierCellularPlanAuthorizationResult {
        requestCalls += 1
        return requestResult
    }

    func statusHint(for phoneNumber: String) async -> CarrierCellularPlanAvailabilityResult {
        hintCalls += 1
        return hintResult
    }
}

final class CarrierCallingDiagnosticTests: XCTestCase {
    func testUnknownPublicStateRemainsUnknownAcrossSerialization() throws {
        let value = PublicCarrierCallingState.unknownPublicAPINotExposed
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(PublicCarrierCallingState.self, from: data), value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""UNKNOWN_PUBLIC_API_NOT_EXPOSED""#)
    }

    func testDiagnosticSerializationContainsNoNumberSubscriberSecretOrToken() throws {
        var record = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        record.cellularServices = [
            PublicCellularServiceSnapshot(id: UUID(uuidString: "2F5E9E61-B31D-46C6-AC81-5D0A22530609")!, label: "Primary"),
        ]
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        for forbidden in [
            "+380501234567", "imsi-secret", "ims-password", "apns-secret",
            "access-secret", "refresh-secret", "bearer-secret", "phoneNumber", "e164",
            "subscriberIdentifier", "identityToken", "authorizationCode",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    @MainActor
    func testTransientE164NeverAppearsInSerializedDiagnostic() async throws {
        let testNumber = "+380501234567"
        let client = CarrierPlanClientSpy()
        let result = await CarrierCellularPlanCheckWorkflow.check(phoneNumber: testNumber, client: client)

        XCTAssertEqual(client.authorizationCalls, 1)
        XCTAssertEqual(client.requestCalls, 0)
        XCTAssertEqual(client.hintCalls, 1)
        var record = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        record.cellularPlanAuthorization = result.authorization
        record.cellularPlanStatus = result.availability
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(encoded.contains(testNumber))
        XCTAssertEqual(result.authorization, "AUTHORIZED")
        XCTAssertEqual(result.availability, "AVAILABLE / CONFIDENCE_HIGH")
    }

    @MainActor
    func testInvalidE164IsRejectedBeforeAnyPlanStatusCall() async {
        for invalid in ["0501234567", "+012345678", "+123", "+123 456 789", "+１２３４５６７８"] {
            let client = CarrierPlanClientSpy()
            let result = await CarrierCellularPlanCheckWorkflow.check(phoneNumber: invalid, client: client)
            XCTAssertEqual(client.authorizationCalls, 0, invalid)
            XCTAssertEqual(client.requestCalls, 0, invalid)
            XCTAssertEqual(client.hintCalls, 0, invalid)
            XCTAssertEqual(result.authorization, "INVALID_E164")
            XCTAssertEqual(result.availability, "NOT_CHECKED")
        }
    }

    @MainActor
    func testAuthorizationFlowRequestsOnceThenUsesExactAvailabilityHint() async {
        let client = CarrierPlanClientSpy(
            authorization: .notAuthorized,
            request: .authorized,
            hint: .unavailableLowConfidence
        )
        var requiredCallbacks = 0
        let result = await CarrierCellularPlanCheckWorkflow.check(
            phoneNumber: "+380501234567",
            client: client,
            authorizationRequired: { requiredCallbacks += 1 }
        )

        XCTAssertEqual(client.authorizationCalls, 1)
        XCTAssertEqual(client.requestCalls, 1)
        XCTAssertEqual(client.hintCalls, 1)
        XCTAssertEqual(requiredCallbacks, 1)
        XCTAssertEqual(result.authorization, "AUTHORIZED")
        XCTAssertEqual(result.availability, "UNAVAILABLE / CONFIDENCE_LOW")
    }

    @MainActor
    func testDeniedAndUnknownAuthorizationNeverBecomeNo() async {
        let denied = CarrierPlanClientSpy(authorization: .notAuthorized, request: .notAuthorized)
        let deniedResult = await CarrierCellularPlanCheckWorkflow.check(phoneNumber: "+380501234567", client: denied)
        XCTAssertEqual(deniedResult.authorization, "AUTHORIZATION_DENIED")
        XCTAssertNotEqual(deniedResult.authorization, PublicCarrierCallingState.no.rawValue)

        let unknown = CarrierPlanClientSpy(authorization: .unknown)
        let unknownResult = await CarrierCellularPlanCheckWorkflow.check(phoneNumber: "+380501234567", client: unknown)
        XCTAssertEqual(unknownResult.authorization, PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue)
        XCTAssertEqual(unknownResult.availability, PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue)
        XCTAssertNotEqual(unknownResult.authorization, PublicCarrierCallingState.no.rawValue)
    }

    func testUnknownNetworkFlagsRemainUnknownRatherThanNo() {
        XCTAssertNil(CarrierCallingNetworkSnapshot.unknown.isExpensive)
        XCTAssertNil(CarrierCallingNetworkSnapshot.unknown.isConstrained)
    }

    func testBeforeAfterSnapshotsUseSameSafeFieldsAndOnlyReportActualChanges() throws {
        var beforeRecord = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        beforeRecord.network = .init(status: "satisfied", interfaces: ["wifi"], isExpensive: false, isConstrained: false)
        beforeRecord.cellularServices = [.init(id: UUID(uuidString: "2F5E9E61-B31D-46C6-AC81-5D0A22530609")!, label: "Primary")]
        let before = CarrierCallingObservationSnapshot(record: beforeRecord)

        var afterRecord = beforeRecord
        afterRecord.network = .init(status: "satisfied", interfaces: ["cellular"], isExpensive: true, isConstrained: false)
        afterRecord.radioAccessTechnologies = ["LTE"]
        let after = CarrierCallingObservationSnapshot(record: afterRecord)

        let beforeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        let afterJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as? [String: Any])
        XCTAssertEqual(Set(beforeJSON.keys), Set(afterJSON.keys))
        XCTAssertEqual(after.changedFields(comparedTo: before), ["network.interfaces", "network.expensive", "radioTechnology"])
    }

    @MainActor
    func testObservationStoreKeepsSafeBeforeAcrossViewLifetimesAndResetsOldAfter() {
        let store = CarrierCallingObservationStore()
        let before = CarrierCallingObservationSnapshot(record: .baseline(platform: .iOS))
        var afterRecord = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        afterRecord.watchConnectivityState = "activated"
        let after = CarrierCallingObservationSnapshot(record: afterRecord)

        store.captureBefore(before, for: .iOS)
        store.captureAfter(after, for: .iOS)
        XCTAssertEqual(store.beforeSnapshot(for: .iOS), before)
        XCTAssertEqual(store.afterSnapshot(for: .iOS), after)
        XCTAssertEqual(store.changedFields(for: .iOS), ["watch.activation"])

        store.captureBefore(after, for: .iOS)
        XCTAssertNil(store.afterSnapshot(for: .iOS))
    }

    func testUnknownIMSVoWiFiAndThumperRemainUnknownBeforeAndAfter() {
        let before = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        var after = before
        after.network = .init(status: "satisfied", interfaces: ["wifi"], isExpensive: false, isConstrained: false)
        for record in [before, after] {
            XCTAssertEqual(record.publicIMSState, .unknownPublicAPINotExposed)
            XCTAssertEqual(record.publicThumperState, .unknownPublicAPINotExposed)
            XCTAssertEqual(record.publicVoWiFiICloudEntitlementState, .unknownPublicAPINotExposed)
            XCTAssertEqual(record.publicICloudDeviceCallingState, .unknownPublicAPINotExposed)
        }
    }

    func testProbeSourceDoesNotPersistSendOrLogE164() throws {
        let source = try probeSource()
        for forbidden in [
            "UserDefaults", "SecureTokenStore", "Keychain", "FileManager", "data.write(",
            "AccountAPIClient", "APIClient(", "URLSession", "Logger(", "os_log", "print(",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testProbeSourceUsesNoDynamicOrPrivateAPI() throws {
        let source = try probeSource()
        for forbidden in [
            "NSClassFromString", "dlopen(", "dlsym(", "performSelector",
            "value(forKey:", "_CTServer", "CTSubscriber", "carrierToken",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertFalse(CarrierCallingPublicSurface.usesPrivateAPI)
        XCTAssertFalse(CarrierCallingPublicSurface.accessesSIMOrIMSSecrets)
    }

    func testProbeCannotDialOrStartCellularConversation() throws {
        let root = repositoryRoot
        let source = try [
            "iOS/CarrierCallingDiagnosticView.swift",
            "Watch/WatchCarrierCallingDiagnosticView.swift",
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        for forbidden in [
            "openSystemURL(", "startCellularConversation(", "SystemDialTelephonyURL.make(",
            "WatchSystemDialerNumber.url(", "tel://", "telephony:",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testWatchProbeReadsButNeverMutatesSystemDialStore() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Watch/WatchCarrierCallingDiagnosticView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("dialStore.attempts.first"))
        for forbidden in ["dialStore.upsert(", "dialStore.update(", "dialStore.record(", "dialStore.updateAndRecord("] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testLegacyMobileDialContractsRemainUnchanged() {
        XCTAssertEqual(WatchSystemDialerNumber.url(for: "+380501234567")?.absoluteString, "tel:+380501234567")
        XCTAssertEqual(SystemDialTelephonyURL.make(handle: "+380501234567")?.absoluteString, "telephony:+380501234567")
        XCTAssertTrue(SystemDialPreflightPolicy.shouldRequestTelHandoff(numberIsValid: true, preflightSucceeded: false))
        XCTAssertFalse(SystemDialPreflightPolicy.shouldRequestTelHandoff(numberIsValid: false, preflightSucceeded: true))
    }

    func testCrossUserImplementationRemainsIndependentFromProbe() throws {
        let root = repositoryRoot
        let accountAPI = try String(contentsOf: root.appendingPathComponent("Shared/AccountAPIClient.swift"), encoding: .utf8)
        let signaling = try String(contentsOf: root.appendingPathComponent("Shared/CallSignaling.swift"), encoding: .utf8)
        XCTAssertTrue(accountAPI.contains(#"authorizedV3("recipients/resolve""#))
        XCTAssertTrue(accountAPI.contains(#"authorizedV3("calls""#))
        XCTAssertTrue(signaling.contains("CrossUserCallSignaling"))
        XCTAssertFalse(accountAPI.contains("CarrierCallingDiagnostic"))
        XCTAssertFalse(signaling.contains("CarrierCallingDiagnostic"))
    }

    func testSignedEntitlementEvidenceIsSeparatedAndDoesNotMutateProjectEntitlements() throws {
        let root = repositoryRoot
        for path in ["iOS/WiFiSecureCall.entitlements", "Watch/WiFiSecureCallWatch.entitlements"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("com.apple.CommCenter.fine-grained"))
        }
        let record = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        XCTAssertEqual(
            record.build44OfflineCommCenterFineGrained,
            "BUILD44_OFFLINE_VERIFIED_COMM_CENTER_FINE_GRAINED_ABSENT"
        )
        XCTAssertEqual(record.currentBuildCommCenterFineGrained, .unknownPublicAPINotExposed)
    }

    func testSDK27AdapterUsesExactPublicPlanStatusAPIAndClearsInput() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("iOS/CarrierCallingDiagnosticView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CTCellularPlanStatus.authorizationStatus(forPhoneNumber:"))
        XCTAssertTrue(source.contains("CTCellularPlanStatus.requestAuthorization(forPhoneNumber:"))
        XCTAssertTrue(source.contains("CTCellularPlanStatus.hint(forPhoneNumber:"))
        XCTAssertTrue(source.contains("e164Input.removeAll(keepingCapacity: false)"))
        XCTAssertFalse(source.contains("CTCellularPlanStatus.getToken"))
        XCTAssertFalse(source.contains("CTCellularPlanStatus.checkValidityOfToken"))
    }

    private func probeSource() throws -> String {
        let root = repositoryRoot
        return try [
            "Shared/CarrierCallingDiagnosticModels.swift",
            "iOS/CarrierCallingDiagnosticView.swift",
            "Watch/WatchCarrierCallingDiagnosticView.swift",
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
