import Intents
import XCTest

final class WatchRemoteExecutionProbeTests: XCTestCase {
    func testHandlerReturnsBackgroundSuccessWithExactMarkerAndOpaqueNonce() throws {
        let nonce = try XCTUnwrap(UUID(uuidString: "4B7BB92C-E946-4E20-A512-CE14D917C124"))
        let receiptScheduler = FakeRemoteExecutionReceiptNotificationScheduler(result: .success(()))
        let deadlineScheduler = FakeRemoteExecutionReceiptDeadlineScheduler()
        let handler = WatchRemoteExecutionProbeIntentHandler(
            nonceFactory: { nonce },
            receiptScheduler: receiptScheduler,
            deadlineScheduler: deadlineScheduler
        )
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
        XCTAssertEqual(
            response.receiptStatus,
            WatchRemoteExecutionProbeIntentHandler.receiptScheduleAccepted
        )
        XCTAssertEqual(receiptScheduler.attempts.count, 1)
        XCTAssertEqual(receiptScheduler.attempts[0].title, "Remote execution confirmed")
        XCTAssertEqual(receiptScheduler.attempts[0].body, response.executionResult)
        XCTAssertEqual(deadlineScheduler.entries.count, 1)
        XCTAssertTrue(deadlineScheduler.entries[0].token.isCancelled)
    }

