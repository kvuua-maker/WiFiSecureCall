import Intents
import XCTest

final class WatchRemoteExecutionProbeTests: XCTestCase {
    func testHandlerReturnsBackgroundSuccessWithExactMarkerAndOpaqueNonce() throws {
        let nonce = try XCTUnwrap(UUID(uuidString: "4B7BB92C-E946-4E20-A512-CE14D917C124"))
        let handler = WatchRemoteExecutionProbeIntentHandler(nonceFactory: { nonce })
        var responses: [WatchRemoteExecutionProbeIntentResponse] = []

        handler.handle(intent: WatchRemoteExecutionProbeIntent()) { responses.append($0) }

        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(response.code, .success)
        XCTAssertNotEqual(response.code, .continueInApp)
        XCTAssertNil(response.userActivity)
        XCTAssertEqual(response.nonce, nonce.uuidString.lowercased())
        XCTAssertEqual(
            response.executionResult,
            "\(WatchRemoteExecutionProbeIntentHandler.executionMarker) · \(nonce.uuidString.lowercased())"
        )
    }

    func testHandlerCreatesFreshOpaqueNonceForEachExecution() throws {
        let handler = WatchRemoteExecutionProbeIntentHandler()

        let first = try response(from: handler)
        let second = try response(from: handler)

        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotNil(first.nonce.flatMap(UUID.init(uuidString:)))
        XCTAssertNotNil(second.nonce.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(first.executionResult?.hasPrefix("EXECUTED_ON_IPHONE · ") == true)
        XCTAssertTrue(second.executionResult?.hasPrefix("EXECUTED_ON_IPHONE · ") == true)
    }

    func testExtensionRoutesOnlyTheProbeIntentToProbeHandler() {
        let extensionHandler = IntentHandler()
        XCTAssertTrue(extensionHandler.handler(for: WatchRemoteExecutionProbeIntent()) is WatchRemoteExecutionProbeIntentHandler)
        XCTAssertTrue((extensionHandler.handler(for: INIntent()) as? IntentHandler) === extensionHandler)
    }

    func testIntentDefinitionHasNoInputsAndSupportsBackgroundExecution() throws {
        let definition = try propertyList(at: "ShortcutsProbe/WatchRemoteExecutionProbe.intentdefinition")
        let intents = try XCTUnwrap(definition["INIntents"] as? [[String: Any]])
        let intent = try XCTUnwrap(intents.first)
        XCTAssertEqual(intent["INIntentTitle"] as? String, "Run remote execution probe")
        XCTAssertEqual(
            intent["INIntentDescription"] as? String,
            "Runs an isolated execution probe in the paired device app extension and returns fresh execution evidence."
        )
        XCTAssertEqual((intent["INIntentParameters"] as? [Any])?.count, 0)

        let combinations = try XCTUnwrap(intent["INIntentParameterCombinations"] as? [String: [String: Any]])
        let zeroInput = try XCTUnwrap(combinations[""])
        XCTAssertEqual(zeroInput["INIntentParameterCombinationIsPrimary"] as? Bool, true)
        XCTAssertEqual(zeroInput["INIntentParameterCombinationSupportsBackgroundExecution"] as? Bool, true)
        XCTAssertEqual(zeroInput["INIntentParameterCombinationTitle"] as? String, "Run remote execution probe")
    }

    func testProbeVisibleNamesAvoidRestrictedDeviceWord() throws {
        let extensionInfo = try propertyList(at: "ShortcutsProbe/Info.plist")
        XCTAssertEqual(extensionInfo["CFBundleDisplayName"] as? String, "Remote Execution Probe")

        let hostInfo = try propertyList(at: "iOS/Info.plist")
        XCTAssertEqual(
            hostInfo["NSSiriUsageDescription"] as? String,
            "Siri and Shortcuts can run the owner-enabled remote execution probe."
        )

        let donationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("iOS/WatchRemoteExecutionProbeDonation.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(donationSource.contains("intent.suggestedInvocationPhrase = \"Run remote execution probe\""))

        let definition = try propertyList(at: "ShortcutsProbe/WatchRemoteExecutionProbe.intentdefinition")
        let intent = try XCTUnwrap((definition["INIntents"] as? [[String: Any]])?.first)
        let combinations = try XCTUnwrap(intent["INIntentParameterCombinations"] as? [String: [String: Any]])
        let visibleStrings = [
            intent["INIntentTitle"] as? String,
            intent["INIntentDescription"] as? String,
            combinations[""]?["INIntentParameterCombinationTitle"] as? String,
            extensionInfo["CFBundleDisplayName"] as? String,
            hostInfo["NSSiriUsageDescription"] as? String,
            "Run remote execution probe"
        ].compactMap { $0 }
        XCTAssertTrue(visibleStrings.allSatisfy { !$0.localizedCaseInsensitiveContains("iPhone") })
    }

    func testExtensionSupportsProbeWhileLockedWithoutForegroundContinuation() throws {
        let info = try propertyList(at: "ShortcutsProbe/Info.plist")
        let extensionDictionary = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(extensionDictionary["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(attributes["IntentsSupported"] as? [String], ["WatchRemoteExecutionProbeIntent"])
        XCTAssertEqual(attributes["IntentsRestrictedWhileLocked"] as? [String], [])
    }

    func testProbeSourcesRemainIsolatedFromCallingNetworkingAndSecrets() throws {
        let files = [
            "ShortcutsProbe/IntentHandler.swift",
            "iOS/WatchRemoteExecutionProbeDonation.swift",
            "ShortcutsProbe/WatchRemoteExecutionProbe.intentdefinition"
        ]
        let forbidden = [
            "CallSession", "NotificationRuntime", "AccountAPIClient", "TelephonyConversationManager",
            "startCellularConversation", "phoneNumber", "accessToken", "refreshToken", "tel:"
        ]

        for file in files {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(file), encoding: .utf8)
            for value in forbidden {
                XCTAssertFalse(source.contains(value), "\(file) unexpectedly contains \(value)")
            }
        }
    }

    private func response(
        from handler: WatchRemoteExecutionProbeIntentHandler
    ) throws -> WatchRemoteExecutionProbeIntentResponse {
        var result: WatchRemoteExecutionProbeIntentResponse?
        handler.handle(intent: WatchRemoteExecutionProbeIntent()) { result = $0 }
        return try XCTUnwrap(result)
    }

    private func propertyList(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
