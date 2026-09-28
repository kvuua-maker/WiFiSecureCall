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
        XCTAssertEqual(
            WatchRemoteExecutionProbeDonation.suggestedInvocationPhrase,
            "Run remote execution probe"
        )

        let setupSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("iOS/WatchRemoteExecutionProbeSetupView.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("iOS/IOSRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(rootSource.contains("Button(\"Shortcut execution probe\")"))
        XCTAssertTrue(setupSource.contains("Add Remote Execution Probe to Shortcuts"))
        XCTAssertTrue(setupSource.contains("Edit Remote Execution Probe in Shortcuts"))
        XCTAssertFalse(setupSource.localizedCaseInsensitiveContains("iPhone"))
        XCTAssertFalse(donationSource.localizedCaseInsensitiveContains("iPhone"))

        let definition = try propertyList(at: "ShortcutsProbe/WatchRemoteExecutionProbe.intentdefinition")
        let intent = try XCTUnwrap((definition["INIntents"] as? [[String: Any]])?.first)
        let combinations = try XCTUnwrap(intent["INIntentParameterCombinations"] as? [String: [String: Any]])
        let visibleStrings = [
            intent["INIntentTitle"] as? String,
            intent["INIntentDescription"] as? String,
            combinations[""]?["INIntentParameterCombinationTitle"] as? String,
            extensionInfo["CFBundleDisplayName"] as? String,
            hostInfo["NSSiriUsageDescription"] as? String,
            WatchRemoteExecutionProbeDonation.suggestedInvocationPhrase,
            "Shortcut execution probe",
            "Add Remote Execution Probe to Shortcuts",
            "Edit Remote Execution Probe in Shortcuts"
        ].compactMap { $0 }
        XCTAssertTrue(visibleStrings.allSatisfy { !$0.localizedCaseInsensitiveContains("iPhone") })
    }

    func testShortcutFactoryCreatesExpectedCustomIntentAndStableIdentities() throws {
        let shortcut = try XCTUnwrap(WatchRemoteExecutionProbeDonation.makeShortcut())
        let intent = try XCTUnwrap(shortcut.intent as? WatchRemoteExecutionProbeIntent)

        XCTAssertEqual(intent.suggestedInvocationPhrase, "Run remote execution probe")
        XCTAssertEqual(
            WatchRemoteExecutionProbeDonation.intentIdentity(for: intent),
            WatchRemoteExecutionProbeDonation.intentTypeIdentity
        )
        XCTAssertEqual(
            WatchRemoteExecutionProbeDonation.interactionIdentifier,
            "watch-remote-execution-probe"
        )
        XCTAssertNil(WatchRemoteExecutionProbeDonation.intentIdentity(for: INIntent()))
    }

    func testShortcutQueryResolvesInstalledAndNotInstalledByIntentIdentity() throws {
        let center = FakeRemoteExecutionVoiceShortcutCenter()
        let model = WatchRemoteExecutionProbeSetupModel(center: center)

        model.refresh()
        center.complete(.success([
            RemoteExecutionVoiceShortcutRecord(
                identifier: UUID(),
                intentIdentity: "UnrelatedIntent"
            )
        ]))
        XCTAssertEqual(model.installState, .notAdded)

        model.refresh()
        center.complete(.success([probeRecord()]))
        XCTAssertEqual(model.installState, .added)
    }

    func testAddIsNotSuccessfulUntilDelegateAndRefreshedQueryConfirmIt() throws {
        let center = FakeRemoteExecutionVoiceShortcutCenter()
        let model = WatchRemoteExecutionProbeSetupModel(center: center)
        let identifier = UUID()

        model.refresh()
        center.complete(.success([]))
        model.presentSystemFlow()

        XCTAssertEqual(model.installState, .notAdded)
        XCTAssertEqual(model.operationState, .presentingAdd)
        guard case let .add(shortcut)? = model.systemSheet else {
            return XCTFail("Expected the system add sheet")
        }
        XCTAssertTrue(shortcut.intent is WatchRemoteExecutionProbeIntent)
        XCTAssertNotEqual(model.operationState, .addConfirmed)

        model.didFinishAdd(identifier: identifier, error: nil)
        XCTAssertEqual(model.installState, .checking)
        XCTAssertEqual(model.operationState, .verifyingAdd)
        XCTAssertNotEqual(model.operationState, .addConfirmed)

        center.complete(.success([probeRecord(identifier: identifier)]))
        XCTAssertEqual(model.installState, .added)
        XCTAssertEqual(model.operationState, .addConfirmed)
    }

    func testEditDeleteAndCancelRefreshAuthoritativeShortcutState() {
        let center = FakeRemoteExecutionVoiceShortcutCenter()
        let model = WatchRemoteExecutionProbeSetupModel(center: center)
        let identifier = UUID()

        model.didFinishEdit(identifier: identifier, error: nil)
        XCTAssertEqual(model.operationState, .verifyingEdit)
        center.complete(.success([probeRecord(identifier: identifier)]))
        XCTAssertEqual(model.installState, .added)
        XCTAssertEqual(model.operationState, .editConfirmed)

        model.didDelete(identifier: identifier)
        XCTAssertEqual(model.operationState, .verifyingDelete)
        center.complete(.success([]))
        XCTAssertEqual(model.installState, .notAdded)
        XCTAssertEqual(model.operationState, .deleteConfirmed)

        model.didCancelSystemFlow()
        XCTAssertEqual(model.operationState, .cancelled)
        center.complete(.success([]))
        XCTAssertEqual(model.installState, .notAdded)
        XCTAssertEqual(model.operationState, .cancelled)
    }

    func testQueryFailureDoesNotClaimShortcutIsInstalled() {
        let center = FakeRemoteExecutionVoiceShortcutCenter()
        let model = WatchRemoteExecutionProbeSetupModel(center: center)

        model.refresh()
        center.complete(.failure(ProbeQueryError.failed))

        XCTAssertEqual(model.installState, .queryFailed)
        XCTAssertEqual(model.operationState, .failed("QUERY_FAILED"))
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
            "iOS/WatchRemoteExecutionProbeSetupView.swift",
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

    private func probeRecord(identifier: UUID = UUID()) -> RemoteExecutionVoiceShortcutRecord {
        RemoteExecutionVoiceShortcutRecord(
            identifier: identifier,
            intentIdentity: WatchRemoteExecutionProbeDonation.intentTypeIdentity
        )
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

private enum ProbeQueryError: Error {
    case failed
}

private final class FakeRemoteExecutionVoiceShortcutCenter: RemoteExecutionVoiceShortcutQuerying {
    typealias Completion = (Result<[RemoteExecutionVoiceShortcutRecord], Error>) -> Void

    private var completions: [Completion] = []

    func getAllVoiceShortcuts(completion: @escaping Completion) {
        completions.append(completion)
    }

    func complete(_ result: Result<[RemoteExecutionVoiceShortcutRecord], Error>) {
        guard !completions.isEmpty else {
            return XCTFail("No pending shortcut query")
        }
        completions.removeFirst()(result)
    }
}