    func testHandlerCreatesFreshOpaqueNonceForEachExecution() throws {
        let handler = makeHandler()

        let first = try response(from: handler)
        let second = try response(from: handler)

        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotNil(first.nonce.flatMap(UUID.init(uuidString:)))
        XCTAssertNotNil(second.nonce.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(first.executionResult?.hasPrefix("EXECUTED_ON_IPHONE · ") == true)
        XCTAssertTrue(second.executionResult?.hasPrefix("EXECUTED_ON_IPHONE · ") == true)
    }

    func testReceiptSchedulingBeginsOnlyAfterHandlerEntryAndMarkerCreation() throws {
        let nonce = try XCTUnwrap(UUID(uuidString: "2CDB02B4-E82C-4C19-9184-6AE07A50FEE7"))
        var events: [String] = []
        let receiptScheduler = FakeRemoteExecutionReceiptNotificationScheduler(
            result: .success(()),
            onSchedule: { attempt in
                events.append("schedule:\(attempt.body)")
            }
        )
        let handler = WatchRemoteExecutionProbeIntentHandler(
            nonceFactory: {
                events.append("handler-entered-and-nonce-created")
                return nonce
            },
            receiptScheduler: receiptScheduler,
            deadlineScheduler: FakeRemoteExecutionReceiptDeadlineScheduler()
        )

        let response = try response(from: handler)

        let marker = "EXECUTED_ON_IPHONE · \(nonce.uuidString.lowercased())"
        XCTAssertEqual(events, ["handler-entered-and-nonce-created", "schedule:\(marker)"])
        XCTAssertEqual(response.executionResult, marker)
    }

    func testExactlyOneReceiptAttemptAndExactlyOneCompletionWhenSchedulerRepliesTwice() throws {
        let receiptScheduler = FakeRemoteExecutionReceiptNotificationScheduler(result: nil)
        let handler = WatchRemoteExecutionProbeIntentHandler(
            nonceFactory: UUID.init,
            receiptScheduler: receiptScheduler,
            deadlineScheduler: FakeRemoteExecutionReceiptDeadlineScheduler()
        )
        var responses: [WatchRemoteExecutionProbeIntentResponse] = []

        handler.handle(intent: WatchRemoteExecutionProbeIntent()) { responses.append($0) }
        XCTAssertEqual(receiptScheduler.attempts.count, 1)
        XCTAssertTrue(responses.isEmpty)

        receiptScheduler.complete(.success(()))
        receiptScheduler.completeAgain(.failure(ProbeReceiptError.failed))

        XCTAssertEqual(receiptScheduler.attempts.count, 1)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(
            responses.first?.receiptStatus,
            WatchRemoteExecutionProbeIntentHandler.receiptScheduleAccepted
        )
    }

    func testReceiptSchedulingFailureIsTruthfulWithoutFabricatingDelivery() throws {
        let receiptScheduler = FakeRemoteExecutionReceiptNotificationScheduler(
            result: .failure(ProbeReceiptError.failed)
        )
        let response = try response(from: WatchRemoteExecutionProbeIntentHandler(
            nonceFactory: UUID.init,
            receiptScheduler: receiptScheduler,
            deadlineScheduler: FakeRemoteExecutionReceiptDeadlineScheduler()
        ))

        XCTAssertEqual(response.code, .success)
        XCTAssertEqual(
            response.receiptStatus,
            WatchRemoteExecutionProbeIntentHandler.receiptScheduleFailed
        )
        XCTAssertFalse(response.receiptStatus?.localizedCaseInsensitiveContains("delivered") == true)
        XCTAssertEqual(receiptScheduler.attempts.count, 1)
    }

    func testReceiptSchedulingTimeoutCompletesOnceAndIgnoresLateSchedulerReply() throws {
        let receiptScheduler = FakeRemoteExecutionReceiptNotificationScheduler(result: nil)
        let deadlineScheduler = FakeRemoteExecutionReceiptDeadlineScheduler()
        let handler = WatchRemoteExecutionProbeIntentHandler(
            nonceFactory: UUID.init,
            receiptScheduler: receiptScheduler,
            deadlineScheduler: deadlineScheduler,
            receiptSchedulingBudget: 0.25
        )
        var responses: [WatchRemoteExecutionProbeIntentResponse] = []

        handler.handle(intent: WatchRemoteExecutionProbeIntent()) { responses.append($0) }
        XCTAssertEqual(deadlineScheduler.entries.map(\.interval), [0.25])
        deadlineScheduler.fireFirst()
        receiptScheduler.complete(.success(()))

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(
            responses.first?.receiptStatus,
            WatchRemoteExecutionProbeIntentHandler.receiptScheduleTimedOut
        )
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

        let response = try XCTUnwrap(intent["INIntentResponse"] as? [String: Any])
        let codes = try XCTUnwrap(response["INIntentResponseCodes"] as? [[String: Any]])
        let success = try XCTUnwrap(codes.first { ($0["INIntentResponseCodeName"] as? String) == "success" })
        XCTAssertEqual(success["INIntentResponseCodeFormatStringID"] as? String, "remoteExecutionConfirmed")
        XCTAssertEqual(
            success["INIntentResponseCodeFormatString"] as? String,
            "Remote execution confirmed\n${executionResult}\nLocal receipt: ${receiptStatus}"
        )
        XCTAssertEqual(success["INIntentResponseCodeSuccess"] as? Bool, true)

        let responseParameters = try XCTUnwrap(response["INIntentResponseParameters"] as? [[String: Any]])
        XCTAssertEqual(
            Set(responseParameters.compactMap { $0["INIntentResponseParameterName"] as? String }),
            Set(["executionResult", "nonce", "receiptStatus"])
        )
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

        let handlerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("ShortcutsProbe/IntentHandler.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(handlerSource.contains("continueInApp"))
    }

    func testProjectKeepsProbeHandlerIOSOnlyAndExtensionEmbeddedOnlyInHost() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("WiFiSecureCall.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let hostSources = try projectObjectLine(id: "S10000000000000000000001", in: project)
        let watchSources = try projectObjectLine(id: "S10000000000000000000002", in: project)
        let extensionSources = try projectObjectLine(id: "S10000000000000000000004", in: project)
        let hostEmbedPhase = try projectObjectLine(id: "C10000000000000000000002", in: project)
        let hostTarget = try projectObjectLine(id: "T10000000000000000000001", in: project)
        let watchTarget = try projectObjectLine(id: "T10000000000000000000002", in: project)

        XCTAssertTrue(hostSources.contains("B20000000000000000000001"))
        XCTAssertFalse(hostSources.contains("B20000000000000000000004"))
        XCTAssertFalse(watchSources.contains("B20000000000000000000003"))
        XCTAssertFalse(watchSources.contains("B20000000000000000000004"))
        XCTAssertTrue(extensionSources.contains("B20000000000000000000003"))
        XCTAssertTrue(extensionSources.contains("B20000000000000000000004"))
        XCTAssertTrue(hostEmbedPhase.contains("B20000000000000000000009"))
        XCTAssertTrue(hostTarget.contains("D20000000000000000000003"))
        XCTAssertFalse(watchTarget.contains("D20000000000000000000003"))
        XCTAssertFalse(project.contains("com.apple.product-type.watchkit2-extension"))
        XCTAssertEqual(project.components(separatedBy: "B20000000000000000000009").count - 1, 2)
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

    private func makeHandler() -> WatchRemoteExecutionProbeIntentHandler {
        WatchRemoteExecutionProbeIntentHandler(
            nonceFactory: UUID.init,
            receiptScheduler: FakeRemoteExecutionReceiptNotificationScheduler(result: .success(())),
            deadlineScheduler: FakeRemoteExecutionReceiptDeadlineScheduler()
        )
    }

    private func projectObjectLine(id: String, in project: String) throws -> String {
        try XCTUnwrap(project.split(separator: "\n").first { $0.contains("\(id) = {") }.map(String.init))
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

private enum ProbeReceiptError: Error {
    case failed
}

private final class FakeRemoteExecutionReceiptNotificationScheduler:
    RemoteExecutionReceiptNotificationScheduling
{
    struct Attempt {
        let identifier: String
        let title: String
        let body: String
    }

    private let immediateResult: Result<Void, Error>?
    private let onSchedule: (Attempt) -> Void
    private var completion: ((Result<Void, Error>) -> Void)?
    private(set) var attempts: [Attempt] = []

    init(
        result: Result<Void, Error>?,
        onSchedule: @escaping (Attempt) -> Void = { _ in }
    ) {
        immediateResult = result
        self.onSchedule = onSchedule
    }

    func schedule(
        identifier: String,
        title: String,
        body: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let attempt = Attempt(identifier: identifier, title: title, body: body)
        attempts.append(attempt)
        onSchedule(attempt)
        self.completion = completion
        if let immediateResult {
            completion(immediateResult)
        }
    }

    func complete(_ result: Result<Void, Error>) {
        completion?(result)
    }

    func completeAgain(_ result: Result<Void, Error>) {
        completion?(result)
    }
}

private final class FakeRemoteExecutionReceiptDeadlineCancellation:
    RemoteExecutionReceiptDeadlineCancellation
{
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private final class FakeRemoteExecutionReceiptDeadlineScheduler:
    RemoteExecutionReceiptDeadlineScheduling
{
    struct Entry {
        let interval: TimeInterval
        let operation: () -> Void
        let token: FakeRemoteExecutionReceiptDeadlineCancellation
    }

    private(set) var entries: [Entry] = []

    func schedule(
        after interval: TimeInterval,
        operation: @escaping () -> Void
    ) -> RemoteExecutionReceiptDeadlineCancellation {
        let token = FakeRemoteExecutionReceiptDeadlineCancellation()
        entries.append(Entry(interval: interval, operation: operation, token: token))
        return token
    }

    func fireFirst() {
        entries.first?.operation()
    }
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
