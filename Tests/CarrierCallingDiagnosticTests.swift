import Foundation
import XCTest

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
            "access-secret", "refresh-secret", "bearer-secret", "phoneNumber",
            "subscriberIdentifier", "identityToken", "authorizationCode",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testProbeSourceUsesNoDynamicOrPrivateAPI() throws {
        let root = repositoryRoot
        let files = [
            "Shared/CarrierCallingDiagnosticModels.swift",
            "iOS/CarrierCallingDiagnosticView.swift",
            "Watch/WatchCarrierCallingDiagnosticView.swift",
        ]
        let source = try files.map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
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
        XCTAssertFalse(source.contains("openSystemURL("))
        XCTAssertFalse(source.contains("startCellularConversation("))
        XCTAssertFalse(source.contains("tel://"))
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

    func testSignedEntitlementFindingDoesNotMutateProjectEntitlements() throws {
        let root = repositoryRoot
        for path in ["iOS/WiFiSecureCall.entitlements", "Watch/WiFiSecureCallWatch.entitlements"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("com.apple.CommCenter.fine-grained"))
        }
        XCTAssertEqual(
            CarrierCallingDiagnosticRecord.baseline(platform: .iOS).signedCellularEntitlements,
            "ABSENT_IN_SIGNED_BUILD44"
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
