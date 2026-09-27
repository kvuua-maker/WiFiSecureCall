import AVFoundation
import Intents
import XCTest

final class WatchSystemDialerNumberTests: XCTestCase {
    func testValidSystemDialerNumbers() {
        XCTAssertTrue(WatchSystemDialerNumber.isValid("+380501234567"))
        XCTAssertTrue(WatchSystemDialerNumber.isValid("380501234567"))
        XCTAssertTrue(WatchSystemDialerNumber.isValid("0501234567"))
    }

    func testInvalidSystemDialerNumbers() {
        for number in ["+", "12", "+380 50", "abc", "++380501234567", "1234567890123456", "380+501234567"] {
            XCTAssertFalse(WatchSystemDialerNumber.isValid(number), number)
        }
    }

    func testSystemDialerInputRulesAndURL() {
        XCTAssertEqual(WatchSystemDialerNumber.appending("+", to: ""), "+")
        XCTAssertEqual(WatchSystemDialerNumber.appending("+", to: "+"), "+")
        XCTAssertEqual(WatchSystemDialerNumber.appending("+", to: "380"), "380")
        XCTAssertEqual(WatchSystemDialerNumber.appending("0", to: "+38"), "+380")
        XCTAssertEqual(WatchSystemDialerNumber.appending("9", to: "+380"), "+3809")
        XCTAssertEqual(WatchSystemDialerNumber.appending("O", to: "+38"), "+38")
        XCTAssertEqual(WatchSystemDialerNumber.appending("G", to: "+38"), "+38")
        XCTAssertEqual(WatchSystemDialerNumber.appending("-", to: "380"), "380")
        XCTAssertEqual(WatchSystemDialerNumber.deletingLast(from: "+3809"), "+380")
        XCTAssertEqual(WatchSystemDialerNumber.deletingLast(from: ""), "")
        XCTAssertEqual(WatchSystemDialerNumber.url(for: "+380501234567")?.absoluteString, "tel:+380501234567")
        XCTAssertNil(WatchSystemDialerNumber.url(for: "+380 50"))
    }
}

@MainActor
final class SystemDialDiagnosticTests: XCTestCase {
    func testDiagnosticStoreKeepsTwentyAttempts() {
        let store = makeStore()
        for index in 0..<25 {
            store.upsert(.make(attemptID: UUID(), startedAt: Date(timeIntervalSince1970: Double(index)), numberDigitCount: 10))
        }
        XCTAssertEqual(store.attempts.count, 20)
        XCTAssertEqual(store.attempts.first?.startedAt, Date(timeIntervalSince1970: 24))
    }

    func testDiagnosticStoreKeepsFiftyEventsPerAttempt() {
        let store = makeStore()
        let id = UUID()
        store.upsert(.make(attemptID: id, numberDigitCount: 10))
        for index in 0..<55 { store.record(id: id, source: "watch", event: "event_\(index)", status: "ok") }
        XCTAssertEqual(store.attempt(id: id)?.events.count, 50)
        XCTAssertEqual(store.attempt(id: id)?.events.first?.event, "event_5")
    }

    func testDiagnosticPersistenceContainsNoRawPhoneNumber() async throws {
        let url = temporaryStoreURL()
        let store = SystemDialDiagnosticStore(fileURL: url)
        store.upsert(.make(numberDigitCount: 12))
        await store.flush()
        let persisted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(persisted.contains("+380501234567"))
        XCTAssertFalse(persisted.contains("phoneNumber"))
        XCTAssertTrue(persisted.contains("numberDigitCount"))
    }

    func testNonceMismatchIsIgnored() {
        let attemptID = UUID(), nonce = UUID()
        let reply: [String: Any] = ["attemptID": attemptID.uuidString, "nonce": UUID().uuidString]
        XCTAssertFalse(SystemDialMessageValidator.matches(reply, attemptID: attemptID, nonce: nonce))
    }

    func testStaleAttemptReplyIsIgnored() {
        let nonce = UUID()
        let reply: [String: Any] = ["attemptID": UUID().uuidString, "nonce": nonce.uuidString]
        XCTAssertFalse(SystemDialMessageValidator.matches(reply, attemptID: UUID(), nonce: nonce))
    }

    func testDuplicateCallbackCannotCompleteTwice() {
        var values: [Int] = []
        let gate = SystemDialOneShotCompletion<Int> { if case let .success(value) = $0 { values.append(value) } }
        XCTAssertTrue(gate.complete(.success(1)))
        XCTAssertFalse(gate.complete(.success(2)))
        XCTAssertEqual(values, [1])
    }

    func testReplyWinsReplyTimeoutRace() {
        var result = ""
        let gate = SystemDialOneShotCompletion<String> { if case let .success(value) = $0 { result = value } }
        XCTAssertTrue(gate.complete(.success("reply")))
        XCTAssertFalse(gate.complete(.failure(TestSystemDialError.timeout)))
        XCTAssertEqual(result, "reply")
    }

    func testErrorWinsErrorTimeoutRace() {
        var completions = 0
        let gate = SystemDialOneShotCompletion<String> { _ in completions += 1 }
        XCTAssertTrue(gate.complete(.failure(TestSystemDialError.transport)))
        XCTAssertFalse(gate.complete(.failure(TestSystemDialError.timeout)))
        XCTAssertEqual(completions, 1)
    }

    func testClassificationForWCNotActivated() {
        XCTAssertEqual(classification(activation: "notActivated"), SystemDialClassification.wcNotActivated)
    }

    func testClassificationForIPhoneNeedsUnlock() {
        XCTAssertEqual(classification(needsUnlock: true), SystemDialClassification.iPhoneNeedsUnlock)
    }

    func testClassificationForIPhoneUnreachable() {
        XCTAssertEqual(classification(reachable: false), SystemDialClassification.iPhoneAppUnreachable)
    }

    func testClassificationForIPhoneReady() {
        XCTAssertEqual(classification(replied: true), SystemDialClassification.iPhoneReady)
    }

    func testNoObserverEvidenceIsNotDefinitiveRelayFailure() {
        let value = SystemDialClassification.afterHandoff(outgoing: nil, connected: nil, ended: nil, resultReceived: true)
        XCTAssertEqual(value, SystemDialClassification.noSystemCallEvidence)
        XCTAssertFalse(value.lowercased().contains("relay_failed"))
    }

    func testOutgoingObservedClassification() {
        XCTAssertEqual(SystemDialClassification.afterHandoff(outgoing: Date(), connected: nil, ended: nil, resultReceived: true), SystemDialClassification.systemCallObserved)
    }

    func testConnectedObservedClassification() {
        XCTAssertEqual(SystemDialClassification.afterHandoff(outgoing: Date(), connected: Date(), ended: nil, resultReceived: true), SystemDialClassification.systemCallConnected)
    }

    func testEndedObservedClassification() {
        XCTAssertEqual(SystemDialClassification.afterHandoff(outgoing: Date(), connected: Date(), ended: Date(), resultReceived: true), SystemDialClassification.systemCallEnded)
    }

    func testEndedBeforeConnectClassification() {
        XCTAssertEqual(
            SystemDialClassification.afterHandoff(outgoing: Date(), connected: nil, ended: Date(), resultReceived: true),
            SystemDialClassification.systemCallEndedBeforeConnect
        )
        let summary = SystemDialUserSummary.make(classification: SystemDialClassification.systemCallEndedBeforeConnect)
        XCTAssertEqual(summary.code, "D24-10")
        XCTAssertNotEqual(summary.severity, .success)
    }

    func testWCReplyOverridesStaleUnsatisfiedNetworkSnapshot() {
        let value = SystemDialClassification.preflight(
            networkStatus: "unsatisfied",
            wcSupported: true,
            activationState: "activated",
            reachable: true,
            needsUnlock: false,
            replied: true
        )
        XCTAssertEqual(value, SystemDialClassification.iPhoneReady)
    }

    func testTelephonyURLBuilderPreservesExactValidHandle() throws {
        let handle = "+380501234567"
        let url = try XCTUnwrap(SystemDialTelephonyURL.make(handle: handle))
        XCTAssertEqual(url.scheme, "telephony")
        XCTAssertEqual(url.path, handle)
        XCTAssertNil(SystemDialTelephonyURL.make(handle: ""))
    }

    func testIOSInfoPlistDoesNotDeclareDefaultCallingActivities() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("iOS/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNil(plist["NSUserActivityTypes"])
    }

    func testDefaultCallingTelURLParsesInternationalHandle() throws {
        let url = try XCTUnwrap(URL(string: "tel:+380501234567"))
        XCTAssertEqual(WSCDefaultCallingURLParser.handle(from: url), "+380501234567")
    }

    func testDefaultCallingTelURLParsesLocalHandle() throws {
        let url = try XCTUnwrap(URL(string: "tel:0501234567"))
        XCTAssertEqual(WSCDefaultCallingURLParser.handle(from: url), "0501234567")
    }

    func testDefaultCallingTelURLSafelyDecodesPercentEncodedHandle() throws {
        let url = try XCTUnwrap(URL(string: "tel:%2B380501234567"))
        XCTAssertEqual(WSCDefaultCallingURLParser.handle(from: url), "+380501234567")
    }

    func testDefaultCallingURLRejectsEmptyAndNonTelSchemes() throws {
        XCTAssertNil(WSCDefaultCallingURLParser.handle(from: try XCTUnwrap(URL(string: "tel:"))))
        for value in ["telephony:+380501234567", "http://example.com", "https://example.com"] {
            XCTAssertNil(WSCDefaultCallingURLParser.handle(from: try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testTelURLCreatesStandaloneAttemptAndTriggersTelephonyFallback() throws {
        let store = makeStore()
        var openedURL: URL?
        let coordinator = makeIOSCoordinator(store: store) { url, completion in
            openedURL = url
            completion(true)
        }
        XCTAssertTrue(coordinator.handleDefaultCallingURL(try XCTUnwrap(URL(string: "tel:+380501234567"))))
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertEqual(store.attempts[0].numberDigitCount, 12)
        XCTAssertTrue(store.attempts[0].events.contains { $0.event == "default_call_url_received" })
        XCTAssertNotNil(store.attempts[0].iPhoneDefaultCallingRequestAt)
        XCTAssertNotNil(store.attempts[0].iPhoneTelephonyFallbackRequestedAt)
        XCTAssertEqual(openedURL?.scheme, "telephony")
        XCTAssertEqual(openedURL?.path, "+380501234567")
    }

    func testTelURLDiagnosticsPersistNoRawNumber() async throws {
        let url = temporaryStoreURL()
        let store = SystemDialDiagnosticStore(fileURL: url)
        let coordinator = makeIOSCoordinator(store: store) { _, completion in completion(true) }
        XCTAssertTrue(coordinator.handleDefaultCallingURL(try XCTUnwrap(URL(string: "tel:+380501234567"))))
        await store.flush()
        let persisted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(persisted.contains("+380501234567"))
        XCTAssertTrue(persisted.contains("scheme=tel digitCount=12"))
    }

    func testActivityThenTelURLRequestsOnlyOneFallbackAndUsesOneAttempt() throws {
        let store = makeStore()
        var openCount = 0
        let coordinator = makeIOSCoordinator(store: store) { _, completion in
            openCount += 1
            completion(true)
        }
        XCTAssertTrue(coordinator.handleDefaultCallingActivityEvidence(
            activityType: "INStartCallIntent",
            interactionPresent: true,
            intentType: "INStartCallIntent",
            handle: "+380501234567"
        ))
        XCTAssertTrue(coordinator.handleDefaultCallingURL(try XCTUnwrap(URL(string: "tel:+380501234567"))))
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertEqual(store.attempts[0].events.filter { $0.event == "telephony_fallback_requested" }.count, 1)
    }

    func testTelURLThenActivityRequestsOnlyOneFallbackAndUsesOneAttempt() throws {
        let store = makeStore()
        var openCount = 0
        let coordinator = makeIOSCoordinator(store: store) { _, completion in
            openCount += 1
            completion(true)
        }
        XCTAssertTrue(coordinator.handleDefaultCallingURL(try XCTUnwrap(URL(string: "tel:0501234567"))))
        XCTAssertTrue(coordinator.handleDefaultCallingActivityEvidence(
            activityType: "INStartCallIntent",
            interactionPresent: true,
            intentType: "INStartCallIntent",
            handle: "0501234567"
        ))
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertEqual(store.attempts[0].events.filter { $0.event == "telephony_fallback_requested" }.count, 1)
    }

    func testDuplicateDefaultCallDeliveryIsSuppressed() {
        let gate = SystemDialDefaultCallAdmissionGate(duplicateWindow: 3)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(gate.admit(fingerprint: 42, now: now))
        XCTAssertFalse(gate.admit(fingerprint: 42, now: now.addingTimeInterval(0.1)))
    }

    func testSeparateLaterDefaultCallIsNotPermanentlyBlocked() {
        let gate = SystemDialDefaultCallAdmissionGate(duplicateWindow: 3)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(gate.admit(fingerprint: 42, now: now))
        XCTAssertTrue(gate.admit(fingerprint: 42, now: now.addingTimeInterval(3.1)))
    }

    func testSystemDialHandoffMessageIsValidatedWithoutReply() throws {
        let attemptID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let parsed = try XCTUnwrap(SystemDialHandoffMessage.parse([
            "type": "systemDialHandoff",
            "attemptID": attemptID.uuidString,
            "handoffAt": timestamp.timeIntervalSince1970,
            "numberDigitCount": 10
        ]))
        XCTAssertEqual(parsed.attemptID, attemptID)
        XCTAssertEqual(parsed.handoffAt, timestamp)
        XCTAssertEqual(parsed.numberDigitCount, 10)
        XCTAssertNil(SystemDialHandoffMessage.parse(["type": "systemDialHandoff", "attemptID": "invalid", "handoffAt": 1.0]))
    }

    func testINStartCallIntentHandleExtraction() {
        let intent = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [intentPerson("+380501234567")],
            callCapability: .audioCall
        )
        XCTAssertEqual(WSCDefaultCallingHandleExtractor.wscStartCallHandle(from: intent), "+380501234567")
    }

    func testLegacyAudioCallIntentHandleExtraction() {
        let intent = INStartAudioCallIntent(destinationType: .normal, contacts: [intentPerson("0501234567")])
        XCTAssertEqual(WSCDefaultCallingHandleExtractor.wscStartCallHandle(from: intent), "0501234567")
    }

    func testLegacyVideoCallIntentHandleExtraction() {
        let intent = INStartVideoCallIntent(contacts: [intentPerson("380501234567")])
        XCTAssertEqual(WSCDefaultCallingHandleExtractor.wscStartCallHandle(from: intent), "380501234567")
    }

    func testActivityWithoutInteractionCreatesSanitizedStandaloneAttempt() {
        let store = makeStore()
        let coordinator = makeIOSCoordinator(store: store)
        XCTAssertFalse(coordinator.handleDefaultCallingActivity(NSUserActivity(activityType: "com.apple.calling")))
        let attempt = store.attempts.first
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertEqual(attempt?.numberDigitCount, 0)
        XCTAssertEqual(attempt?.events.last?.event, "default_call_activity_received")
        XCTAssertEqual(attempt?.events.last?.status, "handle_missing")
    }

    func testUnsupportedIntentEvidenceStillCreatesAttempt() {
        let store = makeStore()
        let coordinator = makeIOSCoordinator(store: store)
        XCTAssertFalse(coordinator.handleDefaultCallingActivityEvidence(
            activityType: "com.apple.calling",
            interactionPresent: true,
            intentType: "INUnsupportedIntent",
            handle: nil
        ))
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertTrue(store.attempts[0].events[0].detail?.contains("interactionPresent=yes") == true)
        XCTAssertTrue(store.attempts[0].events[0].detail?.contains("intentType=INUnsupportedIntent") == true)
    }

    func testValidDefaultActivityWithoutWCStartsStandaloneObservation() {
        let store = makeStore()
        var openedURL: URL?
        let coordinator = makeIOSCoordinator(store: store) { url, completion in
            openedURL = url
            completion(true)
        }
        XCTAssertTrue(coordinator.handleDefaultCallingActivityEvidence(
            activityType: "com.apple.calling",
            interactionPresent: true,
            intentType: "INStartCallIntent",
            handle: "+380501234567"
        ))
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertEqual(store.attempts[0].numberDigitCount, 12)
        XCTAssertNotNil(store.attempts[0].iPhoneDefaultCallingRequestAt)
        XCTAssertTrue(coordinator.hasActiveSystemDialObservation)
        XCTAssertEqual(openedURL?.scheme, "telephony")
    }

    func testDefaultActivityThenWatchHandoffConvergesAndResultUsesAlias() throws {
        let store = makeStore()
        let coordinator = makeIOSCoordinator(store: store) { _, completion in completion(true) }
        XCTAssertTrue(coordinator.handleDefaultCallingActivityEvidence(
            activityType: "com.apple.calling",
            interactionPresent: true,
            intentType: "INStartCallIntent",
            handle: "+380501234567"
        ))
        let iPhoneAttemptID = try XCTUnwrap(store.attempts.first?.attemptID)
        let watchAttemptID = UUID()
        coordinator.handleHandoff(handoffMessage(id: watchAttemptID, digitCount: 12))
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertEqual(store.attempts.first?.attemptID, iPhoneAttemptID)
        XCTAssertNotNil(store.attempts.first?.telHandoffRequestedAt)

        let nonce = UUID()
        let reply = coordinator.handleResult([
            "type": "systemDialResult",
            "attemptID": watchAttemptID.uuidString,
            "nonce": nonce.uuidString,
            "numberDigitCount": 12
        ])
        XCTAssertNotNil(reply["attemptJSON"] as? Data)
        XCTAssertEqual(reply["attemptID"] as? String, watchAttemptID.uuidString)
    }

    func testWatchHandoffThenDefaultActivityConvergesOnWatchAttempt() {
        let store = makeStore()
        let coordinator = makeIOSCoordinator(store: store) { _, completion in completion(true) }
        let watchAttemptID = UUID()
        coordinator.handleHandoff(handoffMessage(id: watchAttemptID, digitCount: 12))
        XCTAssertTrue(coordinator.handleDefaultCallingActivityEvidence(
            activityType: "com.apple.calling",
            interactionPresent: true,
            intentType: "INStartCallIntent",
            handle: "+380501234567"
        ))
        XCTAssertEqual(store.attempts.count, 1)
        XCTAssertEqual(store.attempts.first?.attemptID, watchAttemptID)
        XCTAssertNotNil(store.attempts.first?.iPhoneDefaultCallingRequestAt)
    }

    func testAttemptCorrelationRequiresBoundedWindowAndDigitCount() {
        let resolver = SystemDialAttemptAliasResolver(correlationWindow: 5, aliasLifetime: 10)
        let startedAt = Date(timeIntervalSince1970: 100)
        let standaloneID = UUID()
        resolver.registerStandalone(attemptID: standaloneID, startedAt: startedAt, numberDigitCount: 12)
        XCTAssertNil(resolver.correlate(watchAttemptID: UUID(), at: startedAt.addingTimeInterval(1), numberDigitCount: 10))
        XCTAssertNil(resolver.correlate(watchAttemptID: UUID(), at: startedAt.addingTimeInterval(6), numberDigitCount: 12))
    }

    func testExpiredAttemptAliasIsNotReused() {
        let resolver = SystemDialAttemptAliasResolver(correlationWindow: 5, aliasLifetime: 2)
        let now = Date(timeIntervalSince1970: 100)
        let standaloneID = UUID(), watchID = UUID()
        resolver.registerStandalone(attemptID: standaloneID, startedAt: now, numberDigitCount: 12)
        XCTAssertEqual(resolver.correlate(watchAttemptID: watchID, at: now, numberDigitCount: 12), standaloneID)
        XCTAssertNil(resolver.resolve(watchAttemptID: watchID, now: now.addingTimeInterval(3)))
    }

    func testDefaultCallDiagnosticsPersistNoRawHandle() async throws {
        let url = temporaryStoreURL()
        let store = SystemDialDiagnosticStore(fileURL: url)
        let coordinator = makeIOSCoordinator(store: store) { _, completion in completion(true) }
        XCTAssertTrue(coordinator.handleDefaultCallingActivityEvidence(
            activityType: "com.apple.calling",
            interactionPresent: true,
            intentType: "INStartCallIntent",
            handle: "+380501234567"
        ))
        await store.flush()
        let persisted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(persisted.contains("+380501234567"))
        XCTAssertTrue(persisted.contains("numberDigitCount"))
    }

    func testSecondDialCannotOverlapFirstPreflight() {
        let admission = SystemDialAttemptAdmission()
        XCTAssertTrue(admission.begin())
        XCTAssertFalse(admission.begin())
        admission.end()
        XCTAssertTrue(admission.begin())
    }

    func testTelHandoffContinuesAfterPreflightFailure() {
        XCTAssertTrue(SystemDialPreflightPolicy.shouldRequestTelHandoff(numberIsValid: true, preflightSucceeded: false))
        XCTAssertFalse(SystemDialPreflightPolicy.shouldRequestTelHandoff(numberIsValid: false, preflightSucceeded: false))
    }

    func testEveryKnownClassificationMapsToD24CodeAndCompactUkrainianTitle() {
        let expected = [
            SystemDialClassification.preparing: "D24-05",
            SystemDialClassification.ready: "D24-05",
            SystemDialClassification.watchNetworkUnavailable: "D24-01",
            SystemDialClassification.wcNotActivated: "D24-02",
            SystemDialClassification.iPhoneNeedsUnlock: "D24-03",
            SystemDialClassification.iPhoneAppUnreachable: "D24-04",
            SystemDialClassification.iPhoneReady: "D24-05",
            SystemDialClassification.telHandoffRequested: "D24-06",
            SystemDialClassification.systemCallObserved: "D24-07",
            SystemDialClassification.systemCallConnected: "D24-08",
            SystemDialClassification.systemCallEnded: "D24-09",
            SystemDialClassification.systemCallEndedBeforeConnect: "D24-10",
            SystemDialClassification.noSystemCallEvidence: "D24-11",
            SystemDialClassification.unknownAfterTelHandoff: "D24-12"
        ]
        XCTAssertEqual(Set(expected.keys), Set(SystemDialClassification.knownValues))
        for classification in SystemDialClassification.knownValues {
            let summary = SystemDialUserSummary.make(classification: classification)
            XCTAssertEqual(summary.code, expected[classification])
            XCTAssertFalse(summary.title.isEmpty)
            XCTAssertNotEqual(summary.title, classification)
            XCTAssertLessThanOrEqual(summary.title.count, 34)
        }
    }

    func testUnknownClassificationMapsToD24Twelve() {
        XCTAssertEqual(SystemDialUserSummary.make(classification: "FUTURE_UNKNOWN").code, "D24-12")
    }

    func testWatchResultSummaryDoesNotRequireRawDiagnosticLines() {
        var attempt = SystemDialAttempt.make(numberDigitCount: 10, classification: SystemDialClassification.systemCallConnected)
        attempt.events = [.init(source: "watch", event: "raw_private_event", status: "raw_status", attemptID: attempt.attemptID)]
        let summary = SystemDialUserSummary.make(from: attempt)
        XCTAssertEqual(summary.title, "З’єднано")
        XCTAssertFalse(summary.title.contains("raw_private_event"))
        XCTAssertFalse(summary.code.contains("raw_status"))
    }

    func testPersistenceRevisionsAreMonotonicAndNoOpDoesNotAdvance() {
        let store = makeStore()
        let id = UUID()
        XCTAssertEqual(store.revision, 0)
        store.upsert(.make(attemptID: id, numberDigitCount: 10))
        XCTAssertEqual(store.revision, 1)
        store.update(id: id) { $0.classification = SystemDialClassification.iPhoneReady }
        XCTAssertEqual(store.revision, 2)
        store.update(id: id) { $0.classification = SystemDialClassification.iPhoneReady }
        XCTAssertEqual(store.revision, 2)
    }

    func testStalePersistenceRevisionCannotOverwriteNewer() async throws {
        let url = temporaryStoreURL()
        let worker = SystemDialPersistenceWorker()
        let newer = SystemDialAttempt.make(numberDigitCount: 10, classification: SystemDialClassification.systemCallConnected)
        let older = SystemDialAttempt.make(numberDigitCount: 10, classification: SystemDialClassification.preparing)
        try await worker.persist(snapshot: [newer], revision: 2, fileURL: url)
        try await worker.persist(snapshot: [older], revision: 1, fileURL: url)
        let persisted = try decodeAttempts(at: url)
        XCTAssertEqual(persisted.first?.classification, SystemDialClassification.systemCallConnected)
        let persistedRevision = await worker.persistedRevision
        XCTAssertEqual(persistedRevision, 2)
    }

    func testRapidUpdatesAndFlushPersistNewestState() async throws {
        let url = temporaryStoreURL()
        let store = SystemDialDiagnosticStore(fileURL: url)
        let id = UUID()
        store.upsert(.make(attemptID: id, numberDigitCount: 10))
        for index in 0..<20 {
            store.updateAndRecord(id: id, source: "watch", event: "rapid_\(index)", status: "ok") {
                $0.finishedAt = Date(timeIntervalSince1970: Double(index))
            }
        }
        await store.flush()
        let persisted = try decodeAttempts(at: url).first
        XCTAssertEqual(persisted?.finishedAt, Date(timeIntervalSince1970: 19))
        XCTAssertEqual(persisted?.events.last?.event, "rapid_19")
    }

    func testFlushWaitsForRequestedRevision() async throws {
        let url = temporaryStoreURL()
        let store = SystemDialDiagnosticStore(fileURL: url)
        let id = UUID()
        store.upsert(.make(attemptID: id, numberDigitCount: 10, classification: SystemDialClassification.telHandoffRequested))
        let requestedRevision = store.revision
        await store.flush()
        XCTAssertEqual(try decodeAttempts(at: url).first?.classification, SystemDialClassification.telHandoffRequested)
        XCTAssertEqual(requestedRevision, store.revision)
    }

    func testRapidUpdateFlushThenNewerUpdatePersistsNewest() async throws {
        let url = temporaryStoreURL()
        let store = SystemDialDiagnosticStore(fileURL: url)
        let id = UUID()
        store.upsert(.make(attemptID: id, numberDigitCount: 10))
        store.update(id: id) { $0.classification = SystemDialClassification.iPhoneReady }
        let flushing = Task { await store.flush() }
        store.update(id: id) { $0.classification = SystemDialClassification.systemCallConnected }
        await flushing.value
        await store.flush()
        XCTAssertEqual(try decodeAttempts(at: url).first?.classification, SystemDialClassification.systemCallConnected)
    }

    func testDuplicateResignLifecycleRecordedOnce() {
        var attempt = handedOffAttempt()
        XCTAssertTrue(SystemDialLifecycleRecorder.recordFirstResign(in: &attempt))
        XCTAssertFalse(SystemDialLifecycleRecorder.recordFirstResign(in: &attempt))
        XCTAssertEqual(attempt.events.filter { $0.event == "watch_resigned_active" }.count, 1)
    }

    func testDuplicateReturnLifecycleRecordedOnce() {
        var attempt = handedOffAttempt()
        XCTAssertTrue(SystemDialLifecycleRecorder.recordFirstReturn(in: &attempt))
        XCTAssertFalse(SystemDialLifecycleRecorder.recordFirstReturn(in: &attempt))
        XCTAssertEqual(attempt.events.filter { $0.event == "watch_returned_active" }.count, 1)
    }

    func testConnectedAndEndedSummariesAreSuccessful() {
        XCTAssertEqual(SystemDialUserSummary.make(classification: SystemDialClassification.systemCallConnected).severity, .success)
        XCTAssertEqual(SystemDialUserSummary.make(classification: SystemDialClassification.systemCallEnded).severity, .success)
    }

    func testIPhoneUnavailableSummaryIsWarningOrFailure() {
        let severity = SystemDialUserSummary.make(classification: SystemDialClassification.iPhoneAppUnreachable).severity
        XCTAssertTrue(severity == .warning || severity == .failure)
    }

    func testNoEvidenceSummaryDoesNotClaimRelayFailure() {
        let summary = SystemDialUserSummary.make(classification: SystemDialClassification.noSystemCallEvidence)
        let text = "\(summary.title) \(summary.detail ?? "")".lowercased()
        XCTAssertFalse(text.contains("relay failed"))
        XCTAssertFalse(text.contains("phone relay failed"))
    }

    func testBuild21PersistedAttemptJSONStillDecodes() throws {
        let json = """
        [{"attemptID":"0DAD90C0-47D5-44B5-B7C8-982B9368A950","startedAt":"2026-09-23T20:00:00Z","numberDigitCount":12,"watchNetworkStatus":"satisfied","watchNetworkInterfaces":["wifi"],"wcSupported":true,"wcActivationState":"activated","wcReachableBeforePing":true,"pingResults":[],"classification":"TEL_HANDOFF_REQUESTED","events":[]}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let attempts = try decoder.decode([SystemDialAttempt].self, from: Data(json.utf8))
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].classification, SystemDialClassification.telHandoffRequested)
        XCTAssertNil(attempts[0].watchReturnedActiveAt)
        XCTAssertNil(attempts[0].iPhoneDefaultCallingRequestAt)
        XCTAssertNil(attempts[0].iPhoneTelephonyFallbackRequestedAt)
        XCTAssertNil(attempts[0].iPhoneTelephonyFallbackOpenCompletedAt)
        XCTAssertNil(attempts[0].iPhoneTelephonyFallbackOpenAccepted)
    }

    private func classification(
        activation: String = "activated",
        reachable: Bool = true,
        needsUnlock: Bool? = false,
        replied: Bool = false
    ) -> String {
        SystemDialClassification.preflight(
            networkStatus: "satisfied",
            wcSupported: true,
            activationState: activation,
            reachable: reachable,
            needsUnlock: needsUnlock,
            replied: replied
        )
    }

    private func makeStore() -> SystemDialDiagnosticStore { SystemDialDiagnosticStore(fileURL: temporaryStoreURL()) }
    private func temporaryStoreURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("system-dial-\(UUID().uuidString).json") }
    private func decodeAttempts(at url: URL) throws -> [SystemDialAttempt] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SystemDialAttempt].self, from: Data(contentsOf: url))
    }
    private func handedOffAttempt() -> SystemDialAttempt {
        var attempt = SystemDialAttempt.make(numberDigitCount: 10)
        attempt.telHandoffRequestedAt = Date()
        return attempt
    }

    private func intentPerson(_ handle: String) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: handle, type: .phoneNumber),
            nameComponents: nil,
            displayName: nil,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: nil
        )
    }

    private func makeIOSCoordinator(
        store: SystemDialDiagnosticStore,
        opener: @escaping IOSSystemDialCoordinator.URLOpener = { _, completion in completion(true) }
    ) -> IOSSystemDialCoordinator {
        IOSSystemDialCoordinator(session: nil, store: store, network: SystemDialNetworkMonitor(), urlOpener: opener)
    }

    private func handoffMessage(id: UUID, digitCount: Int) -> [String: Any] {
        [
            "type": "systemDialHandoff",
            "attemptID": id.uuidString,
            "handoffAt": Date().timeIntervalSince1970,
            "numberDigitCount": digitCount
        ]
    }
}

private enum TestSystemDialError: Error { case timeout, transport }

final class WiFiSecureCallTests: XCTestCase {
    func testLegalCallStateTransitions() {
        let id = UUID()
        XCTAssertTrue(CallStateTransition.isLegal(from: .idle, to: .outgoingRinging(id)))
        XCTAssertTrue(CallStateTransition.isLegal(from: .outgoingRinging(id), to: .connecting(id)))
        XCTAssertTrue(CallStateTransition.isLegal(from: .connecting(id), to: .active(id)))
        XCTAssertTrue(CallStateTransition.isLegal(from: .active(id), to: .reconnecting(id)))
        XCTAssertTrue(CallStateTransition.isLegal(from: .reconnecting(id), to: .active(id)))
        XCTAssertTrue(CallStateTransition.isLegal(from: .active(id), to: .ending(id)))
        XCTAssertTrue(CallStateTransition.isLegal(from: .ending(id), to: .ended(id)))
    }

    func testDuplicateStartRejected() {
        let first = UUID(), second = UUID()
        XCTAssertFalse(CallStateTransition.isLegal(from: .outgoingRinging(first), to: .outgoingRinging(second)))
    }

    func testExpiredAcceptBecomesTerminalFailure() {
        let id = UUID()
        XCTAssertTrue(CallStateTransition.isLegal(from: .incomingRinging(id), to: .failed(id, .callExpired)))
        XCTAssertTrue(CallState.failed(id, .callExpired).isTerminal)
    }

    func testCancelAcceptRaceClientHonorsCurrentTerminalState() {
        let id = UUID()
        XCTAssertFalse(CallStateTransition.isLegal(from: .failed(id, .callCancelled), to: .connecting(id)))
    }

    func testAudioPacketBinaryRoundTrip() {
        let packet = AudioPacket(type: .audio, callID: UUID(), sequence: 42, timestampMicroseconds: 9_123, payload: Data(repeating: 7, count: 640))
        XCTAssertEqual(AudioPacket.decode(packet.encode()), packet)
        XCTAssertEqual(packet.encode().count, 674)
    }

    func testSequenceIsMonotonic() {
        let id = UUID()
        let packets = (1...5).map { AudioPacket(type: .audio, callID: id, sequence: UInt64($0), timestampMicroseconds: UInt64($0 * 20_000), payload: Data()) }
        XCTAssertEqual(packets.map(\.sequence), packets.map(\.sequence).sorted())
    }

    func testJitterBufferIsBoundedAndFillsMissingFrameWithNil() {
        let id = UUID(); var buffer = JitterBuffer(initialMilliseconds: 60, maximumMilliseconds: 120)
        for value in 1...20 { buffer.insert(AudioPacket(type: .audio, callID: id, sequence: UInt64(value), timestampMicroseconds: 0, payload: Data(repeating: UInt8(value), count: 640))) }
        XCTAssertLessThanOrEqual(buffer.packets.count, 6)
        var missing = JitterBuffer(initialMilliseconds: 40); missing.insert(AudioPacket(type: .audio, callID: id, sequence: 4, timestampMicroseconds: 0, payload: Data(repeating: 1, count: 640)))
        missing.insert(AudioPacket(type: .audio, callID: id, sequence: 6, timestampMicroseconds: 0, payload: Data(repeating: 2, count: 640)))
        XCTAssertEqual(missing.nextPayload(), Data(repeating: 1, count: 640))
        XCTAssertEqual(missing.nextPayload(), Data(repeating: 0, count: 640))
    }

    func testReconnectScheduleIsBounded() {
        let schedule = ReconnectSchedule()
        XCTAssertEqual(Array(schedule.intervals.prefix(4)), [0.25, 0.5, 1, 2])
        XCTAssertLessThanOrEqual(schedule.intervals.reduce(0, +), 10)
        XCTAssertTrue(schedule.intervals.allSatisfy { $0 <= 2 })
    }

    func testAPIModelEncodeDecode() throws {
        let response = CallResponse(callID: UUID(), caller: .A, callee: .B, state: .accepted, expiresAt: Date(timeIntervalSince1970: 100), mediaToken: "redacted-test")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(CallResponse.self, from: encoder.encode(response)), response)
    }

    func testFailureTerminalState() {
        XCTAssertTrue(CallState.failed(nil, .networkLost).isTerminal)
        XCTAssertFalse(CallState.active(UUID()).isTerminal)
    }

    func testPartialCaptureStartFailureRemovesInstalledSource() {
        var lifecycle = CaptureSourceLifecycle(), installs = 0, removes = 0
        XCTAssertThrowsError(try lifecycle.install(
            installSource: { installs += 1 },
            startEngine: { throw CallFailure.audioFailed },
            removeSource: { removes += 1 }
        ))
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(removes, 1)
        XCTAssertFalse(lifecycle.isInstalled)
    }

    func testRepeatedCaptureStartStopCannotDuplicateSourceAndCleanupIsIdempotent() throws {
        var lifecycle = CaptureSourceLifecycle(), installs = 0, removes = 0
        try lifecycle.install(installSource: { installs += 1 }, startEngine: {}, removeSource: { removes += 1 })
        XCTAssertThrowsError(try lifecycle.install(installSource: { installs += 1 }, startEngine: {}, removeSource: { removes += 1 }))
        lifecycle.remove { removes += 1 }
        lifecycle.remove { removes += 1 }
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(removes, 1)
        XCTAssertFalse(lifecycle.isInstalled)
    }

    func testMicrophonePCMConvertsToCanonicalNetworkFrame() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let networkFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: networkFormat))
        converter.primeMethod = .none
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 960))
        input.frameLength = 960
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        for index in 0..<Int(input.frameLength) { samples[index] = sin(Float(index) * 0.04) * 0.25 }

        let data = try XCTUnwrap(AudioEngine.convertToNetworkPCM(input, converter: converter))

        XCTAssertEqual(data.count, AudioEngine.bytesPerFrame)
        let metrics = try XCTUnwrap(AudioEngine.signalMetrics(forCanonicalPCM: data))
        XCTAssertEqual(metrics.frameCount, 320)
        XCTAssertTrue(metrics.hasNonzeroSignal, "Conversion must preserve nonzero signal energy")
        XCTAssertGreaterThan(metrics.rms, 0)
        XCTAssertGreaterThan(metrics.peak, 0)
    }

    func testCanonicalPCMFormatCopyAndMalformedFrames() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        XCTAssertTrue(AudioEngine.isCanonicalNetworkFormat(format))
        var payload = Data(count: AudioEngine.bytesPerFrame)
        payload[0] = 1
        let buffer = try XCTUnwrap(AudioEngine.canonicalBuffer(from: payload, format: format))
        XCTAssertEqual(buffer.frameLength, 320)
        XCTAssertEqual(AudioEngine.pcmData(from: buffer), payload)
        XCTAssertNil(AudioEngine.canonicalBuffer(from: Data(count: 639), format: format))
        buffer.frameLength = 319
        XCTAssertNil(AudioEngine.pcmData(from: buffer))
    }

    func testCanonicalPCMSignalMetricsDetectZeroAndNonzero() throws {
        let zero = try XCTUnwrap(AudioEngine.signalMetrics(forCanonicalPCM: Data(count: AudioEngine.bytesPerFrame)))
        XCTAssertFalse(zero.hasNonzeroSignal)
        XCTAssertEqual(zero.rms, 0)
        XCTAssertEqual(zero.peak, 0)

        var nonzero = Data(count: AudioEngine.bytesPerFrame)
        nonzero[10] = 0xff
        nonzero[11] = 0x7f
        let metrics = try XCTUnwrap(AudioEngine.signalMetrics(forCanonicalPCM: nonzero))
        XCTAssertTrue(metrics.hasNonzeroSignal)
        XCTAssertEqual(metrics.nonzeroCount, 1)
        XCTAssertGreaterThan(metrics.rms, 0)
        XCTAssertGreaterThan(metrics.peak, 0.99)
    }

    func testAudioFlowWatchdogClassifiesEveryMissingStage() {
        XCTAssertEqual(AudioFlowMilestones().failureStage, .noMicCallback)
        XCTAssertEqual(AudioFlowMilestones(micCallback: true).failureStage, .conversionFailure)
        XCTAssertEqual(AudioFlowMilestones(micCallback: true, networkPCMGenerated: true).failureStage, .sendFailure)
        XCTAssertEqual(AudioFlowMilestones(micCallback: true, networkPCMGenerated: true, networkFrameSent: true).failureStage, .receiveAbsent)
        XCTAssertEqual(AudioFlowMilestones(micCallback: true, networkPCMGenerated: true, networkFrameSent: true, remoteFrameReceived: true).failureStage, .playbackScheduleFailure)
        XCTAssertEqual(AudioFlowMilestones(micCallback: true, networkPCMGenerated: true, networkFrameSent: true, remoteFrameReceived: true, playbackScheduled: true).failureStage, .renderFailure)
        let complete = AudioFlowMilestones(micCallback: true, networkPCMGenerated: true, networkFrameSent: true, remoteFrameReceived: true, playbackScheduled: true, playbackRendered: true)
        XCTAssertNil(complete.failureStage)
        XCTAssertTrue(complete.isOperational(transportActive: true), "Silence is valid; operational state must not require nonzero voice energy")
        XCTAssertFalse(complete.isOperational(transportActive: false))
    }

    func testAudioRecoveryBudgetAllowsExactlyOneRecoveryPerGeneration() {
        var budget = AudioRecoveryBudget()
        XCTAssertTrue(budget.claim())
        XCTAssertFalse(budget.claim())
    }

    func testAudioWatchdogPreservesCallAfterRecoveryBudgetAndForTransportStages() {
        XCTAssertEqual(AudioWatchdogPolicy.action(for: .noMicCallback, recoveryAvailable: true), .recover)
        XCTAssertEqual(AudioWatchdogPolicy.action(for: .noMicCallback, recoveryAvailable: false), .preserveCall)
        XCTAssertEqual(AudioWatchdogPolicy.action(for: .sendFailure, recoveryAvailable: true), .preserveCall)
        XCTAssertEqual(AudioWatchdogPolicy.action(for: .receiveAbsent, recoveryAvailable: true), .preserveCall)
    }

    func testJitterBufferReordersDropsDuplicatesAndLatePackets() {
        let id = UUID()
        func packet(_ sequence: UInt64) -> AudioPacket {
            AudioPacket(type: .audio, callID: id, sequence: sequence, timestampMicroseconds: sequence * 20_000, payload: Data(repeating: UInt8(sequence), count: 640))
        }
        var jitter = JitterBuffer(initialMilliseconds: 100, maximumMilliseconds: 240)
        [2, 1, 3, 5, 4].forEach { jitter.insert(packet(UInt64($0))) }
        XCTAssertEqual(jitter.stats.reordered, 2)
        jitter.insert(packet(4))
        XCTAssertEqual(jitter.stats.duplicateDropped, 1)
        for sequence in 1...5 { XCTAssertEqual(jitter.nextPayload(), packet(UInt64(sequence)).payload) }
        jitter.insert(packet(3))
        XCTAssertEqual(jitter.stats.lateDropped, 1)
    }

    func testJitterMissingFrameUsesBoundedGraceThenConcealment() {
        let id = UUID()
        func packet(_ sequence: UInt64, byte: UInt8) -> AudioPacket {
            AudioPacket(type: .audio, callID: id, sequence: sequence, timestampMicroseconds: sequence * 20_000, payload: Data(repeating: byte, count: 640))
        }
        var jitter = JitterBuffer(initialMilliseconds: 40, maximumMilliseconds: 200, lateGraceMilliseconds: 20)
        jitter.insert(packet(10, byte: 10)); jitter.insert(packet(12, byte: 12))
        XCTAssertEqual(jitter.nextPayload(), packet(10, byte: 10).payload)
        XCTAssertEqual(jitter.nextPayload(), Data(repeating: 0, count: 640))
        XCTAssertEqual(jitter.stats.missingConcealed, 0)
        XCTAssertEqual(jitter.nextPayload(), Data(repeating: 0, count: 640))
        XCTAssertEqual(jitter.stats.missingConcealed, 1)
        XCTAssertEqual(jitter.nextPayload(), packet(12, byte: 12).payload)
    }

    func testJitterLargeDiscontinuityRebasesDeterministically() {
        let id = UUID(), payload = Data(repeating: 1, count: 640)
        var jitter = JitterBuffer(initialMilliseconds: 40, maximumMilliseconds: 200)
        jitter.insert(AudioPacket(type: .audio, callID: id, sequence: 1, timestampMicroseconds: 0, payload: payload))
        jitter.insert(AudioPacket(type: .audio, callID: id, sequence: 2, timestampMicroseconds: 20_000, payload: payload))
        XCTAssertEqual(jitter.nextPayload(), payload)
        jitter.insert(AudioPacket(type: .audio, callID: id, sequence: 1_000, timestampMicroseconds: 40_000, payload: payload))
        XCTAssertEqual(jitter.stats.rebased, 1)
        XCTAssertEqual(jitter.nextSequence, 1_000)
    }

    func testPlayoutSchedulerRunsOutsideMainThread() {
        let controller = AudioPlayoutController()
        let expectation = expectation(description: "playout")
        let once = LockedOnce()
        controller.start(onFrame: { _ in
            guard once.claim() else { return }
            XCTAssertFalse(Thread.isMainThread)
            expectation.fulfill()
        }, onDiagnostic: { _ in })
        let id = UUID()
        for sequence in 1...5 {
            controller.insert(AudioPacket(type: .audio, callID: id, sequence: UInt64(sequence), timestampMicroseconds: UInt64(sequence * 20_000), payload: Data(repeating: UInt8(sequence), count: 640)))
        }
        wait(for: [expectation], timeout: 2)
        controller.stop()
    }

    func testLowLatencySendQueueDropsOldestAndKeepsNewest() async {
        var continuation: AsyncStream<Int>.Continuation?
        let stream = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(AudioSendQueuePolicy.maximumFrames)) { continuation = $0 }
        var dropped = 0
        for value in 0..<10 {
            if case .dropped = continuation?.yield(value) { dropped += 1 }
        }
        continuation?.finish()
        var values: [Int] = []
        for await value in stream { values.append(value) }
        XCTAssertEqual(AudioSendQueuePolicy.maximumFrames, 6)
        XCTAssertEqual(dropped, 4)
        XCTAssertEqual(values, [4, 5, 6, 7, 8, 9])
    }

    func testRuntimeDiagnosticPayloadContainsNoTokenOrRawAudio() throws {
        let value = NotificationDiagnosticRequest(
            requestID: UUID(), role: .B, platform: "iOS", event: "first_network_audio_frame_sent",
            status: "bytes=640", tokenPrefix: nil, tokenLength: nil, stage: nil,
            errorDomain: nil, errorCode: nil, callID: UUID()
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(value), encoding: .utf8))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("bearer"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("mediaToken"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("payload"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("audioData"))
    }

    func testValidForegroundIncomingNotificationDispatchesOnceWithoutAutoAnswer() {
        let id = UUID()
        var invocations: [(UUID, Bool)] = []

        let outcome = ForegroundIncomingNotification.dispatch(
            userInfo: ["event": "incoming_call", "callID": id.uuidString]
        ) { callID, requestAnswer in
            invocations.append((callID, requestAnswer))
        }

        XCTAssertEqual(outcome, .incoming(id))
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.0, id)
        XCTAssertEqual(invocations.first?.1, false)
    }

    func testForegroundIncomingNotificationRejectsInvalidOrMissingCallID() {
        var invocations = 0
        let invalid = ForegroundIncomingNotification.dispatch(
            userInfo: ["event": "incoming_call", "callID": "not-a-uuid"]
        ) { _, _ in invocations += 1 }
        let missing = ForegroundIncomingNotification.dispatch(
            userInfo: ["event": "incoming_call"]
        ) { _, _ in invocations += 1 }

        XCTAssertEqual(invalid, .invalidCallID)
        XCTAssertEqual(missing, .invalidCallID)
        XCTAssertEqual(invocations, 0)
    }

    func testUnrelatedForegroundNotificationIsNotDispatchedAsCall() {
        var invoked = false
        let outcome = ForegroundIncomingNotification.dispatch(
            userInfo: ["event": "something_else", "callID": UUID().uuidString]
        ) { _, _ in invoked = true }

        XCTAssertEqual(outcome, .unrelated)
        XCTAssertFalse(invoked)
    }

    func testVoIPPayloadRequiresServerCallID() {
        let serverCallID = UUID()
        XCTAssertEqual(
            VoIPIncomingNotification.callID(from: ["event": "incoming_call", "serverCallID": serverCallID.uuidString]),
            serverCallID
        )
        XCTAssertNil(VoIPIncomingNotification.callID(from: ["event": "incoming_call", "callID": serverCallID.uuidString]))
    }

    func testAlertAndVoIPRegistrationsEncodeAsSeparateTokenTypes() throws {
        let encoder = JSONEncoder()
        let alert = DeviceRegistrationRequest(requestID: UUID(), role: .A, token: "alert-token", platform: "watchOS", pushType: .alert)
        let voip = DeviceRegistrationRequest(requestID: UUID(), role: .A, token: "voip-token", platform: "watchOS", pushType: .voip)
        let alertJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(alert)) as? [String: Any])
        let voipJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(voip)) as? [String: Any])
        XCTAssertEqual(alertJSON["pushType"] as? String, "alert")
        XCTAssertEqual(voipJSON["pushType"] as? String, "voip")
        XCTAssertNotEqual(alertJSON["token"] as? String, voipJSON["token"] as? String)
    }

    @MainActor
    func testCallSessionRetainsCallKitAdapter() {
        let config = AppConfig(
            apiBaseURL: URL(string: "https://example.invalid/v1")!,
            mediaURL: URL(string: "wss://example.invalid/media")!,
            role: .B,
            bearerToken: String(repeating: "a", count: 64)
        )
        let session = CallSession(config: config, audio: AudioEngineMock())
        var adapter: RetainedCallKitMock? = RetainedCallKitMock()
        weak var retained = adapter
        session.attach(callKit: adapter!)
        adapter = nil
        XCTAssertNotNil(retained)
        XCTAssertNotNil(retained?.onPrepareAudio)
        XCTAssertNotNil(retained?.onActionFailed)
    }

    @MainActor
    func testAppLaunchRegistersFactoryWithoutCreatingProvider() {
        let capture = RequestCapture()
        let runtime = makeRuntime(capture: capture)
        var creations = 0
        runtime.configureCallKitFactory { creations += 1; return RetainedCallKitMock() }

        XCTAssertEqual(creations, 0)
        XCTAssertEqual(runtime.callKitCreationCount, 0)
    }

    @MainActor
    func testAppAndDelegateFactoryRegistrationCreateOnlyOneAdapter() {
        let runtime = makeRuntime(capture: RequestCapture())
        var appCreations = 0, delegateCreations = 0
        runtime.configureCallKitFactory { appCreations += 1; return RetainedCallKitMock() }
        runtime.configureCallKitFactory { delegateCreations += 1; return RetainedCallKitMock() }

        _ = runtime.ensureCallKit()
        _ = runtime.ensureCallKit()

        XCTAssertEqual(appCreations, 1)
        XCTAssertEqual(delegateCreations, 0)
        XCTAssertEqual(runtime.callKitCreationCount, 1)
    }

    @MainActor
    func testFirstOutgoingCreatesProviderAndSecondOutgoingReusesIt() async {
        let runtime = makeRuntime(capture: RequestCapture())
        let adapter = RetainedCallKitMock()
        adapter.startError = NSError(domain: "CallKitUnitTest", code: 1)
        var creations = 0
        runtime.configureCallKitFactory { creations += 1; return adapter }

        await runtime.startCall()
        runtime.callSession.reset()
        await runtime.startCall()

        XCTAssertEqual(creations, 1)
        XCTAssertEqual(runtime.callKitCreationCount, 1)
        XCTAssertEqual(adapter.startedIDs.count, 2)
    }

    @MainActor
    func testFirstPushKitIncomingCreatesExactlyOneProviderAndDuplicateReusesIt() async {
        let capture = RequestCapture()
        let runtime = makeRuntime(capture: capture)
        let adapter = RetainedCallKitMock()
        var creations = 0
        runtime.configureCallKitFactory { creations += 1; return adapter }
        let callID = UUID()

        await runtime.handleIncomingVoIP(callID: callID)
        await runtime.handleIncomingVoIP(callID: callID)
        await eventually { capture.paths.contains { $0.hasSuffix("/calls/\(callID.uuidString.lowercased())") } }

        XCTAssertEqual(creations, 1)
        XCTAssertEqual(adapter.incomingIDs.count, 1)
    }

    @MainActor
    func testBackgroundIncomingCreatesSingleCallKitIncoming() async throws {
        let capture = RequestCapture()
        let runtime = makeRuntime(capture: capture, role: .A)
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }
        let serverCallID = UUID()

        let handled = await runtime.handleIncomingBackgroundNotification(callID: serverCallID)

        XCTAssertTrue(handled)
        let localCallKitUUID = try XCTUnwrap(adapter.incomingIDs.first)
        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertNotEqual(localCallKitUUID, serverCallID)
        XCTAssertEqual(runtime.callSession.state.callID, serverCallID)
    }

    @MainActor
    func testDuplicateBackgroundIncomingSameCallIsSuppressed() async {
        let runtime = makeRuntime(capture: RequestCapture(), role: .A)
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }
        let callID = UUID()

        let firstHandled = await runtime.handleIncomingBackgroundNotification(callID: callID)
        let secondHandled = await runtime.handleIncomingBackgroundNotification(callID: callID)
        XCTAssertTrue(firstHandled)
        XCTAssertTrue(secondHandled)

        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertEqual(runtime.callSession.state.callID, callID)
    }

    @MainActor
    func testBackgroundIncomingCannotReplaceDifferentBusyCall() async {
        let runtime = makeRuntime(capture: RequestCapture(), role: .A)
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }
        let firstCallID = UUID(), secondCallID = UUID()

        let firstHandled = await runtime.handleIncomingBackgroundNotification(callID: firstCallID)
        let secondHandled = await runtime.handleIncomingBackgroundNotification(callID: secondCallID)
        XCTAssertTrue(firstHandled)
        XCTAssertFalse(secondHandled)

        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertEqual(runtime.callSession.state.callID, firstCallID)
    }

    @MainActor
    func testTerminalSameCallBackgroundDuplicateDoesNotResurrectCall() async {
        let capture = RequestCapture()
        capture.getState = .cancelled
        let runtime = makeRuntime(capture: capture, role: .A)
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }
        let callID = UUID()

        _ = await runtime.handleIncomingBackgroundNotification(callID: callID)
        await eventually { runtime.callSession.state.isTerminal }
        let reportsBeforeDuplicate = adapter.incomingIDs.count

        let duplicateHandled = await runtime.handleIncomingBackgroundNotification(callID: callID)
        XCTAssertFalse(duplicateHandled)
        XCTAssertTrue(runtime.callSession.state.isTerminal)
        XCTAssertEqual(adapter.incomingIDs.count, reportsBeforeDuplicate)
    }

    @MainActor
    func testSimultaneousEnsureCallKitCreatesExactlyOneProvider() async {
        let runtime = makeRuntime(capture: RequestCapture())
        var creations = 0
        runtime.configureCallKitFactory { creations += 1; return RetainedCallKitMock() }

        await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0..<20 {
                group.addTask { @MainActor in runtime.ensureCallKit().map { ObjectIdentifier($0) } }
            }
            var identities: [ObjectIdentifier] = []
            for await value in group { if let value { identities.append(value) } }
            XCTAssertEqual(Set(identities).count, 1)
        }
        XCTAssertEqual(creations, 1)
    }

    @MainActor
    func testCallKitStartRejectionMapsToTerminalFailureAndDiagnostic() async {
        let config = AppConfig(
            apiBaseURL: URL(string: "https://example.invalid/v1")!,
            mediaURL: URL(string: "wss://example.invalid/media")!,
            role: .B,
            bearerToken: String(repeating: "a", count: 64)
        )
        let adapter = RetainedCallKitMock()
        adapter.startError = NSError(domain: "CallKitUnitTest", code: 42)
        let session = CallSession(config: config, audio: AudioEngineMock())
        session.attach(callKit: adapter)
        let eventCount = Diagnostics.shared.events.count

        await session.startCall()

        guard case .failed(_, .callKitRejected) = session.state else {
            return XCTFail("Expected callKitRejected terminal state")
        }
        XCTAssertTrue(Diagnostics.shared.events.dropFirst(eventCount).contains {
            $0.category == "callKitError" &&
            $0.value == "stage=startOutgoing domain=CallKitUnitTest code=42"
        })
    }

    @MainActor
    func testUnapprovedCallKitStartNeverCreatesServerCall() async {
        let capture = RequestCapture()
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock()
        adapter.startError = NSError(domain: "WiFiSecureCall.CallKitTransaction", code: 1)
        session.attach(callKit: adapter)

        await session.startCall()

        guard case .failed(_, .callKitRejected) = session.state else {
            return XCTFail("Expected callKitRejected terminal state")
        }
        XCTAssertFalse(capture.paths.contains { $0 == "/v1/calls" })
        XCTAssertNil(session.activeCallKitUUID)
    }

    @MainActor
    func testOutgoingUsesDistinctLocalCallKitUUIDAndServerAPIReceivesServerCallID() async throws {
        let capture = RequestCapture()
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock()
        session.attach(callKit: adapter)

        await session.startCall()

        let serverCallID = try XCTUnwrap(session.state.callID)
        let localCallKitUUID = try XCTUnwrap(adapter.startedIDs.first)
        XCTAssertEqual(session.activeCallKitUUID, localCallKitUUID)
        XCTAssertNotEqual(serverCallID, localCallKitUUID)

        try await adapter.approveStart(localCallKitUUID)
        await eventually { capture.createdCallID == serverCallID }
        XCTAssertEqual(capture.createdCallID, serverCallID)
        XCTAssertNotEqual(capture.createdCallID, localCallKitUUID)
    }

    @MainActor
    func testIncomingPushReportsPromptlyWhileValidationRunsAndDeduplicates() async throws {
        let capture = RequestCapture()
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock()
        adapter.onReportIncoming = { capture.events.append("report") }
        capture.onRequest = { request in
            if request.httpMethod == "GET" { capture.events.append("get") }
        }
        session.attach(callKit: adapter)
        let serverCallID = UUID()

        await session.handleIncomingVoIP(callID: serverCallID)
        await session.handleIncomingVoIP(callID: serverCallID)
        await eventually { capture.events.contains("get") }

        let localCallKitUUID = try XCTUnwrap(adapter.incomingIDs.first)
        XCTAssertNotEqual(serverCallID, localCallKitUUID)
        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertTrue(capture.events.contains("report"))
        XCTAssertTrue(capture.events.contains("get"))
        XCTAssertEqual(adapter.answerIDs.count, 0)
    }

    @MainActor
    func testDelayedPushForCancelledCallIsPromptlyReportedThenEnded() async throws {
        let capture = RequestCapture(); capture.getState = .cancelled
        let runtime = makeRuntime(capture: capture)
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }
        let callID = UUID()

        await runtime.handleIncomingVoIP(callID: callID)
        await eventually { adapter.endedIDs.count == 1 }

        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertEqual(adapter.endedIDs, adapter.incomingIDs)
        XCTAssertTrue(runtime.callSession.state.isTerminal)
    }

    @MainActor
    func testLateStartApprovalAfterGenerationEndedCannotCreateServerCall() async throws {
        let capture = RequestCapture()
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        let staleLocalID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveEnd(staleLocalID)
        do {
            try await adapter.approveStart(staleLocalID)
            XCTFail("Stale start approval must fail")
        } catch { }
        XCTAssertFalse(capture.paths.contains { $0 == "/v1/calls" })
    }

    @MainActor
    func testAnswerAndEndCallbacksMapLocalUUIDBackToServerCallIDAndClearMapping() async throws {
        let capture = RequestCapture()
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock()
        session.attach(callKit: adapter)
        let serverCallID = UUID()
        await session.handleIncomingVoIP(callID: serverCallID)
        let localCallKitUUID = try XCTUnwrap(session.activeCallKitUUID)

        capture.mutationState = .accepted
        try await adapter.approveAnswer(localCallKitUUID)
        await eventually { capture.paths.contains { $0.hasSuffix("/calls/\(serverCallID.uuidString.lowercased())/accept") } }
        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/calls/\(serverCallID.uuidString.lowercased())/accept") })

        capture.mutationState = .ended
        try await adapter.approveEnd(localCallKitUUID)
        await eventually {
            session.state.isTerminal && capture.paths.contains {
                $0.hasSuffix("/calls/\(serverCallID.uuidString.lowercased())/end")
            }
        }
        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/calls/\(serverCallID.uuidString.lowercased())/end") })
        XCTAssertTrue(adapter.endedIDs.allSatisfy { $0 == localCallKitUUID })
        XCTAssertNil(session.activeCallKitUUID)
    }

    @MainActor
    func testAppRequestedEndWhileOutgoingRingingCancelsNormally() async throws {
        let capture = RequestCapture(); capture.mutationState = .cancelled
        let (session, adapter, _, localID) = try await prepareOutgoingRinging(capture: capture)

        let disposition = try await adapter.approveEnd(localID, origin: .appRequested)
        await eventually { capture.paths.contains { $0.hasSuffix("/cancel") } }

        XCTAssertEqual(disposition, .ended)
        XCTAssertTrue(session.state.isTerminal)
        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/cancel") })
    }

    @MainActor
    func testSystemEndWhileServerRingingCancelsNormally() async throws {
        let capture = RequestCapture(); capture.mutationState = .cancelled
        let (session, adapter, _, localID) = try await prepareOutgoingRinging(capture: capture)

        let disposition = try await adapter.approveEnd(localID, origin: .system)
        await eventually { capture.paths.contains { $0.hasSuffix("/cancel") } }

        XCTAssertEqual(disposition, .ended)
        XCTAssertTrue(session.state.isTerminal)
        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/cancel") })
    }

    @MainActor
    func testSystemEndAfterRemoteAcceptPreservesOutgoingCall() async throws {
        let capture = RequestCapture()
        let (session, adapter, serverID, localID) = try await prepareOutgoingRinging(capture: capture)
        capture.getState = .accepted

        let disposition = try await adapter.approveEnd(localID, origin: .system)

        XCTAssertEqual(disposition, .preserveCall)
        XCTAssertEqual(session.state, .connecting(serverID))
        XCTAssertFalse(capture.paths.contains { $0.hasSuffix("/cancel") || $0.hasSuffix("/end") })
    }

    @MainActor
    func testAcceptedSystemEndWithActivatedCallKitStartsAudioAndMedia() async throws {
        let capture = RequestCapture()
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let (session, adapter, serverID, localID) = try await prepareOutgoingRinging(capture: capture, audio: audio, media: media)
        adapter.onAudioActivated?(localID)
        capture.getState = .accepted

        let disposition = try await adapter.approveEnd(localID, origin: .system)
        await eventually { audio.startCount == 1 && media.connectedCallIDs == [serverID] }

        XCTAssertEqual(disposition, .preserveCall)
        XCTAssertEqual(session.state, .connecting(serverID))
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(media.connectedCallIDs, [serverID])
    }

    @MainActor
    func testDuplicateSystemEndDuringPreservedConnectingIsSuppressed() async throws {
        let capture = RequestCapture()
        let (session, adapter, serverID, localID) = try await prepareOutgoingRinging(capture: capture)
        capture.getState = .accepted
        let first = try await adapter.approveEnd(localID, origin: .system)
        XCTAssertEqual(first, .preserveCall)
        let getCountAfterFirst = capture.paths.filter { $0.hasSuffix("/calls/\(serverID.uuidString.lowercased())") }.count

        let second = try await adapter.approveEnd(localID, origin: .system)

        XCTAssertEqual(second, .preserveCall)
        XCTAssertEqual(session.state, .connecting(serverID))
        XCTAssertEqual(capture.paths.filter { $0.hasSuffix("/calls/\(serverID.uuidString.lowercased())") }.count, getCountAfterFirst)
        XCTAssertFalse(capture.paths.contains { $0.hasSuffix("/cancel") || $0.hasSuffix("/end") })
    }

    @MainActor
    func testExplicitAppEndAfterPreservedAcceptanceEndsNormally() async throws {
        let capture = RequestCapture(); capture.mutationState = .ended
        let (session, adapter, _, localID) = try await prepareOutgoingRinging(capture: capture)
        capture.getState = .accepted
        let preserved = try await adapter.approveEnd(localID, origin: .system)
        XCTAssertEqual(preserved, .preserveCall)

        let disposition = try await adapter.approveEnd(localID, origin: .appRequested)
        await eventually { capture.paths.contains { $0.hasSuffix("/end") } }

        XCTAssertEqual(disposition, .ended)
        XCTAssertTrue(session.state.isTerminal)
        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/end") })
    }

    @MainActor
    func testSystemEndAfterCallBecomesActiveEndsNormally() async throws {
        let capture = RequestCapture(); capture.mutationState = .ended
        let media = MediaTransportMock()
        let (session, adapter, serverID, localID) = try await prepareOutgoingRinging(capture: capture, media: media)
        adapter.onAudioActivated?(localID)
        capture.getState = .accepted
        let preserved = try await adapter.approveEnd(localID, origin: .system)
        XCTAssertEqual(preserved, .preserveCall)
        await eventually { !media.connectionIDs.isEmpty }
        let epoch = try XCTUnwrap(media.connectionIDs.last)
        media.onPeerReady?(serverID, epoch)
        await eventually { session.state == .active(serverID) }

        let disposition = try await adapter.approveEnd(localID, origin: .system)
        await eventually { capture.paths.contains { $0.hasSuffix("/end") } }

        XCTAssertEqual(disposition, .ended)
        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/end") })
    }

    @MainActor
    func testSystemEndReconcileUsesExistingRemoteTerminalHandling() async throws {
        let capture = RequestCapture()
        let (session, adapter, _, localID) = try await prepareOutgoingRinging(capture: capture)
        capture.getState = .rejected

        let disposition = try await adapter.approveEnd(localID, origin: .system)

        XCTAssertEqual(disposition, .ended)
        XCTAssertTrue(session.state.isTerminal)
        XCTAssertFalse(capture.paths.contains { $0.hasSuffix("/cancel") || $0.hasSuffix("/end") })
    }

    @MainActor
    func testSystemEndReconcileNetworkFailureFallsBackToNormalCancel() async throws {
        let capture = RequestCapture(); capture.mutationState = .cancelled
        let (session, adapter, _, localID) = try await prepareOutgoingRinging(capture: capture)
        capture.getError = URLError(.timedOut)

        let disposition = try await adapter.approveEnd(localID, origin: .system)
        await eventually { capture.paths.contains { $0.hasSuffix("/cancel") } }

        XCTAssertEqual(disposition, .ended)
        XCTAssertTrue(session.state.isTerminal)
        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/cancel") })
    }

    @MainActor
    func testIncomingIPhoneAnswerPathRemainsUnchanged() async throws {
        let capture = RequestCapture(); capture.mutationState = .accepted
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let session = makeSession(capture: capture, role: .B, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        let serverID = UUID()
        await session.handleIncomingVoIP(callID: serverID)
        let localID = try XCTUnwrap(adapter.incomingIDs.first)

        try await adapter.approveAnswer(localID)
        adapter.onAudioActivated?(localID)
        await eventually { audio.startCount == 1 && media.connectedCallIDs == [serverID] }

        XCTAssertEqual(session.state, .connecting(serverID))
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(media.connectedCallIDs, [serverID])
    }

    @MainActor
    func testCallKitErrorUploadsExactBoundedFields() async throws {
        let capture = RequestCapture()
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock()
        adapter.startError = NSError(domain: "CallKitIdentityTest", code: 7)
        session.attach(callKit: adapter)

        await session.startCall()
        await eventually { capture.callKitDiagnostic != nil }

        let diagnostic = try XCTUnwrap(capture.callKitDiagnostic)
        XCTAssertEqual(diagnostic["event"] as? String, "callkit_error")
        XCTAssertEqual(diagnostic["stage"] as? String, "startOutgoing")
        XCTAssertEqual(diagnostic["errorDomain"] as? String, "CallKitIdentityTest")
        XCTAssertEqual(diagnostic["errorCode"] as? Int, 7)
        XCTAssertNil(diagnostic["localizedDescription"])
    }

    @MainActor
    func testCurrentCallActivationStartsAudioAndUsesServerCallID() async throws {
        let capture = RequestCapture(); capture.getState = .accepted
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let session = makeSession(capture: capture, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)

        await session.startCall()
        let serverID = try XCTUnwrap(session.state.callID)
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)
        await eventually { if case .connecting = session.state { return true }; return false }
        XCTAssertEqual(audio.startCount, 0)

        adapter.onAudioActivated?(localID)
        await eventually { media.connectedCallIDs.contains(serverID) }
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(audio.startMutedValues, [false])
        XCTAssertEqual(media.connectedCallIDs, [serverID])
        XCTAssertEqual(adapter.startedConnectingIDs, [localID])
        XCTAssertTrue(adapter.connectedIDs.isEmpty)
        let epoch = try XCTUnwrap(media.connectionIDs.last)
        media.onPeerReady?(serverID, epoch)
        await eventually { adapter.connectedIDs == [localID] }
        XCTAssertEqual(adapter.connectedIDs, [localID])
        XCTAssertNotEqual(serverID, localID)

        let capturedFrame = Data(repeating: 3, count: AudioEngine.bytesPerFrame)
        audio.onFrame?(capturedFrame)
        await eventually { media.sentPackets.count == 1 }
        XCTAssertEqual(media.sentPackets.first?.callID, serverID)
        XCTAssertEqual(media.sentPackets.first?.payload, capturedFrame)

        let remoteFrame = Data(repeating: 7, count: AudioEngine.bytesPerFrame)
        media.onPacket?(AudioPacket(type: .audio, callID: serverID, sequence: 1, timestampMicroseconds: 1, payload: remoteFrame), epoch)
        media.onPacket?(AudioPacket(type: .audio, callID: serverID, sequence: 2, timestampMicroseconds: 20_001, payload: remoteFrame), epoch)
        media.onPacket?(AudioPacket(type: .audio, callID: serverID, sequence: 3, timestampMicroseconds: 40_001, payload: remoteFrame), epoch)
        media.onPacket?(AudioPacket(type: .audio, callID: serverID, sequence: 4, timestampMicroseconds: 60_001, payload: remoteFrame), epoch)
        media.onPacket?(AudioPacket(type: .audio, callID: serverID, sequence: 5, timestampMicroseconds: 80_001, payload: remoteFrame), epoch)
        await eventually { audio.played.contains(remoteFrame) }
        XCTAssertTrue(audio.played.contains(remoteFrame))
    }

    @MainActor
    func testExplicitCallKitMuteRemainsMutedWhenAudioStarts() async throws {
        let capture = RequestCapture(); capture.getState = .accepted
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let session = makeSession(capture: capture, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)
        await eventually { if case .connecting = session.state { return true }; return false }
        try adapter.onMutedRequested?(localID, true)
        adapter.onAudioActivated?(localID)
        await eventually { audio.startCount == 1 }
        XCTAssertEqual(audio.mutedValues, [true])
        XCTAssertEqual(audio.startMutedValues, [true])
        XCTAssertTrue(session.isMuted)
    }

    @MainActor
    func testRepeatedAudioHealthFailureUsesOneRecoveryAndPreservesActiveCall() async throws {
        let capture = RequestCapture(); capture.getState = .accepted
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let session = makeSession(capture: capture, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        let serverID = try XCTUnwrap(session.state.callID)
        try await adapter.approveStart(localID)
        await eventually { if case .connecting = session.state { return true }; return false }
        adapter.onAudioActivated?(localID)
        await eventually { audio.startCount == 1 && !media.connectionIDs.isEmpty }
        let epoch = try XCTUnwrap(media.connectionIDs.last)
        media.onPeerReady?(serverID, epoch)
        await eventually { session.state == .active(serverID) }

        audio.onFailure?(.configurationChanged)
        await eventually { audio.startCount == 2 }
        audio.onFailure?(.configurationChanged)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(session.state, .active(serverID))
        XCTAssertFalse(session.state.isTerminal)
    }

    @MainActor
    func testStaleActivationFromPreviousCallCannotStartNewCallAudio() async throws {
        let capture = RequestCapture(); capture.getState = .accepted
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let session = makeSession(capture: capture, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)

        await session.startCall()
        let oldLocalID = try XCTUnwrap(adapter.startedIDs.first)
        adapter.onActionFailed?(oldLocalID, "start", NSError(domain: "test", code: 1))
        await eventually { session.state.isTerminal }
        await session.startCall()
        let newLocalID = try XCTUnwrap(adapter.startedIDs.last)
        XCTAssertNotEqual(oldLocalID, newLocalID)
        try await adapter.approveStart(newLocalID)
        await eventually { if case .connecting = session.state { return true }; return false }
        adapter.onAudioActivated?(oldLocalID)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(audio.startCount, 0)
        adapter.onAudioActivated?(newLocalID)
        await eventually { audio.startCount == 1 }
        XCTAssertEqual(audio.startCount, 1)
    }

    @MainActor
    func testDidDeactivateStopsCurrentAudio() async throws {
        let capture = RequestCapture(); capture.getState = .accepted
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let session = makeSession(capture: capture, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)
        await eventually { if case .connecting = session.state { return true }; return false }
        adapter.onAudioActivated?(localID)
        await eventually { audio.startCount == 1 }
        let previousStops = audio.stopCount
        adapter.onAudioDeactivated?(localID)
        await eventually { audio.stopCount > previousStops }
        XCTAssertGreaterThan(audio.stopCount, previousStops)
    }

    @MainActor
    func testWatchOutgoingGrantedPermissionReachesCallKitAndServerCreate() async throws {
        let capture = RequestCapture()
        let audio = AudioEngineMock()
        audio.permission = true
        let session = makeSession(capture: capture, role: .A, audio: audio)
        let adapter = RetainedCallKitMock()
        session.attach(callKit: adapter)

        await session.startCall()
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        XCTAssertNotEqual(localID, session.state.callID)
        try await adapter.approveStart(localID)

        await eventually { capture.createdCallID == session.state.callID }
        XCTAssertEqual(capture.createdCallID, session.state.callID)
    }

    @MainActor
    func testTerminalIncomingCleanupCannotBlockNextOutgoingCall() async throws {
        let capture = RequestCapture()
        capture.mutationState = .ended
        let session = makeSession(capture: capture, role: .A)
        let adapter = RetainedCallKitMock()
        session.attach(callKit: adapter)

        await session.handleIncomingVoIP(callID: UUID())
        let incomingLocalID = try XCTUnwrap(adapter.incomingIDs.first)
        try await adapter.approveEnd(incomingLocalID)
        await eventually { session.state.isTerminal }

        await session.startCall()

        XCTAssertEqual(adapter.startedIDs.count, 1)
        guard case .outgoingRinging = session.state else { return XCTFail("Expected fresh outgoing call") }
        XCTAssertNotEqual(adapter.startedIDs.first, incomingLocalID)
    }

    @MainActor
    func testTerminalFailureDoesNotLeaveStaleCallKitUUIDForSecondCall() async throws {
        let capture = RequestCapture()
        let session = makeSession(capture: capture, role: .A)
        let adapter = RetainedCallKitMock()
        adapter.startError = NSError(domain: "first-call", code: 1)
        session.attach(callKit: adapter)

        await session.startCall()
        XCTAssertTrue(session.state.isTerminal)
        let firstLocalID = try XCTUnwrap(adapter.startedIDs.first)
        adapter.startError = nil

        await session.startCall()

        XCTAssertEqual(adapter.startedIDs.count, 2)
        XCTAssertNotEqual(adapter.startedIDs.last, firstLocalID)
        XCTAssertEqual(session.activeCallKitUUID, adapter.startedIDs.last)
    }

    func testPacketSchemasRejectMalformedAudioAndControlPayloads() {
        let id = UUID()
        XCTAssertNil(AudioPacket.decode(AudioPacket(type: .audio, callID: id, sequence: 1, timestampMicroseconds: 0, payload: Data(count: 639)).encode()))
        XCTAssertNil(AudioPacket.decode(AudioPacket(type: .ping, callID: id, sequence: 0, timestampMicroseconds: 0, payload: Data([1])).encode()))
        XCTAssertNotNil(AudioPacket.decode(AudioPacket(type: .ping, callID: id, sequence: 0, timestampMicroseconds: 0, payload: Data()).encode()))
    }

    func testJitterInitialDelayAndReconnectRebase() {
        let id = UUID()
        var jitter = JitterBuffer(initialMilliseconds: 60, maximumMilliseconds: 120)
        jitter.insert(AudioPacket(type: .audio, callID: id, sequence: 90, timestampMicroseconds: 0, payload: Data(repeating: 1, count: 640)))
        XCTAssertNil(jitter.nextPayload())
        jitter.insert(AudioPacket(type: .audio, callID: id, sequence: 91, timestampMicroseconds: 20_000, payload: Data(repeating: 2, count: 640)))
        XCTAssertNil(jitter.nextPayload())
        jitter.insert(AudioPacket(type: .audio, callID: id, sequence: 92, timestampMicroseconds: 40_000, payload: Data(repeating: 3, count: 640)))
        XCTAssertEqual(jitter.nextPayload(), Data(repeating: 1, count: 640))
        jitter.resetForReconnect()
        jitter.insert(AudioPacket(type: .audio, callID: id, sequence: 4_000, timestampMicroseconds: 0, payload: Data(repeating: 4, count: 640)))
        XCTAssertNil(jitter.nextPayload())
    }

    func testProductionConfigRejectsTransportDowngrade() {
        XCTAssertFalse(AppConfig(apiBaseURL: URL(string: "http://example.com/v1")!, mediaURL: URL(string: "wss://example.com/media")!, role: .A, bearerToken: String(repeating: "a", count: 64)).isProductionSafe)
        XCTAssertFalse(AppConfig(apiBaseURL: URL(string: "https://example.com/v1")!, mediaURL: URL(string: "ws://example.com/media")!, role: .A, bearerToken: String(repeating: "a", count: 64)).isProductionSafe)
        XCTAssertTrue(AppConfig(apiBaseURL: URL(string: "https://example.com/v1")!, mediaURL: URL(string: "wss://example.com/media")!, role: .A, bearerToken: String(repeating: "a", count: 64)).isProductionSafe)
    }

    @MainActor
    func testTwoRapidStartCallsCreateOnlyOneCallKitTransaction() async {
        let capture = RequestCapture()
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        async let first: Void = session.startCall()
        async let second: Void = session.startCall()
        _ = await (first, second)
        XCTAssertEqual(adapter.startedIDs.count, 1)
        guard case .outgoingRinging = session.state else { return XCTFail("Expected one ringing call") }
    }

    @MainActor
    func testAcceptedResponseWithoutMediaTokenFailsClosed() async throws {
        let capture = RequestCapture(); capture.getState = .accepted; capture.acceptedMediaToken = nil
        let session = makeSession(capture: capture)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        try await adapter.approveStart(XCTUnwrap(adapter.startedIDs.first))
        await eventually { session.state.isTerminal }
        guard case .failed(_, .invalidServerState) = session.state else { return XCTFail("Expected invalid server state") }
    }

    @MainActor
    func testActiveDeactivateReactivateRestartsAudioExactlyOnce() async throws {
        let capture = RequestCapture(); capture.getState = .accepted
        let audio = AudioEngineMock(), media = MediaTransportMock()
        let session = makeSession(capture: capture, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)
        await eventually { if case .connecting = session.state { return true }; return false }
        adapter.onAudioActivated?(localID)
        await eventually { audio.startCount == 1 }
        adapter.onAudioDeactivated?(localID)
        await eventually { audio.stopCount > 0 }
        adapter.onAudioActivated?(localID)
        await eventually { audio.startCount == 2 }
        XCTAssertEqual(audio.startCount, 2)
    }

    @MainActor
    func testAppMuteUsesCallKitAndAuthoritativeAudioMuteCallback() async throws {
        let capture = RequestCapture()
        let audio = AudioEngineMock()
        let session = makeSession(capture: capture, audio: audio)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        session.toggleMute()
        await eventually { adapter.mutedRequests.count == 1 }
        XCTAssertEqual(adapter.mutedRequests.first?.1, true)
        XCTAssertTrue(session.isMuted)
    }

    @MainActor
    private func prepareOutgoingRinging(
        capture: RequestCapture,
        audio: AudioEngineHandling = AudioEngineMock(),
        media: MediaTransport? = nil
    ) async throws -> (CallSession, RetainedCallKitMock, UUID, UUID) {
        capture.getState = .ringing
        let session = makeSession(capture: capture, role: .B, audio: audio, media: media)
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        let serverID = try XCTUnwrap(session.state.callID)
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)
        await eventually {
            capture.createdCallID == serverID && capture.paths.contains {
                $0.hasSuffix("/calls/\(serverID.uuidString.lowercased())")
            }
        }
        return (session, adapter, serverID, localID)
    }

    @MainActor
    private func makeSession(capture: RequestCapture, role: DeviceRole = .B, audio: AudioEngineHandling = AudioEngineMock(), media: MediaTransport? = nil) -> CallSession {
        let config = AppConfig(
            apiBaseURL: URL(string: "https://unit.test/v1")!,
            mediaURL: URL(string: "wss://unit.test/media")!,
            role: role,
            bearerToken: String(repeating: "a", count: 64)
        )
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.protocolClasses = [CallSessionURLProtocol.self]
        CallSessionURLProtocol.capture = capture
        capture.clientRole = role
        return CallSession(config: config, api: APIClient(config: config, session: URLSession(configuration: urlConfiguration)), audio: audio, media: media)
    }

    @MainActor
    private func makeRuntime(capture: RequestCapture, role: DeviceRole = .B) -> NotificationRuntime {
        let config = AppConfig(
            apiBaseURL: URL(string: "https://unit.test/v1")!,
            mediaURL: URL(string: "wss://unit.test/media")!,
            role: role,
            bearerToken: String(repeating: "a", count: 64)
        )
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.protocolClasses = [CallSessionURLProtocol.self]
        CallSessionURLProtocol.capture = capture
        capture.clientRole = role
        let api = APIClient(config: config, session: URLSession(configuration: urlConfiguration))
        return NotificationRuntime(config: config, api: api, audio: AudioEngineMock(), media: MediaTransportMock())
    }

    @MainActor
    private func eventually(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class LockedOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}

@MainActor
private final class RetainedCallKitMock: CallKitHandling {
    let diagnosticInstanceID = UUID()
    var onLifecycleDiagnostic: ((String, UUID?) -> Void)?
    var onPrepareAudio: (() throws -> Void)?
    var onActionFailed: ((UUID, String, Error) -> Void)?
    var onStartRequested: ((UUID, Date) async throws -> Void)?
    var onAnswerRequested: ((UUID, Date) async throws -> Void)?
    var onEndRequested: ((UUID, Date, CallEndRequestOrigin) async throws -> CallEndDisposition)?
    var onMutedRequested: ((UUID, Bool) throws -> Void)?
    var onActionTimedOut: ((UUID, String) -> Void)?
    var onAudioActivated: ((UUID) -> Void)?
    var onAudioDeactivated: ((UUID?) -> Void)?
    var onProviderReset: ((UUID?) -> Void)?
    var startError: Error?
    var startedIDs: [UUID] = []
    var incomingIDs: [UUID] = []
    var incomingNames: [String?] = []
    var answerIDs: [UUID] = []
    var endRequestIDs: [UUID] = []
    var endedIDs: [UUID] = []
    var startedConnectingIDs: [UUID] = []
    var connectedIDs: [UUID] = []
    var mutedRequests: [(UUID, Bool)] = []
    var onReportIncoming: (() -> Void)?
    func startOutgoing(id: UUID) async throws { startedIDs.append(id); if let startError { throw startError } }
    func reportIncoming(id: UUID) async throws { try await reportIncoming(id: id, callerName: nil) }
    func reportIncoming(id: UUID, callerName: String?) async throws { incomingIDs.append(id); incomingNames.append(callerName); onReportIncoming?() }
    func requestAnswer(id: UUID) async throws { answerIDs.append(id) }
    func requestEnd(id: UUID) async throws { endRequestIDs.append(id) }
    func requestSetMuted(id: UUID, muted: Bool) async throws { mutedRequests.append((id, muted)); try onMutedRequested?(id, muted) }
    func reportOutgoingStartedConnecting(id: UUID) { startedConnectingIDs.append(id) }
    func reportOutgoingConnected(id: UUID) { connectedIDs.append(id) }
    func reportEnded(id: UUID, reason: CallEndReason) { endedIDs.append(id) }
    func approveStart(_ id: UUID) async throws { try await onStartRequested?(id, Date().addingTimeInterval(10)) }
    func approveAnswer(_ id: UUID) async throws { try await onAnswerRequested?(id, Date().addingTimeInterval(10)) }
    @discardableResult
    func approveEnd(_ id: UUID, origin: CallEndRequestOrigin = .appRequested) async throws -> CallEndDisposition {
        try await onEndRequested?(id, Date().addingTimeInterval(10), origin) ?? .ended
    }
}

private final class AudioEngineMock: AudioEngineHandling, @unchecked Sendable {
    var onFrame: (@Sendable (Data) -> Void)?
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)?
    var onFailure: (@Sendable (AudioEngineRuntimeFailure) -> Void)?
    var onMuteChanged: (@Sendable (Bool) -> Void)?
    var permission = true
    var startCount = 0
    var stopCount = 0
    var startMutedValues: [Bool] = []
    var mutedValues: [Bool] = []
    var played: [Data] = []
    func ensureRecordPermission() async -> Bool { permission }
    func configureSession() throws {}
    func start(muted: Bool) throws { startCount += 1; startMutedValues.append(muted) }
    func stop() { stopCount += 1 }
    func setMuted(_ value: Bool) throws { mutedValues.append(value); onMuteChanged?(value) }
    func play(_ payload: Data) { played.append(payload) }
}

private final class MediaTransportMock: MediaTransport, @unchecked Sendable {
    var onPacket: (@Sendable (AudioPacket, UUID) -> Void)?
    var onDisconnect: (@Sendable (MediaDisconnect) -> Void)?
    var onPeerReady: (@Sendable (UUID, UUID) -> Void)?
    var onDiagnostic: (@Sendable (MediaTransportDiagnostic) -> Void)?
    private(set) var connectedCallIDs: [UUID] = []
    private(set) var connectedPeers: [MediaPeerIdentity] = []
    private(set) var sentPackets: [AudioPacket] = []
    private(set) var connectionIDs: [UUID] = []
    func connect(callID: UUID, peer: MediaPeerIdentity, token: String) async throws -> UUID { let id = UUID(); connectedCallIDs.append(callID); connectedPeers.append(peer); connectionIDs.append(id); return id }
    func send(_ packet: AudioPacket, connectionID: UUID) async throws { sentPackets.append(packet) }
    func close(connectionID: UUID?) async {}
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private var _events: [String] = []
    private var _createdCallID: UUID?
    private var _callKitDiagnostic: [String: Any]?
    private var _diagnosticEvents: [String] = []
    var mutationState: ServerCallState = .ended
    var getState: ServerCallState = .ringing
    var getError: Error?
    var acceptedMediaToken: String? = "media-token"
    var onRequest: ((URLRequest) -> Void)?
    var clientRole: DeviceRole = .B

    var paths: [String] { lock.withLock { _paths } }
    var events: [String] {
        get { lock.withLock { _events } }
        set { lock.withLock { _events = newValue } }
    }
    var createdCallID: UUID? { lock.withLock { _createdCallID } }
    var callKitDiagnostic: [String: Any]? { lock.withLock { _callKitDiagnostic } }
    var diagnosticEvents: [String] { lock.withLock { _diagnosticEvents } }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        onRequest?(request)
        let path = request.url?.path ?? ""
        lock.withLock { _paths.append(path) }
        let requestBody = bodyData(from: request)
        if path.hasSuffix("/devices/diagnostics"), let body = requestBody,
           let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let event = value["event"] as? String { lock.withLock { _diagnosticEvents.append(event) } }
            if value["event"] as? String == "callkit_error" {
                lock.withLock { _callKitDiagnostic = value }
            }
            return (response(request, 204), Data())
        }
        if path.hasSuffix("/calls"), request.httpMethod == "POST", let body = requestBody,
           let value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
           let raw = value["callID"] as? String, let callID = UUID(uuidString: raw) {
            lock.withLock { _createdCallID = callID }
            return (response(request, 200), callResponse(callID: callID, state: .ringing, mediaToken: nil, outgoing: true))
        }
        guard let rawID = path.split(separator: "/").dropFirst(2).first,
              let callID = UUID(uuidString: String(rawID)) else {
            return (response(request, 204), Data())
        }
        if request.httpMethod == "GET" {
            if let getError { throw getError }
            let state = getState
            return (response(request, 200), callResponse(callID: callID, state: state, mediaToken: state == .accepted ? acceptedMediaToken : nil, outgoing: callID == createdCallID))
        }
        let state = mutationState
        return (response(request, 200), callResponse(callID: callID, state: state, mediaToken: state == .accepted ? acceptedMediaToken : nil, outgoing: callID == createdCallID))
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func response(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func callResponse(callID: UUID, state: ServerCallState, mediaToken: String?, outgoing: Bool) -> Data {
        let caller = outgoing ? clientRole : (clientRole == .A ? DeviceRole.B : DeviceRole.A)
        let callee = caller == .A ? DeviceRole.B : DeviceRole.A
        let value = CallResponse(callID: callID, caller: caller, callee: callee, state: state, expiresAt: Date(timeIntervalSince1970: 2_000_000_000), mediaToken: mediaToken, ringExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), peerReady: state == .accepted)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(value)
    }
}

private final class CallSessionURLProtocol: URLProtocol {
    static var capture: RequestCapture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let capture = Self.capture else { return }
        do {
            let (response, data) = try capture.handle(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class AccountFoundationTests: XCTestCase {
    func testE164Validation() {
        XCTAssertTrue(E164Phone.isValid("+380501234567"))
        XCTAssertTrue(E164Phone.isValid("+14155550123"))
        XCTAssertEqual(E164Phone.canonicalized("+380 50-123-4567"), "+380501234567")
        for invalid in ["380501234567", "+01234567", "+123", "+380 50", "+1234567890123456"] { XCTAssertFalse(E164Phone.isValid(invalid)) }
    }

    func testAccountStoreMultipleSwitchLogoutAndDelete() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AccountFoundationTests.\(UUID())"))
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let secrets = InMemorySecureTokenStore()
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        let first = accountResponse(phone: "+380501234567")
        let second = accountResponse(phone: "+14155550123")
        try store.add(first); try store.add(second)
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(store.activeAccountID, second.account.accountID)
        store.switchAccount(to: first.account.accountID)
        XCTAssertEqual(store.activeAccountID, first.account.accountID)
        try store.logout(accountID: first.account.accountID)
        XCTAssertEqual(store.accounts, [second.account])
        XCTAssertNil(try secrets.tokens(for: first.account.accountID))
        XCTAssertNotNil(try secrets.tokens(for: second.account.accountID))
        try store.delete(accountID: second.account.accountID)
        XCTAssertTrue(store.accounts.isEmpty)
        let defaultsText = String(data: defaults.data(forKey: "WiFiSecureCall.accounts.v1") ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(defaultsText.contains(first.accessToken)); XCTAssertFalse(defaultsText.contains(second.refreshToken))
    }

    func testAccountStoreRetainsThreeIndependentAccountsAndRemovalIsIsolated() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AccountFoundationTests.Three.\(UUID())"))
        let secrets = InMemorySecureTokenStore()
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        let first = accountResponse(phone: "+380501111111", access: "access-a", refresh: "refresh-a")
        let second = accountResponse(phone: "+380502222222", access: "access-b", refresh: "refresh-b")
        let third = accountResponse(phone: "+380503333333", access: "access-c", refresh: "refresh-c")

        try store.add(first)
        try store.add(second)
        try store.add(third)

        XCTAssertEqual(store.accounts, [first.account, second.account, third.account])
        XCTAssertEqual(store.callableAccounts.count, 3)
        XCTAssertEqual(try secrets.tokens(for: first.account.accountID)?.accessToken, "access-a")
        XCTAssertEqual(try secrets.tokens(for: second.account.accountID)?.accessToken, "access-b")
        XCTAssertEqual(try secrets.tokens(for: third.account.accountID)?.accessToken, "access-c")

        try store.logout(accountID: second.account.accountID)

        XCTAssertEqual(store.accounts, [first.account, third.account])
        XCTAssertNil(try secrets.tokens(for: second.account.accountID))
        XCTAssertEqual(try secrets.tokens(for: first.account.accountID)?.refreshToken, "refresh-a")
        XCTAssertEqual(try secrets.tokens(for: third.account.accountID)?.refreshToken, "refresh-c")
    }

    func testSharedAccountStoreAndCustomInjection() throws {
        XCTAssertTrue(AccountSessionStore.shared === AccountSessionStore.shared)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AccountStoreInjection.\(UUID())"))
        let secrets = InMemorySecureTokenStore()
        var added: UUID?
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults, accountAdded: { added = $0 })
        let response = accountResponse(phone: "+380501234567")
        try store.add(response)
        XCTAssertEqual(added, response.account.accountID)
        XCTAssertFalse(store === AccountSessionStore.shared)
    }

    func testAccountAPIRefreshesOnceForConcurrentRequests() async throws {
        let accountID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "expired", accessExpiresAt: .distantPast, refreshToken: "refresh", refreshExpiresAt: .distantFuture), for: accountID)
        let counter = LockedCounter()
        let session = accountTestSession { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                counter.increment()
                return (200, self.accountResponse(accountID: accountID, phone: "+380501234567", access: "new-access", refresh: "new-refresh"))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (200, AccountMeResponse(accountID: accountID, phoneNumber: "+380501234567", deviceID: InstallationIdentity.shared.id, platform: "iOS"))
        }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session)
        async let one = client.me(accountID: accountID)
        async let two = client.me(accountID: accountID)
        _ = try await (one, two)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "new-refresh")
    }

    func testRefreshFailureSignsOutOnlyAffectedAccount() async throws {
        let first = UUID(), second = UUID(), secrets = InMemorySecureTokenStore()
        let expired = AccountTokens(accessToken: "expired", accessExpiresAt: .distantPast, refreshToken: "bad", refreshExpiresAt: .distantFuture)
        try secrets.save(expired, for: first)
        try secrets.save(AccountTokens(accessToken: "valid", accessExpiresAt: .distantFuture, refreshToken: "good", refreshExpiresAt: .distantFuture), for: second)
        let session = accountTestSession { request in
            if request.url!.path.hasSuffix("/auth/refresh") { return (401, AccountAPIErrorResponse(error: "unauthorized", retryAt: nil)) }
            return (500, AccountAPIErrorResponse(error: "unexpected", retryAt: nil))
        }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session)
        do { _ = try await client.me(accountID: first); XCTFail("refresh succeeded") } catch { }
        XCTAssertNil(try secrets.tokens(for: first))
        XCTAssertNotNil(try secrets.tokens(for: second))
    }

    func testTransientRefreshFailuresPreserveSessions() async throws {
        for failure in [URLError(.timedOut), URLError(.notConnectedToInternet)] {
            let accountID = UUID(), secrets = InMemorySecureTokenStore()
            try secrets.save(AccountTokens(accessToken: "expired", accessExpiresAt: .distantPast, refreshToken: "refresh", refreshExpiresAt: .distantFuture), for: accountID)
            let session = accountTestSession { _ in throw failure }
            let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session)
            do { _ = try await client.me(accountID: accountID); XCTFail("transient refresh succeeded") } catch { }
            XCTAssertNotNil(try secrets.tokens(for: accountID))
        }

        let accountID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "expired", accessExpiresAt: .distantPast, refreshToken: "refresh", refreshExpiresAt: .distantFuture), for: accountID)
        let session = accountTestSession { _ in (500, AccountAPIErrorResponse(error: "temporary", retryAt: nil)) }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session)
        do { _ = try await client.me(accountID: accountID); XCTFail("500 refresh succeeded") } catch { }
        XCTAssertNotNil(try secrets.tokens(for: accountID))
    }

    func testCrossClientRefreshUsesOneProcessWideRequest() async throws {
        let accountID = UUID(), deviceID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "expired", accessExpiresAt: .distantPast, refreshToken: "R0", refreshExpiresAt: .distantFuture), for: accountID)
        let refreshCount = LockedCounter()
        let session = accountTestSession { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                let body = try JSONDecoder.account.decode(AccountRefreshRequest.self, from: try XCTUnwrap(request.httpBody))
                XCTAssertEqual(body.refreshToken, "R0")
                XCTAssertEqual(body.deviceID, deviceID)
                refreshCount.increment()
                Thread.sleep(forTimeInterval: 0.05)
                if refreshCount.value > 1 { return (401, AccountAPIErrorResponse(error: "stale refresh", retryAt: nil)) }
                return (200, self.accountResponse(accountID: accountID, phone: "+380501234567", access: "A1", refresh: "R1"))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A1")
            return (200, AccountMeResponse(accountID: accountID, phoneNumber: "+380501234567", deviceID: deviceID, platform: "iOS"))
        }
        let first = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID)
        let second = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID)

        async let one = first.me(accountID: accountID)
        async let two = second.me(accountID: accountID)
        _ = try await (one, two)

        XCTAssertEqual(refreshCount.value, 1)
        XCTAssertEqual(try secrets.tokens(for: accountID)?.accessToken, "A1")
        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "R1")
    }

    func testStaggeredStaleRefreshSnapshotUsesNewerStoredSession() async throws {
        let accountID = UUID(), deviceID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "A0", accessExpiresAt: .distantPast, refreshToken: "R0", refreshExpiresAt: .distantFuture), for: accountID)
        let refreshCount = LockedCounter()
        let entered = AsyncLatch(), release = AsyncLatch()
        let session = accountTestSession { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                let body = try JSONDecoder.account.decode(AccountRefreshRequest.self, from: try XCTUnwrap(request.httpBody))
                refreshCount.increment()
                if refreshCount.value == 1 {
                    XCTAssertEqual(body.refreshToken, "R0")
                    return (200, self.accountResponse(accountID: accountID, phone: "+380501234567", access: "A1", refresh: "R1"))
                }
                return (200, self.accountResponse(accountID: accountID, phone: "+380501234567", access: "A2", refresh: "R2"))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A1")
            return (200, AccountMeResponse(accountID: accountID, phoneNumber: "+380501234567", deviceID: deviceID, platform: "iOS"))
        }
        let first = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID)
        let second = AccountAPIClient(
            config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID,
            beforeRefresh: { _, _ in await entered.open(); await release.wait() }
        )

        let delayed = Task { try await second.me(accountID: accountID) }
        await entered.wait()
        do {
            _ = try await first.me(accountID: accountID)
            await release.open()
            _ = try await delayed.value
        } catch {
            await release.open()
            delayed.cancel()
            throw error
        }

        XCTAssertEqual(refreshCount.value, 1)
        XCTAssertEqual(try secrets.tokens(for: accountID)?.accessToken, "A1")
        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "R1")
    }

    func testUnauthorizedRequestUsesNewerStoredSessionWithoutRefresh() async throws {
        let accountID = UUID(), deviceID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "A0", accessExpiresAt: .distantFuture, refreshToken: "R0", refreshExpiresAt: .distantFuture), for: accountID)
        let refreshCount = LockedCounter(), requestCount = LockedCounter()
        let session = accountTestSession { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                refreshCount.increment()
                return (500, AccountAPIErrorResponse(error: "unexpected refresh", retryAt: nil))
            }
            requestCount.increment()
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer A0" {
                try secrets.save(AccountTokens(accessToken: "A1", accessExpiresAt: .distantFuture, refreshToken: "R1", refreshExpiresAt: .distantFuture), for: accountID)
                return (401, AccountAPIErrorResponse(error: "stale access", retryAt: nil))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A1")
            return (200, AccountMeResponse(accountID: accountID, phoneNumber: "+380501234567", deviceID: deviceID, platform: "iOS"))
        }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID)

        _ = try await client.me(accountID: accountID)

        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(refreshCount.value, 0)
        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "R1")
    }

    func testNewerExpiredSessionRefreshesCurrentRefreshToken() async throws {
        let accountID = UUID(), deviceID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "A0", accessExpiresAt: .distantPast, refreshToken: "R0", refreshExpiresAt: .distantFuture), for: accountID)
        let refreshCount = LockedCounter()
        let entered = AsyncLatch(), release = AsyncLatch()
        let session = accountTestSession { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                let body = try JSONDecoder.account.decode(AccountRefreshRequest.self, from: try XCTUnwrap(request.httpBody))
                XCTAssertEqual(body.refreshToken, "R1")
                refreshCount.increment()
                return (200, self.accountResponse(accountID: accountID, phone: "+380501234567", access: "A2", refresh: "R2"))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer A2")
            return (200, AccountMeResponse(accountID: accountID, phoneNumber: "+380501234567", deviceID: deviceID, platform: "iOS"))
        }
        let client = AccountAPIClient(
            config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID,
            beforeRefresh: { _, _ in await entered.open(); await release.wait() }
        )

        let operation = Task { try await client.me(accountID: accountID) }
        await entered.wait()
        try secrets.save(AccountTokens(accessToken: "A1", accessExpiresAt: .distantPast, refreshToken: "R1", refreshExpiresAt: .distantFuture), for: accountID)
        await release.open()
        _ = try await operation.value

        XCTAssertEqual(refreshCount.value, 1)
        XCTAssertEqual(try secrets.tokens(for: accountID)?.accessToken, "A2")
        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "R2")
    }

    func testRepeatedUnauthorizedRecoveryIsBounded() async throws {
        let accountID = UUID(), deviceID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "A0", accessExpiresAt: .distantFuture, refreshToken: "R0", refreshExpiresAt: .distantFuture), for: accountID)
        let refreshCount = LockedCounter(), requestCount = LockedCounter()
        let session = accountTestSession { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                let body = try JSONDecoder.account.decode(AccountRefreshRequest.self, from: try XCTUnwrap(request.httpBody))
                refreshCount.increment()
                switch body.refreshToken {
                case "R0": return (200, self.accountResponse(accountID: accountID, phone: "+380501234567", access: "A1", refresh: "R1"))
                case "R1": return (200, self.accountResponse(accountID: accountID, phone: "+380501234567", access: "A2", refresh: "R2"))
                default: return (500, AccountAPIErrorResponse(error: "refresh storm", retryAt: nil))
                }
            }
            requestCount.increment()
            return (401, AccountAPIErrorResponse(error: "unauthorized", retryAt: nil))
        }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID)

        do {
            _ = try await client.me(accountID: accountID)
            XCTFail("repeated unauthorized requests succeeded")
        } catch AccountAPIError.status(401, _) { }

        XCTAssertEqual(requestCount.value, 3)
        XCTAssertEqual(refreshCount.value, 2)
        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "R2")
    }

    func testConditionalRefreshDeletionCannotDeleteNewerTokens() throws {
        let accountID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "A0", accessExpiresAt: .distantPast, refreshToken: "R0", refreshExpiresAt: .distantFuture), for: accountID)
        try secrets.save(AccountTokens(accessToken: "A1", accessExpiresAt: .distantFuture, refreshToken: "R1", refreshExpiresAt: .distantFuture), for: accountID)

        XCTAssertFalse(try secrets.deleteIfRefreshTokenMatches(accountID: accountID, refreshToken: "R0"))
        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "R1")
        XCTAssertTrue(try secrets.deleteIfRefreshTokenMatches(accountID: accountID, refreshToken: "R1"))
        XCTAssertNil(try secrets.tokens(for: accountID))
    }

    func testDifferentAccountsRefreshIndependently() async throws {
        let firstID = UUID(), secondID = UUID(), deviceID = UUID()
        let gate = RefreshConcurrencyGate()
        let firstTokens = AccountTokens(accessToken: "A-first", accessExpiresAt: .distantFuture, refreshToken: "R1-first", refreshExpiresAt: .distantFuture)
        let secondTokens = AccountTokens(accessToken: "A-second", accessExpiresAt: .distantFuture, refreshToken: "R1-second", refreshExpiresAt: .distantFuture)

        async let one = AccountRefreshCoordinator.shared.refresh(
            key: .init(accountID: firstID, deviceID: deviceID)
        ) { await gate.arrive(firstID); return firstTokens }
        async let two = AccountRefreshCoordinator.shared.refresh(
            key: .init(accountID: secondID, deviceID: deviceID)
        ) { await gate.arrive(secondID); return secondTokens }
        let results = try await (one, two)
        let arrivalCount = await gate.arrivalCount

        XCTAssertEqual(results.0, firstTokens)
        XCTAssertEqual(results.1, secondTokens)
        XCTAssertEqual(arrivalCount, 2)
    }

    func testTransientRefreshFailurePreservesAttemptedToken() async throws {
        let accountID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "expired", accessExpiresAt: .distantPast, refreshToken: "transient-refresh", refreshExpiresAt: .distantFuture), for: accountID)
        let session = accountTestSession { _ in throw URLError(.notConnectedToInternet) }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session)

        do { _ = try await client.me(accountID: accountID); XCTFail("transient refresh succeeded") } catch { }

        XCTAssertEqual(try secrets.tokens(for: accountID)?.refreshToken, "transient-refresh")
    }

    func testDefinitiveRefreshRejectionDeletesOnlyCurrentAttemptedToken() async throws {
        let rejectedID = UUID(), otherID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "expired", accessExpiresAt: .distantPast, refreshToken: "rejected-current", refreshExpiresAt: .distantFuture), for: rejectedID)
        try secrets.save(AccountTokens(accessToken: "other", accessExpiresAt: .distantFuture, refreshToken: "other-refresh", refreshExpiresAt: .distantFuture), for: otherID)
        let session = accountTestSession { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/auth/refresh"))
            return (401, AccountAPIErrorResponse(error: "unauthorized", retryAt: nil))
        }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session)

        do { _ = try await client.me(accountID: rejectedID); XCTFail("invalid refresh succeeded") } catch { }

        XCTAssertNil(try secrets.tokens(for: rejectedID))
        XCTAssertEqual(try secrets.tokens(for: otherID)?.refreshToken, "other-refresh")
    }

    func testPreferredCallWithMissingTokensReportsAccountSessionInvalid() async throws {
        let accountID = UUID(), secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MissingPreferredSession.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        try store.add(accountResponse(accountID: accountID, phone: "+380501234567"))
        try secrets.delete(accountID: accountID)
        let requests = LockedCounter()
        let accountSession = accountTestSession { _ in requests.increment(); return (500, AccountAPIErrorResponse(error: "unexpected", retryAt: nil)) }
        let runtime = NotificationRuntime(config: accountConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: accountSession), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); runtime.configureCallKitFactory { adapter }

        await runtime.startPreferredCall(targetPlatform: "watchOS")

        switch runtime.callSession.state {
        case .failed(_, let failure): XCTAssertEqual(failure, .accountSessionInvalid)
        default: XCTFail("unexpected state \(runtime.callSession.state)")
        }
        XCTAssertEqual(requests.value, 0)
        XCTAssertTrue(adapter.startedIDs.isEmpty)
    }

    func testIncomingKnownAccountWithoutTokensFailsClosedAndRecordsDiagnostic() async throws {
        let accountID = UUID(), callID = UUID(), secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MissingIncomingSession.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        try store.add(accountResponse(accountID: accountID, phone: "+380501234567"))
        try secrets.delete(accountID: accountID)
        let capture = RequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallSessionURLProtocol.self]
        CallSessionURLProtocol.capture = capture
        let api = APIClient(config: accountConfig(), session: URLSession(configuration: configuration))
        let accountRequests = LockedCounter()
        let accountSession = accountTestSession { _ in accountRequests.increment(); return (500, AccountAPIErrorResponse(error: "unexpected", retryAt: nil)) }
        let runtime = NotificationRuntime(config: accountConfig(), api: api, accountStore: store, accountAPI: AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: accountSession), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); runtime.configureCallKitFactory { adapter }

        await runtime.handleIncomingVoIP(callID: callID, accountID: accountID)
        for _ in 0..<100 where !capture.diagnosticEvents.contains("account_session_invalid") { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertTrue(adapter.incomingIDs.isEmpty)
        XCTAssertEqual(accountRequests.value, 0)
        XCTAssertTrue(capture.diagnosticEvents.contains("account_session_invalid"))
    }

    func testOrphanedWatchAccountCanRelinkSameAccountWithoutSMS() throws {
        let accountID = UUID(), secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WatchRelinkRecovery.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        try store.add(accountResponse(accountID: accountID, phone: "+380••••4567", access: "old-access", refresh: "old-refresh"))
        try secrets.delete(accountID: accountID)

        XCTAssertTrue(try store.removeOrphanedLocalAccount(accountID: accountID))
        XCTAssertFalse(store.accounts.contains(where: { $0.accountID == accountID }))
        let replacement = AccountTokens(accessToken: "new-access", accessExpiresAt: .distantFuture, refreshToken: "new-refresh", refreshExpiresAt: .distantFuture)
        try store.addLinkedAccount(accountID: accountID, phoneNumber: "+380••••4567", tokens: replacement)

        XCTAssertEqual(store.activeAccountID, accountID)
        XCTAssertEqual(store.activeAccount?.accountID, accountID)
        XCTAssertEqual(try secrets.tokens(for: accountID), replacement)
    }

    func testAccountPushCoordinatorRegistersEveryAccountAndInvalidatesIndependently() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AccountPushCoordinator.\(UUID())"))
        let secrets = InMemorySecureTokenStore()
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        let first = accountResponse(phone: "+380501234567", access: "access-one", refresh: "refresh-one")
        let second = accountResponse(phone: "+14155550123", access: "access-two", refresh: "refresh-two")
        let third = accountResponse(phone: "+442071838750", access: "access-three", refresh: "refresh-three")
        try store.add(first)
        try store.add(second)
        try store.add(third)
        let requests = LockedRequests()
        let session = accountTestSession { request in
            requests.append(request)
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-one", body.contains("\"token\":\"\"") {
                return (500, AccountAPIErrorResponse(error: "temporary", retryAt: nil))
            }
            return (204, AccountAPIErrorResponse(error: "", retryAt: nil))
        }
        let deviceID = UUID()
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session, deviceID: deviceID)
        let coordinator = AccountPushRegistrationCoordinator(store: store, client: client, platform: "iOS", generation: 7)
        let caps = DeviceCapabilities(voipPush: true, alertPush: true, notificationsAuthorized: true, microphoneReady: true)

        await coordinator.update(token: Data([0xaa, 0xbb]), pushType: .alert, capabilities: caps)
        XCTAssertEqual(requests.values.count, 3)
        XCTAssertEqual(Set(requests.values.compactMap { $0.value(forHTTPHeaderField: "Authorization") }), ["Bearer access-one", "Bearer access-two", "Bearer access-three"])
        for request in requests.values {
            let body = try JSONDecoder.account.decode(AccountDeviceRegistrationRequest.self, from: try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.deviceID, deviceID)
            XCTAssertEqual(body.pushType, .alert)
            XCTAssertEqual(body.token, "aabb")
            XCTAssertEqual(body.installationGeneration, 7)
        }

        store.switchAccount(to: first.account.accountID)
        await coordinator.update(token: Data([0xcc, 0xdd]), pushType: .voip, capabilities: caps)
        XCTAssertEqual(requests.values.count, 6)

        let linked = accountResponse(phone: "+14155559876", access: "access-watch", refresh: "refresh-watch")
        try store.addLinkedAccount(accountID: linked.account.accountID, phoneNumber: linked.account.phoneNumber, tokens: linked.tokens)
        await coordinator.registerKnownTokens(for: linked.account.accountID)
        XCTAssertEqual(requests.values.count, 8)

        await coordinator.invalidate(pushType: .voip, expectedToken: Data([0xcc, 0xdd]))
        XCTAssertEqual(requests.values.count, 12)
        let invalidations = try requests.values.suffix(4).map { try JSONDecoder.account.decode(AccountDeviceRegistrationRequest.self, from: XCTUnwrap($0.httpBody)) }
        XCTAssertTrue(invalidations.allSatisfy { $0.token.isEmpty && $0.invalidatedToken == "ccdd" })
    }

    func testWatchLinkPendingExpiredAndSuccessStorage() async throws {
        let accountID = UUID(), secrets = InMemorySecureTokenStore(), counter = LockedCounter()
        let session = accountTestSession { request in
            counter.increment()
            switch counter.value {
            case 1: return (200, WatchLinkStatusResponse(status: "pending", accountID: nil, phoneNumber: nil, accessToken: nil, accessExpiresAt: nil, refreshToken: nil, refreshExpiresAt: nil))
            case 2: return (200, WatchLinkStatusResponse(status: "expired", accountID: nil, phoneNumber: nil, accessToken: nil, accessExpiresAt: nil, refreshToken: nil, refreshExpiresAt: nil))
            case 3: return (200, WatchLinkStatusResponse(status: "claimed", accountID: accountID, phoneNumber: "+380••••4567", accessToken: "watch-access", accessExpiresAt: .distantFuture, refreshToken: "watch-refresh", refreshExpiresAt: .distantFuture))
            default: return (409, AccountAPIErrorResponse(error: "link session already retrieved", retryAt: nil))
            }
        }
        let client = AccountAPIClient(config: accountConfig(), tokenStore: secrets, session: session)
        let linkID = UUID(), secret = "link-secret"
        let pending = try await client.watchLinkStatus(linkID: linkID, secret: secret)
        XCTAssertEqual(pending.status, "pending")
        let expired = try await client.watchLinkStatus(linkID: linkID, secret: secret)
        XCTAssertEqual(expired.status, "expired")
        let claimed = try await client.watchLinkStatus(linkID: linkID, secret: secret)
        let store = AccountSessionStore(tokenStore: secrets, defaults: try XCTUnwrap(UserDefaults(suiteName: "WatchLink.\(UUID())")))
        try store.addLinkedAccount(accountID: try XCTUnwrap(claimed.accountID), phoneNumber: try XCTUnwrap(claimed.phoneNumber), tokens: AccountTokens(accessToken: try XCTUnwrap(claimed.accessToken), accessExpiresAt: try XCTUnwrap(claimed.accessExpiresAt), refreshToken: try XCTUnwrap(claimed.refreshToken), refreshExpiresAt: try XCTUnwrap(claimed.refreshExpiresAt)))
        XCTAssertEqual(try secrets.tokens(for: accountID)?.accessToken, "watch-access")
        do { _ = try await client.watchLinkStatus(linkID: linkID, secret: secret); XCTFail("session retrieved twice") } catch AccountAPIError.status(409, _) { }
    }

    private func accountResponse(accountID: UUID = UUID(), phone: String, access: String = UUID().uuidString, refresh: String = UUID().uuidString) -> AccountSessionResponse {
        AccountSessionResponse(account: AccountSummary(accountID: accountID, phoneNumber: phone), deviceID: InstallationIdentity.shared.id, accessToken: access, accessExpiresAt: .distantFuture, refreshToken: refresh, refreshExpiresAt: .distantFuture)
    }
    private func accountConfig() -> AppConfig { AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)) }
    private func defaultsSuite(_ defaults: UserDefaults) -> String { defaults.dictionaryRepresentation()["suiteName"] as? String ?? "" }

    private func accountTestSession(handler: @escaping (URLRequest) throws -> (Int, Encodable)) -> URLSession {
        AccountURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class AccountCallFoundationTests: XCTestCase {
    func testMediaPeerIdentityKeepsLegacyAndAccountQueriesSeparate() {
        XCTAssertEqual(MediaPeerIdentity.legacy(.A).queryName, "role")
        XCTAssertEqual(MediaPeerIdentity.legacy(.B).queryValue, "B")
        XCTAssertEqual(MediaPeerIdentity.account(.caller).queryName, "side")
        XCTAssertEqual(MediaPeerIdentity.account(.caller).queryValue, "caller")
        XCTAssertEqual(MediaPeerIdentity.account(.callee).queryValue, "callee")
    }

    func testLegacyAndAccountIncomingEnvelopesAreStrict() {
        let callID = UUID(), accountID = UUID()
        XCTAssertEqual(IncomingNotificationEnvelope.parse(["event": "incoming_call", "serverCallID": callID.uuidString]), .legacy(callID: callID))
        XCTAssertEqual(IncomingNotificationEnvelope.parse(["event": "incoming_call_v2", "serverCallID": callID.uuidString, "accountID": accountID.uuidString]), .account(callID: callID, accountID: accountID))
        XCTAssertNil(IncomingNotificationEnvelope.parse(["event": "incoming_call_v2", "serverCallID": callID.uuidString]))
        XCTAssertNil(IncomingNotificationEnvelope.parse(["event": "incoming_call_v2", "serverCallID": "invalid", "accountID": accountID.uuidString]))
        XCTAssertNil(IncomingNotificationEnvelope.parse(["event": "incoming_call_unknown", "serverCallID": callID.uuidString]))
    }

    func testAccountAPIUsesAuthenticatedV2DeviceAndCallRoutes() async throws {
        let accountID = UUID(), deviceID = UUID(), targetID = UUID(), callID = UUID()
        let secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "account-access", accessExpiresAt: .distantFuture, refreshToken: "refresh", refreshExpiresAt: .distantFuture), for: accountID)
        let requests = LockedRequests()
        let session = accountCallTestSession { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-access")
            if request.url!.path.hasSuffix("/devices") {
                return (200, [AccountDeviceSummary(deviceID: targetID, platform: "watchOS", callReady: true, lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000))])
            }
            let state: ServerCallState = request.url!.path.hasSuffix("/accept") ? .accepted : .ringing
            return (200, self.accountCallResponse(callID: callID, side: .caller, state: state))
        }
        let client = AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session, deviceID: deviceID)
        let devices = try await client.devices(accountID: accountID)
        XCTAssertEqual(devices.map(\.deviceID), [targetID])
        _ = try await client.createCall(accountID: accountID, callID: callID, requestID: UUID(), targetDeviceID: targetID)
        _ = try await client.call(accountID: accountID, callID: callID)
        _ = try await client.mutateCall(accountID: accountID, action: .accept, callID: callID, requestID: UUID())
        XCTAssertTrue(requests.values.contains { $0.url?.path.hasSuffix("/v2/calls") == true })
        XCTAssertTrue(requests.values.contains { $0.url?.path.hasSuffix("/v2/calls/\(callID.uuidString.lowercased())") == true && $0.httpMethod == "GET" })
        XCTAssertTrue(requests.values.contains { $0.url?.path.hasSuffix("/accept") == true })
        let create = try XCTUnwrap(requests.values.first { $0.url?.path.hasSuffix("/v2/calls") == true })
        let body = try JSONDecoder.account.decode(AccountCallCreateRequest.self, from: try XCTUnwrap(create.httpBody))
        XCTAssertEqual(body.targetDeviceID, targetID)
    }

    func testLegacySignalingMapsRoleBAsCallerAndCallee() async throws {
        let callID = UUID(), capture = RequestCapture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallSessionURLProtocol.self]
        CallSessionURLProtocol.capture = capture
        capture.clientRole = .B
        let legacyConfig = AppConfig(apiBaseURL: URL(string: "https://example.invalid/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64))
        let api = APIClient(config: legacyConfig, session: URLSession(configuration: configuration))
        let signaling = LegacyCallSignaling(api: api, role: .B)
        let caller = try await signaling.create(callID: callID, requestID: UUID())
        XCTAssertEqual(caller.localSide, .caller)
        XCTAssertEqual(signaling.mediaPeerIdentity, .legacy(.B))

        let incomingID = UUID()
        let callee = try await signaling.call(incomingID)
        XCTAssertEqual(callee.localSide, .callee)
    }

    func testAccountSignalingEnforcesExpectedLocalSideAndMediaSide() async throws {
        let accountID = UUID(), targetID = UUID(), callID = UUID(), secrets = InMemorySecureTokenStore()
        try secrets.save(AccountTokens(accessToken: "access", accessExpiresAt: .distantFuture, refreshToken: "refresh", refreshExpiresAt: .distantFuture), for: accountID)
        let session = accountCallTestSession { request in
            let side: CallPartySide = request.httpMethod == "POST" && request.url!.path.hasSuffix("/calls") ? .caller : .callee
            return (200, self.accountCallResponse(callID: callID, side: side, state: .ringing))
        }
        let client = AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session)
        let caller = AccountCallSignaling(client: client, accountID: accountID, targetDeviceID: targetID, localSide: .caller)
        let callerView = try await caller.create(callID: callID, requestID: UUID())
        XCTAssertEqual(callerView.localSide, .caller)
        XCTAssertEqual(caller.mediaPeerIdentity, .account(.caller))
        let callee = AccountCallSignaling(client: client, accountID: accountID, localSide: .callee)
        let calleeView = try await callee.call(callID)
        XCTAssertEqual(calleeView.localSide, .callee)
        XCTAssertEqual(callee.mediaPeerIdentity, .account(.callee))
    }

    func testPreferredCallWithActiveAccountDoesNotFallBackWhenTargetMissingOrAmbiguous() async throws {
        for devices in [
            [AccountDeviceSummary](),
            [AccountDeviceSummary(deviceID: UUID(), platform: "watchOS", callReady: true, lastSeenAt: Date()), AccountDeviceSummary(deviceID: UUID(), platform: "watchOS", callReady: true, lastSeenAt: Date())]
        ] {
            let accountID = UUID(), secrets = InMemorySecureTokenStore()
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "PreferredAccountCall.\(UUID())"))
            let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
            try store.add(accountSession(accountID: accountID))
            let session = accountCallTestSession { request in
                XCTAssertTrue(request.url!.path.hasSuffix("/v2/devices"))
                return (200, devices)
            }
            let runtime = NotificationRuntime(config: accountCallConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session), audio: AudioEngineMock(), media: MediaTransportMock())
            let adapter = RetainedCallKitMock()
            runtime.configureCallKitFactory { adapter }
            await runtime.startPreferredCall(targetPlatform: "watchOS")
            XCTAssertTrue(adapter.startedIDs.isEmpty)
            switch runtime.callSession.state {
            case .failed(_, let failure): XCTAssertEqual(failure, devices.isEmpty ? .targetUnavailable : .targetAmbiguous)
            default: XCTFail("unexpected state \(runtime.callSession.state)")
            }
        }
    }

    func testPreferredCallSelectsOnlyReadyTargetAndCreatesV2Call() async throws {
        let accountID = UUID(), targetID = UUID(), callIDBox = LockedUUID(), mutationCount = LockedCounter(), secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PreferredAccountCall.One.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        try store.add(accountSession(accountID: accountID))
        let session = accountCallTestSession { request in
            if request.url!.path.hasSuffix("/devices") {
                return (200, [
                    AccountDeviceSummary(deviceID: targetID, platform: "watchOS", callReady: true, lastSeenAt: Date()),
                    AccountDeviceSummary(deviceID: UUID(), platform: "watchOS", callReady: false, lastSeenAt: Date()),
                    AccountDeviceSummary(deviceID: UUID(), platform: "iOS", callReady: true, lastSeenAt: Date())
                ])
            }
            if request.url!.path.hasSuffix("/calls") {
                let body = try JSONDecoder.account.decode(AccountCallCreateRequest.self, from: try XCTUnwrap(request.httpBody))
                XCTAssertEqual(body.targetDeviceID, targetID)
                callIDBox.set(body.callID)
                return (200, self.accountCallResponse(callID: body.callID, side: .caller, state: .ringing))
            }
            let callID = try XCTUnwrap(callIDBox.value)
            if request.url!.path.hasSuffix("/cancel") { mutationCount.increment() }
            return (200, self.accountCallResponse(callID: callID, side: .caller, state: request.url!.path.hasSuffix("/cancel") ? .cancelled : .ringing))
        }
        let runtime = NotificationRuntime(config: accountCallConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }
        await runtime.startPreferredCall(targetPlatform: "watchOS")
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)
        for _ in 0..<100 where callIDBox.value == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(callIDBox.value)
        _ = try await adapter.approveEnd(localID)
        for _ in 0..<100 where !runtime.callSession.state.isTerminal || mutationCount.value == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(runtime.callSession.state.isTerminal)
        XCTAssertEqual(mutationCount.value, 1)
    }

    func testExplicitOutgoingUsesSelectedAccountWithoutChangingActiveAccount() async throws {
        let activeID = UUID(), secondID = UUID(), selectedID = UUID(), targetID = UUID()
        let secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ExplicitOutgoingAccount.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        try store.add(accountSession(accountID: activeID))
        try store.add(accountSession(accountID: secondID))
        try store.add(accountSession(accountID: selectedID))
        store.switchAccount(to: activeID)
        let requests = LockedRequests()
        let callIDBox = LockedUUID()
        let session = accountCallTestSession { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-\(selectedID)")
            if request.url!.path.hasSuffix("/devices") {
                return (200, [AccountDeviceSummary(deviceID: targetID, platform: "watchOS", callReady: true, lastSeenAt: Date())])
            }
            if request.httpMethod == "POST", request.url!.path.hasSuffix("/calls") {
                let body = try JSONDecoder.account.decode(AccountCallCreateRequest.self, from: try XCTUnwrap(request.httpBody))
                XCTAssertEqual(body.targetDeviceID, targetID)
                callIDBox.set(body.callID)
                return (200, self.accountCallResponse(callID: body.callID, side: .caller, state: .ringing))
            }
            return (200, self.accountCallResponse(callID: try XCTUnwrap(callIDBox.value), side: .caller, state: .ringing))
        }
        let runtime = NotificationRuntime(config: accountCallConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }

        await runtime.startPreferredCall(targetPlatform: "watchOS", accountID: selectedID)

        XCTAssertEqual(store.activeAccountID, activeID)
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)
        await eventually { requests.values.contains { $0.url?.path.hasSuffix("/calls") == true } }
        XCTAssertTrue(requests.values.contains { $0.url?.path.hasSuffix("/calls") == true })
        XCTAssertEqual(store.activeAccountID, activeID)
    }

    func testExplicitOutgoingMissingAccountFailsWithoutNetworkOrCallKit() async throws {
        let secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ExplicitOutgoingMissing.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        let requests = LockedCounter()
        let session = accountCallTestSession { _ in
            requests.increment()
            return (500, AccountAPIErrorResponse(error: "unexpected", retryAt: nil))
        }
        let runtime = NotificationRuntime(config: accountCallConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }

        await runtime.startPreferredCall(targetPlatform: "watchOS", accountID: UUID())

        XCTAssertEqual(requests.value, 0)
        XCTAssertTrue(adapter.startedIDs.isEmpty)
        switch runtime.callSession.state {
        case .failed(_, let failure): XCTAssertEqual(failure, .accountSessionInvalid)
        default: XCTFail("unexpected state \(runtime.callSession.state)")
        }
    }

    func testIncomingUsesRequestedAccountWhenDifferentAccountIsActive() async throws {
        let activeID = UUID(), incomingID = UUID(), callID = UUID()
        let secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "IncomingSelectedAccount.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        try store.add(accountSession(accountID: activeID))
        try store.add(accountSession(accountID: incomingID))
        store.switchAccount(to: activeID)
        let requests = LockedRequests()
        let session = accountCallTestSession { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-\(incomingID)")
            return (200, self.accountCallResponse(callID: callID, side: .callee, state: .ringing))
        }
        let runtime = NotificationRuntime(config: accountCallConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }

        await runtime.handleIncomingVoIP(callID: callID, accountID: incomingID)
        await eventually { !requests.values.isEmpty }

        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertFalse(requests.values.isEmpty)
        XCTAssertEqual(store.activeAccountID, activeID)
    }

    func testIncomingV2MissingAccountIgnoredAndSignedInAccountUsesSameProvider() async throws {
        let accountID = UUID(), callID = UUID(), secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "IncomingAccountCall.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        let requestCount = LockedCounter()
        let session = accountCallTestSession { request in
            requestCount.increment()
            return (200, self.accountCallResponse(callID: callID, side: .callee, state: request.url!.path.hasSuffix("/reject") ? .rejected : .ringing))
        }
        let runtime = NotificationRuntime(config: accountCallConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }
        await runtime.handleIncomingVoIP(callID: callID, accountID: accountID)
        XCTAssertTrue(adapter.incomingIDs.isEmpty)
        try store.add(accountSession(accountID: accountID))
        await runtime.handleIncomingVoIP(callID: callID, accountID: accountID)
        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertEqual(runtime.callKitCreationCount, 1)
        XCTAssertEqual(runtime.callSession.state.callID, callID)
        for _ in 0..<100 where requestCount.value == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        _ = try await adapter.approveEnd(try XCTUnwrap(adapter.incomingIDs.first))
        for _ in 0..<100 where !runtime.callSession.state.isTerminal || requestCount.value < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(runtime.callSession.state.isTerminal)
        XCTAssertGreaterThanOrEqual(requestCount.value, 2)
    }

    func testWatchBackgroundV2IncomingUsesSameCallSessionAndProvider() async throws {
        let accountID = UUID(), callID = UUID(), secrets = InMemorySecureTokenStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BackgroundAccountCall.\(UUID())"))
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        try store.add(accountSession(accountID: accountID))
        let requestCount = LockedCounter()
        let session = accountCallTestSession { request in
            requestCount.increment()
            return (200, self.accountCallResponse(callID: callID, side: .callee, state: request.url!.path.hasSuffix("/reject") ? .rejected : .ringing))
        }
        let runtime = NotificationRuntime(config: accountCallConfig(), accountStore: store, accountAPI: AccountAPIClient(config: accountCallConfig(), tokenStore: secrets, session: session), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock()
        runtime.configureCallKitFactory { adapter }

        let firstHandled = await runtime.handleIncomingBackgroundNotification(callID: callID, accountID: accountID)
        XCTAssertTrue(firstHandled)
        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertEqual(runtime.callKitCreationCount, 1)
        XCTAssertEqual(runtime.callSession.state.callID, callID)
        let duplicateHandled = await runtime.handleIncomingBackgroundNotification(callID: callID, accountID: accountID)
        XCTAssertTrue(duplicateHandled)
        XCTAssertEqual(adapter.incomingIDs.count, 1)
        XCTAssertEqual(runtime.callKitCreationCount, 1)
        for _ in 0..<100 where requestCount.value == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        _ = try await adapter.approveEnd(try XCTUnwrap(adapter.incomingIDs.first))
        for _ in 0..<100 where !runtime.callSession.state.isTerminal || requestCount.value < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(runtime.callSession.state.isTerminal)
        XCTAssertGreaterThanOrEqual(requestCount.value, 2)
    }

    func testStaleV2CreateCompensatesThroughOriginalSignaling() async throws {
        let original = ControlledCallSignaling(accountID: UUID(), localSide: .caller, holdCreate: true)
        let replacement = ControlledCallSignaling(accountID: UUID(), localSide: .caller)
        let session = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)

        await session.startCall(signaling: original)
        let oldCallID = try XCTUnwrap(session.state.callID)
        let oldLocalID = try XCTUnwrap(adapter.startedIDs.first)
        let start = Task { try await adapter.approveStart(oldLocalID) }
        await eventually { original.createPending }
        adapter.onActionFailed?(oldLocalID, "start", NSError(domain: "generation-invalidated", code: 1))
        await eventually { session.state.isTerminal }
        session.reset()
        await session.startCall(signaling: replacement)

        original.resumeCreate()
        _ = try? await start.value
        await eventually { original.contains(.cancel, callID: oldCallID) }

        XCTAssertTrue(original.contains(.cancel, callID: oldCallID))
        XCTAssertFalse(replacement.containsAnyMutation(callID: oldCallID))
    }

    func testStaleV2AcceptCompensatesThroughOriginalSignaling() async throws {
        let original = ControlledCallSignaling(accountID: UUID(), localSide: .callee, holdAccept: true)
        let replacement = ControlledCallSignaling(accountID: UUID(), localSide: .caller)
        let session = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        let oldCallID = UUID()

        await session.handleIncomingVoIP(callID: oldCallID, signaling: original)
        let oldLocalID = try XCTUnwrap(adapter.incomingIDs.first)
        let answer = Task { try await adapter.approveAnswer(oldLocalID) }
        await eventually { original.acceptPending }
        adapter.onActionFailed?(oldLocalID, "answer", NSError(domain: "generation-invalidated", code: 2))
        await eventually { session.state.isTerminal }
        session.reset()
        await session.startCall(signaling: replacement)

        original.resumeAccept()
        _ = try? await answer.value
        await eventually { original.contains(.end, callID: oldCallID) }

        XCTAssertTrue(original.contains(.end, callID: oldCallID))
        XCTAssertFalse(replacement.containsAnyMutation(callID: oldCallID))
    }

    func testProviderResetRingingV2RetainsCancelAndRejectBackends() async throws {
        let signaling = ControlledCallSignaling(accountID: UUID(), localSide: .caller)
        let session = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall(signaling: signaling)
        let callID = try XCTUnwrap(session.state.callID)
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)

        adapter.onProviderReset?(localID)
        await eventually { signaling.contains(.cancel, callID: callID) }

        XCTAssertTrue(signaling.contains(.cancel, callID: callID))
        XCTAssertTrue(session.state.isTerminal)

        let incomingSignaling = ControlledCallSignaling(accountID: UUID(), localSide: .callee)
        let incomingSession = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let incomingAdapter = RetainedCallKitMock(); incomingSession.attach(callKit: incomingAdapter)
        let incomingCallID = UUID()
        await incomingSession.handleIncomingVoIP(callID: incomingCallID, signaling: incomingSignaling)
        let incomingLocalID = try XCTUnwrap(incomingAdapter.incomingIDs.first)
        incomingAdapter.onProviderReset?(incomingLocalID)
        await eventually { incomingSignaling.contains(.reject, callID: incomingCallID) }

        XCTAssertTrue(incomingSignaling.contains(.reject, callID: incomingCallID))
        XCTAssertTrue(incomingSession.state.isTerminal)
    }

    func testProviderResetAcceptedV2RetainsEndBackend() async throws {
        let signaling = ControlledCallSignaling(accountID: UUID(), localSide: .callee)
        let session = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        let callID = UUID()
        await session.handleIncomingVoIP(callID: callID, signaling: signaling)
        let localID = try XCTUnwrap(adapter.incomingIDs.first)
        try await adapter.approveAnswer(localID)
        guard case .connecting = session.state else { return XCTFail("expected connecting") }

        adapter.onProviderReset?(localID)
        await eventually { signaling.contains(.end, callID: callID) }

        XCTAssertTrue(signaling.contains(.end, callID: callID))
        XCTAssertTrue(session.state.isTerminal)
    }

    func testProviderResetTerminalDeliverySurvivesGenerationTeardownCancellation() async throws {
        let cancelSignaling = ControlledCallSignaling(accountID: UUID(), localSide: .caller)
        let unrelated = ControlledCallSignaling(accountID: UUID(), localSide: .caller)
        let outgoing = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let outgoingAdapter = RetainedCallKitMock(); outgoing.attach(callKit: outgoingAdapter)
        await outgoing.startCall(signaling: cancelSignaling)
        let outgoingCallID = try XCTUnwrap(outgoing.state.callID)
        let outgoingLocalID = try XCTUnwrap(outgoingAdapter.startedIDs.first)
        try await outgoingAdapter.approveStart(outgoingLocalID)

        outgoingAdapter.onProviderReset?(outgoingLocalID)
        await eventually { outgoing.state.isTerminal && cancelSignaling.mutationCount(.cancel, callID: outgoingCallID) == 1 }
        outgoing.reset()
        await outgoing.startCall(signaling: unrelated)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(cancelSignaling.mutationCount(.cancel, callID: outgoingCallID), 1)
        XCTAssertFalse(unrelated.containsAnyMutation(callID: outgoingCallID))

        let endSignaling = ControlledCallSignaling(accountID: UUID(), localSide: .callee)
        let accepted = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let acceptedAdapter = RetainedCallKitMock(); accepted.attach(callKit: acceptedAdapter)
        let acceptedCallID = UUID()
        await accepted.handleIncomingVoIP(callID: acceptedCallID, signaling: endSignaling)
        let acceptedLocalID = try XCTUnwrap(acceptedAdapter.incomingIDs.first)
        try await acceptedAdapter.approveAnswer(acceptedLocalID)

        acceptedAdapter.onProviderReset?(acceptedLocalID)
        await eventually { accepted.state.isTerminal && endSignaling.mutationCount(.end, callID: acceptedCallID) == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(endSignaling.mutationCount(.end, callID: acceptedCallID), 1)
        XCTAssertTrue(accepted.state.isTerminal)
    }

    func testLegacyProviderResetOutgoingRingingStillCancels() async throws {
        let capture = RequestCapture()
        let config = accountCallConfig()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallSessionURLProtocol.self]
        CallSessionURLProtocol.capture = capture
        capture.clientRole = config.role
        let api = APIClient(config: config, session: URLSession(configuration: configuration))
        let session = CallSession(config: config, api: api, audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall()
        let callID = try XCTUnwrap(session.state.callID)
        let localID = try XCTUnwrap(adapter.startedIDs.first)
        try await adapter.approveStart(localID)

        adapter.onProviderReset?(localID)
        await eventually { capture.paths.contains { $0.hasSuffix("/calls/\(callID.uuidString.lowercased())/cancel") } }

        XCTAssertTrue(capture.paths.contains { $0.hasSuffix("/calls/\(callID.uuidString.lowercased())/cancel") })
        XCTAssertTrue(session.state.isTerminal)
    }

    func testStaleCompensationCannotCrossGenerationBackends() async throws {
        let backendA = ControlledCallSignaling(accountID: UUID(), localSide: .caller, holdCreate: true)
        let backendB = ControlledCallSignaling(accountID: UUID(), localSide: .caller)
        let session = CallSession(config: accountCallConfig(), audio: AudioEngineMock(), media: MediaTransportMock())
        let adapter = RetainedCallKitMock(); session.attach(callKit: adapter)
        await session.startCall(signaling: backendA)
        let callA = try XCTUnwrap(session.state.callID)
        let localA = try XCTUnwrap(adapter.startedIDs.first)
        let startA = Task { try await adapter.approveStart(localA) }
        await eventually { backendA.createPending }
        adapter.onActionFailed?(localA, "start", NSError(domain: "replace-generation", code: 3))
        await eventually { session.state.isTerminal }
        session.reset()
        await session.startCall(signaling: backendB)
        let callB = try XCTUnwrap(session.state.callID)

        backendA.resumeCreate()
        _ = try? await startA.value
        await eventually { backendA.contains(.cancel, callID: callA) }

        XCTAssertTrue(backendA.contains(.cancel, callID: callA))
        XCTAssertFalse(backendB.containsAnyMutation(callID: callA))
        XCTAssertFalse(backendA.containsAnyMutation(callID: callB))
    }

    private func accountCallConfig() -> AppConfig {
        AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64))
    }

    private func accountSession(accountID: UUID) -> AccountSessionResponse {
        AccountSessionResponse(account: AccountSummary(accountID: accountID, phoneNumber: "+380501234567"), deviceID: InstallationIdentity.shared.id, accessToken: "access-\(accountID)", accessExpiresAt: .distantFuture, refreshToken: "refresh-\(accountID)", refreshExpiresAt: .distantFuture)
    }

    private func accountCallTestSession(handler: @escaping (URLRequest) throws -> (Int, Encodable)) -> URLSession {
        AccountURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func accountCallResponse(callID: UUID, side: CallPartySide, state: ServerCallState) -> AccountCallResponse {
        AccountCallResponse(callID: callID, localSide: side, state: state, expiresAt: Date(timeIntervalSince1970: 2_000_000_000), mediaToken: state == .accepted ? "media" : nil, ringExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), acceptedAt: state == .accepted ? Date() : nil, terminalAt: nil, terminalReason: nil, deliveryStatus: "submission_accepted", peerReady: state == .accepted, createdNew: true, mutationApplied: nil)
    }

    private func eventually(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<200 where !predicate() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

private final class ControlledCallSignaling: CallSignaling, @unchecked Sendable {
    private struct HeldOperation {
        let callID: UUID
        let continuation: CheckedContinuation<CallSignalView, Error>
    }
    private struct MutationRecord {
        let action: CallMutation
        let callID: UUID
    }

    let accountID: UUID
    let localSide: CallPartySide
    let mediaPeerIdentity: MediaPeerIdentity
    private let holdCreate: Bool
    private let holdAccept: Bool
    private let lock = NSLock()
    private var heldCreate: HeldOperation?
    private var heldAccept: HeldOperation?
    private var mutations: [MutationRecord] = []

    init(accountID: UUID, localSide: CallPartySide, holdCreate: Bool = false, holdAccept: Bool = false) {
        self.accountID = accountID
        self.localSide = localSide
        self.mediaPeerIdentity = .account(localSide)
        self.holdCreate = holdCreate
        self.holdAccept = holdAccept
    }

    var createPending: Bool { lock.withLock { heldCreate != nil } }
    var acceptPending: Bool { lock.withLock { heldAccept != nil } }

    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView {
        if holdCreate {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { heldCreate = HeldOperation(callID: callID, continuation: continuation) }
            }
        }
        return view(callID: callID, state: .ringing, side: .caller)
    }

    func call(_ id: UUID) async throws -> CallSignalView { view(callID: id, state: .ringing, side: localSide) }

    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        lock.withLock { mutations.append(MutationRecord(action: action, callID: callID)) }
        if action == .accept, holdAccept {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { heldAccept = HeldOperation(callID: callID, continuation: continuation) }
            }
        }
        return view(callID: callID, state: state(for: action), side: localSide)
    }

    func resumeCreate() {
        let held = lock.withLock { let value = heldCreate; heldCreate = nil; return value }
        if let held { held.continuation.resume(returning: view(callID: held.callID, state: .ringing, side: .caller)) }
    }

    func resumeAccept() {
        let held = lock.withLock { let value = heldAccept; heldAccept = nil; return value }
        if let held { held.continuation.resume(returning: view(callID: held.callID, state: .accepted, side: localSide)) }
    }

    func contains(_ action: CallMutation, callID: UUID) -> Bool {
        lock.withLock { mutations.contains { $0.action == action && $0.callID == callID } }
    }

    func containsAnyMutation(callID: UUID) -> Bool {
        lock.withLock { mutations.contains { $0.callID == callID } }
    }

    func mutationCount(_ action: CallMutation, callID: UUID) -> Int {
        lock.withLock { mutations.filter { $0.action == action && $0.callID == callID }.count }
    }

    private func state(for action: CallMutation) -> ServerCallState {
        switch action { case .accept: return .accepted; case .reject: return .rejected; case .cancel: return .cancelled; case .end: return .ended }
    }

    private func view(callID: UUID, state: ServerCallState, side: CallPartySide) -> CallSignalView {
        CallSignalView(callID: callID, localSide: side, state: state, expiresAt: Date(timeIntervalSince1970: 2_000_000_000), mediaToken: state == .accepted ? "media-token" : nil, ringExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), acceptedAt: state == .accepted ? Date() : nil, terminalAt: state == .ended || state == .cancelled || state == .rejected ? Date() : nil, terminalReason: nil, deliveryStatus: "test", peerReady: false, createdNew: true, mutationApplied: true)
    }
}

private final class LockedUUID: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UUID?
    var value: UUID? { lock.withLock { storage } }
    func set(_ value: UUID) { lock.withLock { storage = value } }
}

private final class InMemorySecureTokenStore: SecureTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: AccountTokens] = [:]
    func tokens(for accountID: UUID) throws -> AccountTokens? { lock.withLock { values[accountID] } }
    func save(_ tokens: AccountTokens, for accountID: UUID) throws { lock.withLock { values[accountID] = tokens } }
    func delete(accountID: UUID) throws { lock.withLock { values[accountID] = nil } }
    @discardableResult
    func deleteIfRefreshTokenMatches(accountID: UUID, refreshToken: String) throws -> Bool {
        lock.withLock {
            guard values[accountID]?.refreshToken == refreshToken else { return false }
            values[accountID] = nil
            return true
        }
    }
}

private actor RefreshConcurrencyGate {
    private var arrivals: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var arrivalCount: Int { arrivals.count }

    func arrive(_ id: UUID) async {
        arrivals.insert(id)
        if arrivals.count >= 2 {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            if arrivals.count >= 2 { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }
}

private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class AccountURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Encodable))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            var capturedRequest = request
            if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                capturedRequest.httpBody = data
            }
            let (status, body) = try handler(capturedRequest)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status != 204 { client?.urlProtocol(self, didLoad: try JSONEncoder.account.encode(AnyEncodable(body))) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

@MainActor
final class AppleIdentityFoundationTests: XCTestCase {
    func testLegacyAccountSummaryDecodingRemainsCompatible() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["accountID": id.uuidString, "phoneNumber": "+380501234567"])
        let value = try JSONDecoder().decode(AccountSummary.self, from: data)
        XCTAssertEqual(value.accountID, id)
        XCTAssertEqual(value.phoneNumber, "+380501234567")
        XCTAssertEqual(value.displayLabel, "+380501234567")
        XCTAssertNil(value.userID)
    }

    func testZeroPhoneAppleAccountIsValidAndPersistsProfile() throws {
        let suite = "AppleIdentityFoundationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defaults.removePersistentDomain(forName: suite)
        let tokenStore = InMemorySecureTokenStore()
        let store = AccountSessionStore(tokenStore: tokenStore, defaults: defaults)
        let accountID = UUID(), userID = UUID()
        let profile = UserProfile(userID: userID, username: "user-test", displayName: nil, email: nil, verifiedPhones: [], publicIdentity: "wsc:user:user-test")
        let response = AccountSessionResponse(account: AccountSummary(accountID: accountID, userID: userID, phoneNumber: nil, displayLabel: "@user-test"), deviceID: UUID(), accessToken: "access", accessExpiresAt: .distantFuture, refreshToken: "refresh", refreshExpiresAt: .distantFuture, user: profile)
        try store.add(response)
        XCTAssertEqual(store.accounts.first?.displayLabel, "@user-test")
        XCTAssertNil(store.accounts.first?.phoneNumber)
        XCTAssertEqual(store.profiles[accountID], profile)
        XCTAssertNotNil(try tokenStore.tokens(for: accountID))
        let reloaded = AccountSessionStore(tokenStore: tokenStore, defaults: defaults)
        XCTAssertEqual(reloaded.profiles[accountID], profile)
        XCTAssertNotNil(try tokenStore.tokens(for: accountID))
    }

    func testWatchLinkCanDecodeWithoutPhone() throws {
        let accountID = UUID(), userID = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["status":"claimed", "accountID":accountID.uuidString, "userID":userID.uuidString, "displayLabel":"@user-test"])
        let response = try JSONDecoder().decode(WatchLinkStatusResponse.self, from: data)
        XCTAssertEqual(response.accountID, accountID)
        XCTAssertEqual(response.userID, userID)
        XCTAssertNil(response.phoneNumber)
    }
}


@MainActor
final class AppleNonceContractTests: XCTestCase {
    func testRawNonceUsesSecureRandomURLSafeValues() throws {
        let values = try (0..<16).map { _ in try AppleSignInNonceContract.makeRawNonce() }
        XCTAssertEqual(Set(values).count, values.count)
        for value in values {
            XCTAssertGreaterThanOrEqual(value.count, 43)
            XCTAssertNotNil(value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression))
        }
    }

    func testExactNativeAndServerNonceRepresentations() {
        let raw = "raw-nonce"
        XCTAssertEqual(
            AppleSignInNonceContract.requestNonce(forRawNonce: raw),
            "2c5d107938053a2275f022c153c9a71f65ee07754b8bca543ee97a0c3cc66990"
        )
        XCTAssertEqual(AppleSignInNonceContract.serverNonce(forRawNonce: raw), raw)
        XCTAssertNotEqual(
            AppleSignInNonceContract.serverNonce(forRawNonce: raw),
            AppleSignInNonceContract.requestNonce(forRawNonce: raw)
        )
    }

    func testWatchAppleAttemptUsesSecureIndependentStateAndLowercaseHexNonce() throws {
        let attempts = try (0..<16).map { _ in try AppleSignInAttempt.make() }
        XCTAssertEqual(Set(attempts.map(\.rawNonce)).count, attempts.count)
        XCTAssertEqual(Set(attempts.map(\.state)).count, attempts.count)
        for attempt in attempts {
            XCTAssertNotEqual(attempt.rawNonce, attempt.state)
            XCTAssertEqual(attempt.requestNonce, AppleSignInNonceContract.requestNonce(forRawNonce: attempt.rawNonce))
            XCTAssertNotNil(attempt.requestNonce.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
        }
    }

    func testInvalidWatchAppleCredentialsCauseZeroServerPosts() async throws {
        let requests = LockedRequests()
        let client = AccountAPIClient(
            config: AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)),
            tokenStore: InMemorySecureTokenStore(),
            session: testSession { request in
                requests.append(request)
                return (500, AccountAPIErrorResponse(error: "unexpected", retryAt: nil))
            },
            deviceID: UUID(),
            platform: "watchOS"
        )

        let validToken = Data("identity-token".utf8)
        let validCode = Data("authorization-code".utf8)
        let cases: [(AppleNativeCredentialInput, String, String, AppleCredentialValidationError)] = [
            (
                AppleNativeCredentialInput(state: "wrong", identityToken: validToken, authorizationCode: validCode, displayName: "", email: ""),
                "expected", "raw-nonce", .stateMismatch
            ),
            (
                AppleNativeCredentialInput(state: "expected", identityToken: nil, authorizationCode: validCode, displayName: "", email: ""),
                "expected", "raw-nonce", .missingIdentityToken
            ),
            (
                AppleNativeCredentialInput(state: "expected", identityToken: validToken, authorizationCode: nil, displayName: "", email: ""),
                "expected", "raw-nonce", .missingAuthorizationCode
            ),
            (
                AppleNativeCredentialInput(state: "expected", identityToken: validToken, authorizationCode: validCode, displayName: "", email: ""),
                "expected", "", .missingNonce
            ),
        ]

        for (credential, expectedState, rawNonce, expectedError) in cases {
            do {
                _ = try await client.signInWithAppleFromWatch(
                    credential: credential,
                    expectedState: expectedState,
                    rawNonce: rawNonce
                )
                XCTFail("invalid native credential was submitted")
            } catch let error as AppleCredentialValidationError {
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail("unexpected error type: \(type(of: error))")
            }
        }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testValidWatchAppleCredentialProducesOneV3PostWithRawNonceAndWatchPlatform() async throws {
        let requests = LockedRequests()
        let accountID = UUID(), userID = UUID(), deviceID = UUID(), requestID = UUID()
        let response = AccountSessionResponse(
            account: AccountSummary(accountID: accountID, userID: userID, phoneNumber: nil, displayLabel: "@watch-user"),
            deviceID: deviceID,
            accessToken: "access", accessExpiresAt: .distantFuture,
            refreshToken: "refresh", refreshExpiresAt: .distantFuture,
            user: UserProfile(userID: userID, username: "watch-user", displayName: nil, email: nil, verifiedPhones: [], publicIdentity: "wsc:user:watch-user")
        )
        let client = AccountAPIClient(
            config: AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)),
            tokenStore: InMemorySecureTokenStore(),
            session: testSession { request in requests.append(request); return (200, response) },
            deviceID: deviceID,
            platform: "watchOS"
        )
        let rawNonce = "watch-raw-nonce"
        let credential = AppleNativeCredentialInput(
            state: "watch-state",
            identityToken: Data("identity-token".utf8),
            authorizationCode: Data("authorization-code".utf8),
            displayName: "Watch User",
            email: "relay@example.invalid"
        )

        _ = try await client.signInWithAppleFromWatch(
            credential: credential,
            expectedState: "watch-state",
            rawNonce: rawNonce,
            requestID: requestID
        )

        XCTAssertEqual(requests.values.count, 1)
        let request = try XCTUnwrap(requests.values.first)
        XCTAssertEqual(request.url?.path, "/wifi-secure-call/v3/auth/apple")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONDecoder.account.decode(AppleSignInRequest.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.requestID, requestID)
        XCTAssertEqual(body.deviceID, deviceID)
        XCTAssertEqual(body.platform, "watchOS")
        XCTAssertEqual(body.nonce, rawNonce)
        XCTAssertNotEqual(body.nonce, AppleSignInNonceContract.requestNonce(forRawNonce: rawNonce))
    }

    func testPhoneLessWatchAppleAccountCoexistsWithLinkedPhoneAccountAndTokensPersist() throws {
        let suite = "WatchAppleCoexistence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let tokens = InMemorySecureTokenStore()
        let store = AccountSessionStore(tokenStore: tokens, defaults: defaults)
        let legacyID = UUID(), appleID = UUID(), userID = UUID()
        let legacyTokens = AccountTokens(accessToken: "legacy-access", accessExpiresAt: .distantFuture, refreshToken: "legacy-refresh", refreshExpiresAt: .distantFuture)
        try store.addLinkedAccount(accountID: legacyID, phoneNumber: "+380••••4567", tokens: legacyTokens)
        let appleResponse = AccountSessionResponse(
            account: AccountSummary(accountID: appleID, userID: userID, phoneNumber: nil, displayLabel: "@watch-user"),
            deviceID: UUID(),
            accessToken: "apple-access", accessExpiresAt: .distantFuture,
            refreshToken: "apple-refresh", refreshExpiresAt: .distantFuture,
            user: UserProfile(userID: userID, username: "watch-user", displayName: nil, email: nil, verifiedPhones: [], publicIdentity: "wsc:user:watch-user")
        )
        try store.add(appleResponse)

        XCTAssertEqual(Set(store.accounts.map(\.accountID)), [legacyID, appleID])
        XCTAssertNil(store.accounts.first(where: { $0.accountID == appleID })?.phoneNumber)
        XCTAssertEqual(try tokens.tokens(for: legacyID), legacyTokens)
        XCTAssertEqual(try tokens.tokens(for: appleID), appleResponse.tokens)

        let reloaded = AccountSessionStore(tokenStore: tokens, defaults: defaults)
        XCTAssertEqual(Set(reloaded.accounts.map(\.accountID)), [legacyID, appleID])
        XCTAssertEqual(try tokens.tokens(for: legacyID), legacyTokens)
        XCTAssertEqual(try tokens.tokens(for: appleID), appleResponse.tokens)
    }

    func testWatchPushRegistrationUsesWatchDeviceAndPlatformAfterAccountStorage() async throws {
        let suite = "WatchApplePush.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let tokens = InMemorySecureTokenStore()
        let store = AccountSessionStore(tokenStore: tokens, defaults: defaults)
        let requests = LockedRequests()
        let watchDeviceID = UUID(), accountID = UUID(), userID = UUID()
        let client = AccountAPIClient(
            config: AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)),
            tokenStore: tokens,
            session: testSession { request in requests.append(request); return (204, AccountAPIErrorResponse(error: "", retryAt: nil)) },
            deviceID: watchDeviceID,
            platform: "watchOS"
        )
        let coordinator = AccountPushRegistrationCoordinator(
            store: store,
            client: client,
            platform: "watchOS",
            generation: 17
        )
        let capabilities = DeviceCapabilities(voipPush: true, alertPush: true, notificationsAuthorized: true, microphoneReady: true)
        await coordinator.update(token: Data([0xaa, 0xbb]), pushType: .alert, capabilities: capabilities)
        XCTAssertTrue(requests.values.isEmpty)

        let response = AccountSessionResponse(
            account: AccountSummary(accountID: accountID, userID: userID, phoneNumber: nil, displayLabel: "@watch-user"),
            deviceID: watchDeviceID,
            accessToken: "access", accessExpiresAt: .distantFuture,
            refreshToken: "refresh", refreshExpiresAt: .distantFuture,
            user: UserProfile(userID: userID, username: "watch-user", displayName: nil, email: nil, verifiedPhones: [], publicIdentity: "wsc:user:watch-user")
        )
        try store.add(response)
        await coordinator.registerKnownTokens(for: accountID)

        XCTAssertEqual(requests.values.count, 1)
        let request = try XCTUnwrap(requests.values.first)
        let body = try JSONDecoder.account.decode(AccountDeviceRegistrationRequest.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.deviceID, watchDeviceID)
        XCTAssertEqual(body.platform, "watchOS")
        XCTAssertEqual(body.installationGeneration, 17)
        XCTAssertEqual(body.pushType, .alert)
        XCTAssertEqual(body.token, "aabb")
    }

    func testWatchNativeAppleSourcePreservesOfficialButtonAndSixDigitLinking() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Watch/WatchAccountLinkView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("WKInterfaceAuthorizationAppleIDButton"))
        XCTAssertTrue(source.contains("WKInterfaceObjectRepresentable"))
        XCTAssertTrue(source.contains("ASAuthorizationAppleIDProvider().createRequest()"))
        XCTAssertTrue(source.contains("ASAuthorizationController(authorizationRequests:"))
        XCTAssertTrue(source.contains("client.watchLinkStart()"))
        XCTAssertTrue(source.contains("client.watchLinkStatus("))
        XCTAssertFalse(source.contains("print("))
        XCTAssertFalse(source.contains("NSLog("))
    }

    func testAppleValidationErrorsContainNoCredentialMaterial() {
        let secrets = ["identity-secret", "authorization-secret", "nonce-secret", "state-secret", "email@example.invalid"]
        let credential = AppleNativeCredentialInput(
            state: "wrong-state",
            identityToken: Data(secrets[0].utf8),
            authorizationCode: Data(secrets[1].utf8),
            displayName: "Private Name",
            email: secrets[4]
        )
        do {
            _ = try AppleCredentialContract.validate(credential, expectedState: secrets[3], rawNonce: secrets[2])
            XCTFail("state mismatch accepted")
        } catch {
            let text = String(reflecting: error)
            for secret in secrets { XCTAssertFalse(text.contains(secret)) }
        }
    }

    func testResolvedProductionConfigReturnsProductionURLsForPhoneAndWatch() {
        let expectedAPI = "https://178.105.32.46/wifi-secure-call/v1"
        let expectedMedia = "wss://178.105.32.46/wifi-secure-call/media"
        for role in [DeviceRole.B, .A] {
            let config = AppConfig.resolve(values: [
                "API_BASE_URL": expectedAPI,
                "MEDIA_BASE_URL": expectedMedia,
                "DEVICE_ROLE": role.rawValue,
                "BEARER_TOKEN": String(repeating: role == .A ? "a" : "b", count: 64),
            ])
            XCTAssertNil(config.configurationError)
            XCTAssertTrue(config.isProductionSafe)
            XCTAssertEqual(config.apiBaseURL.absoluteString, expectedAPI)
            XCTAssertEqual(config.mediaURL.absoluteString, expectedMedia)
            XCTAssertEqual(config.role, role)
            let root = config.apiBaseURL.deletingLastPathComponent()
            let apple = root
                .appendingPathComponent("v3", isDirectory: true)
                .appendingPathComponent("auth/apple")
            XCTAssertEqual(apple.absoluteString, "https://178.105.32.46/wifi-secure-call/v3/auth/apple")
        }
    }

    func testMissingBearerFailsClosedWithExplicitErrorAndNoInvalidInvalid() {
        let common = [
            "API_BASE_URL": "https://178.105.32.46/wifi-secure-call/v1",
            "MEDIA_BASE_URL": "wss://178.105.32.46/wifi-secure-call/media",
            "DEVICE_ROLE": "B",
        ]
        for token in [nil, ""] as [String?] {
            var values = common
            if let token { values["BEARER_TOKEN"] = token }
            let config = AppConfig.resolve(values: values)
            XCTAssertEqual(config.configurationError, .missingBearerToken)
            XCTAssertEqual(config.configurationError?.localizedDescription, "CONFIG_MISSING_BEARER_TOKEN")
            XCTAssertFalse(config.isProductionSafe)
            XCTAssertFalse(config.apiBaseURL.absoluteString.contains("invalid.invalid"))
            XCTAssertEqual(config.apiBaseURL.scheme, "wifisecurecall-config-error")
        }
    }

    func testInvalidBearerVariantsAreRejectedWithoutLeakingValues() {
        let candidates = ["short-private-value", String(repeating: "x", count: 31), String(repeating: "x", count: 32) + " "]
        for candidate in candidates {
            let config = AppConfig.resolve(values: [
                "API_BASE_URL": "https://178.105.32.46/wifi-secure-call/v1",
                "MEDIA_BASE_URL": "wss://178.105.32.46/wifi-secure-call/media",
                "DEVICE_ROLE": "A",
                "BEARER_TOKEN": candidate,
            ])
            XCTAssertEqual(config.configurationError, .invalidBearerToken)
            XCTAssertEqual(config.configurationError?.localizedDescription, "CONFIG_INVALID_BEARER_TOKEN")
            XCTAssertFalse(String(reflecting: config.configurationError).contains(candidate))
            XCTAssertFalse(config.isProductionSafe)
        }
    }

    func testMalformedURLsAreRejectedExplicitly() {
        let token = String(repeating: "x", count: 64)
        let invalidAPI = AppConfig.resolve(values: [
            "API_BASE_URL": "not a production URL",
            "MEDIA_BASE_URL": "wss://178.105.32.46/wifi-secure-call/media",
            "DEVICE_ROLE": "B",
            "BEARER_TOKEN": token,
        ])
        XCTAssertEqual(invalidAPI.configurationError, .invalidAPIURL)
        let invalidMedia = AppConfig.resolve(values: [
            "API_BASE_URL": "https://178.105.32.46/wifi-secure-call/v1",
            "MEDIA_BASE_URL": "https://178.105.32.46/wifi-secure-call/media",
            "DEVICE_ROLE": "B",
            "BEARER_TOKEN": token,
        ])
        XCTAssertEqual(invalidMedia.configurationError, .invalidMediaURL)
        XCTAssertFalse(invalidAPI.apiBaseURL.absoluteString.contains("invalid.invalid"))
        XCTAssertFalse(invalidMedia.apiBaseURL.absoluteString.contains("invalid.invalid"))
    }

    func testReleaseInfoPlistsUseIndependentProtectedTokenMappings() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func plist(_ relativePath: String) throws -> [String: Any] {
            let data = try Data(contentsOf: repository.appendingPathComponent(relativePath))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let phone = try plist("iOS/Info.plist")
        let watch = try plist("Watch/Info.plist")
        XCTAssertEqual(phone["BEARER_TOKEN"] as? String, "$(IOS_BEARER_TOKEN)")
        XCTAssertEqual(watch["BEARER_TOKEN"] as? String, "$(WATCH_BEARER_TOKEN)")
        XCTAssertEqual(phone["DEVICE_ROLE"] as? String, "B")
        XCTAssertEqual(watch["DEVICE_ROLE"] as? String, "A")
        let base = try String(contentsOf: repository.appendingPathComponent("Config/Base.xcconfig"), encoding: .utf8)
        XCTAssertTrue(base.contains("#include? \"Secrets.xcconfig\""))
        XCTAssertFalse(base.contains("IOS_BEARER_TOKEN ="))
        XCTAssertFalse(base.contains("WATCH_BEARER_TOKEN ="))
    }

    func testInvalidConfigurationPreventsAccountNetworkRequest() async throws {
        let requests = LockedRequests()
        let config = AppConfig.resolve(values: [
            "API_BASE_URL": "https://178.105.32.46/wifi-secure-call/v1",
            "MEDIA_BASE_URL": "wss://178.105.32.46/wifi-secure-call/media",
            "DEVICE_ROLE": "B",
            "BEARER_TOKEN": "",
        ])
        let client = AccountAPIClient(
            config: config,
            tokenStore: InMemorySecureTokenStore(),
            session: testSession { request in
                requests.append(request)
                return (500, AccountAPIErrorResponse(error: "unexpected", retryAt: nil))
            },
            deviceID: UUID()
        )
        do {
            _ = try await client.startPhone("+00000000000")
            XCTFail("invalid configuration attempted a request")
        } catch let error as AppConfigError {
            XCTAssertEqual(error, .missingBearerToken)
            XCTAssertEqual(error.localizedDescription, "CONFIG_MISSING_BEARER_TOKEN")
        } catch {
            XCTFail("unexpected error: \(type(of: error))")
        }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testReleasePreflightCoversBothTargetsWithoutPrintingTokenValues() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(contentsOf: repository.appendingPathComponent("WiFiSecureCall.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertEqual(project.components(separatedBy: "name = \"Verify Release Configuration\"").count - 1, 2)
        XCTAssertTrue(project.contains("IOS_BEARER_TOKEN-"))
        XCTAssertTrue(project.contains("WATCH_BEARER_TOKEN-"))
        XCTAssertTrue(project.contains("TOKEN_PRESENT=$present"))
        XCTAssertTrue(project.contains("TOKEN_LENGTH=$length"))
        XCTAssertTrue(project.contains("TOKEN_WHITESPACE=$whitespace"))
        XCTAssertTrue(project.contains("showEnvVarsInLog = 0"))
        XCTAssertFalse(project.contains(#"echo \"$token\""#))
    }

    func testNormalPersistentTransportPolicyRemainsUnchanged() {
        let configuration = AccountTransportPolicy.configuration()
        XCTAssertEqual(AccountTransportPolicy.requestTimeout, 10)
        XCTAssertEqual(AccountTransportPolicy.resourceTimeout, 10)
        XCTAssertFalse(AccountTransportPolicy.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testAppleAndLegacyRequestsShareGenericPersistentSessionWithOneApplePost() async throws {
        let captured = LockedRequests()
        let appleRequestCount = LockedCounter()
        let accountID = UUID(), userID = UUID(), deviceID = UUID(), requestID = UUID()
        let appleResponse = AccountSessionResponse(
            account: AccountSummary(accountID: accountID, userID: userID, phoneNumber: nil, displayLabel: "@user-test"),
            deviceID: deviceID,
            accessToken: "access", accessExpiresAt: .distantFuture,
            refreshToken: "refresh", refreshExpiresAt: .distantFuture,
            user: UserProfile(userID: userID, username: "user-test", displayName: nil, email: nil, verifiedPhones: [], publicIdentity: "wsc:user:user-test")
        )
        let phoneResponse = PhoneStartResponse(verificationID: UUID(), expiresAt: .distantFuture, resendAfter: .distantFuture)
        let session = testSession { request in
            captured.append(request)
            if request.url?.path == "/wifi-secure-call/v3/auth/apple" {
                appleRequestCount.increment()
                return (200, appleResponse)
            }
            return (200, phoneResponse)
        }
        let client = AccountAPIClient(
            config: AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)),
            tokenStore: InMemorySecureTokenStore(), session: session, deviceID: deviceID
        )

        _ = try await client.startPhone("+00000000000")
        _ = try await client.signInWithApple(
            identityToken: "identity-token",
            authorizationCode: "authorization-code",
            nonce: "raw-nonce",
            displayName: "Private Name",
            email: "email@example.invalid",
            requestID: requestID
        )

        XCTAssertEqual(captured.values.map(\.url?.path), [
            "/wifi-secure-call/v2/auth/phone/start",
            "/wifi-secure-call/v3/auth/apple",
        ])
        XCTAssertEqual(appleRequestCount.value, 1)
        let appleRequest = try XCTUnwrap(captured.values.last)
        XCTAssertEqual(appleRequest.httpMethod, "POST")
        XCTAssertEqual(appleRequest.timeoutInterval, 10)
        let body = try JSONDecoder.account.decode(AppleSignInRequest.self, from: try XCTUnwrap(appleRequest.httpBody))
        XCTAssertEqual(body.requestID, requestID)
        XCTAssertEqual(body.deviceID, deviceID)
        XCTAssertEqual(body.platform, "iOS")
        XCTAssertEqual(body.identityToken, "identity-token")
        XCTAssertEqual(body.authorizationCode, "authorization-code")
        XCTAssertEqual(body.nonce, "raw-nonce")
        XCTAssertEqual(body.displayName, "Private Name")
        XCTAssertEqual(body.email, "email@example.invalid")
    }

    func testProductionApplePathHasNoDiagnosticTransportInterposition() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let clientSource = try String(contentsOf: repository.appendingPathComponent("Shared/AccountAPIClient.swift"), encoding: .utf8)
        let accountViewSource = try String(contentsOf: repository.appendingPathComponent("iOS/AccountView.swift"), encoding: .utf8)

        XCTAssertTrue(clientSource.contains("self.session = session ?? URLSession(configuration: AccountTransportPolicy.configuration())"))
        XCTAssertTrue(clientSource.contains("try await request(\"auth/apple\""))
        XCTAssertTrue(clientSource.contains("(data, response) = try await session.data(for: value)"))
        XCTAssertTrue(accountViewSource.contains("client.signInWithApple("))
        for forbidden in [
            "AppleTaskLifecycleDelegate", "AppleNWPathTracker", "NWPathMonitor",
            "URLSessionTaskMetrics", "signInWithAppleDiagnosed", "Task.sleep", "usleep(",
        ] {
            XCTAssertFalse(clientSource.contains(forbidden), "unexpected transport interposition: \(forbidden)")
            XCTAssertFalse(accountViewSource.contains(forbidden), "unexpected Account view transport interposition: \(forbidden)")
        }
    }

    func testAppleSignInRequestSendsRawNonceToV3Server() async throws {
        let captured = LockedRequests()
        let accountID = UUID(), userID = UUID(), deviceID = UUID()
        let response = AccountSessionResponse(
            account: AccountSummary(accountID: accountID, userID: userID, phoneNumber: nil, displayLabel: "@user-test"),
            deviceID: deviceID,
            accessToken: "access", accessExpiresAt: .distantFuture,
            refreshToken: "refresh", refreshExpiresAt: .distantFuture,
            user: UserProfile(userID: userID, username: "user-test", displayName: nil, email: nil, verifiedPhones: [], publicIdentity: "wsc:user:user-test")
        )
        let session = testSession { request in
            captured.append(request)
            return (200, response)
        }
        let client = AccountAPIClient(
            config: AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)),
            tokenStore: InMemorySecureTokenStore(), session: session, deviceID: deviceID
        )
        let raw = "raw-nonce"
        _ = try await client.signInWithApple(identityToken: "jwt", authorizationCode: "code", nonce: AppleSignInNonceContract.serverNonce(forRawNonce: raw), displayName: "", email: "")
        let request = try XCTUnwrap(captured.values.first)
        XCTAssertEqual(request.url?.path, "/wifi-secure-call/v3/auth/apple")
        let body = try JSONDecoder.account.decode(AppleSignInRequest.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.nonce, raw)
        XCTAssertNotEqual(body.nonce, AppleSignInNonceContract.requestNonce(forRawNonce: raw))
    }

    func testSafeAppleVerificationDiagnosticClassification() {
        let codes: [AppleVerificationDiagnostic] = [.jwtFormat, .header, .keyFetch, .signature, .issuer, .audience, .expired, .nonce]
        for code in codes {
            let error = AccountAPIError.status(401, AccountAPIErrorResponse(error: code.rawValue, retryAt: nil))
            XCTAssertEqual(AppleVerificationDiagnostic.classify(error), code)
        }
        XCTAssertEqual(AppleVerificationDiagnostic.classify(AccountAPIError.status(404, nil)), .serverResponse)
        XCTAssertEqual(AppleVerificationDiagnostic.classify(AccountAPIError.decoding), .serverResponse)
    }

    func testTransportDiagnosticMappings() {
        let mappings: [(URLError.Code, AppleVerificationDiagnostic)] = [
            (.cannotFindHost, .dns),
            (.dnsLookupFailed, .dns),
            (.secureConnectionFailed, .tls),
            (.serverCertificateUntrusted, .tls),
            (.timedOut, .timeout),
            (.cannotConnectToHost, .connection),
            (.networkConnectionLost, .networkLost),
            (.notConnectedToInternet, .offline),
            (.cancelled, .cancelled),
            (.badURL, .otherTransport),
        ]
        for (code, expected) in mappings {
            let error = AccountAPIError.transport(domain: NSURLErrorDomain, code: code.rawValue)
            XCTAssertEqual(AppleVerificationDiagnostic.classify(error), expected)
        }
        let other = AccountAPIError.transport(domain: "Safe.Transport", code: 42)
        XCTAssertEqual(AppleVerificationDiagnostic.classify(other), .otherTransport)
        XCTAssertEqual(AppleVerificationDiagnostic.safeTransportDetail(other), "Safe.Transport 42")
        XCTAssertNil(AppleVerificationDiagnostic.safeTransportDetail(AccountAPIError.transport(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue)))
    }

    func testURLSessionFailureBecomesSafeTransportError() async {
        let session = testSession { _ -> (Int, Encodable) in throw URLError(.networkConnectionLost) }
        let client = AccountAPIClient(
            config: AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)),
            tokenStore: InMemorySecureTokenStore(), session: session, deviceID: UUID()
        )
        do {
            _ = try await client.signInWithApple(identityToken: "jwt", authorizationCode: "code", nonce: "nonce", displayName: "", email: "")
            XCTFail("transport failure was not thrown")
        } catch let error as AccountAPIError {
            guard case .transport(let domain, let code) = error else {
                return XCTFail("unexpected account error: \(error)")
            }
            XCTAssertEqual(domain, NSURLErrorDomain)
            XCTAssertEqual(code, URLError.networkConnectionLost.rawValue)
            XCTAssertEqual(AppleVerificationDiagnostic.classify(error), .networkLost)
        } catch {
            XCTFail("unwrapped transport error: \(type(of: error))")
        }
    }

    func testAppleTransportErrorNeverContainsCredentialMaterial() async {
        let secrets = ["identity-token-secret", "authorization-code-secret", "raw-nonce-secret", "email@example.invalid", "Private Name"]
        let session = testSession { _ -> (Int, Encodable) in throw URLError(.networkConnectionLost) }
        let client = AccountAPIClient(
            config: AppConfig(apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!, mediaURL: URL(string: "wss://example.invalid/media")!, role: .B, bearerToken: String(repeating: "b", count: 64)),
            tokenStore: InMemorySecureTokenStore(), session: session, deviceID: UUID()
        )
        do {
            _ = try await client.signInWithApple(
                identityToken: secrets[0], authorizationCode: secrets[1], nonce: secrets[2],
                displayName: secrets[4], email: secrets[3]
            )
            XCTFail("transport failure was not thrown")
        } catch {
            let safeText = String(reflecting: error) + " " + (AppleVerificationDiagnostic.safeTransportDetail(error) ?? "")
            for secret in secrets { XCTAssertFalse(safeText.contains(secret)) }
        }
    }

    private func testSession(handler: @escaping (URLRequest) throws -> (Int, Encodable)) -> URLSession {
        AccountURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class RemoteCellularControlTests: XCTestCase {
    func testStrictE164PolicyAndSafeDiagnosticSerialization() throws {
        XCTAssertEqual(RemoteCellularControlPolicy.normalizedE164("+380501234567"), "+380501234567")
        for invalid in ["0501234567", "+012345678", "+380 50 123 4567", "tel:+380501234567", "+123", "+1234567890123456"] {
            XCTAssertNil(RemoteCellularControlPolicy.normalizedE164(invalid), invalid)
        }
        XCTAssertEqual(RemoteCellularControlPolicy.requestTTL, 120)

        let diagnostic = RemoteCellularControlDiagnostic(
            requestID: UUID(), accountID: UUID(), expiresAt: .distantFuture, state: .iPhoneActionRequired,
            receiptContext: .background, sameOwnerAuthorized: true,
            appConfirmationRequired: true, systemStartAttempted: false,
            safeResult: "IPHONE_RECEIVED_BACKGROUND"
        )
        let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(encoded.contains("+380501234567"))
        XCTAssertFalse(encoded.contains("phoneNumber"))
        XCTAssertFalse(encoded.contains("e164"))
    }

    func testFlattenedStartGrantMatchesServerAuthorizationContract() throws {
        let requestID = UUID()
        let json = Data("""
        {"requestID":"\(requestID.uuidString.lowercased())","state":"iphone_start_authorized","createdAt":"2026-09-27T00:00:00Z","expiresAt":"2026-09-27T00:02:00Z","deliveryStatus":"submission_accepted","sourcePlatform":"watchOS","targetPlatform":"iOS","sameOwnerAuthorized":true,"mutationApplied":true,"phoneNumber":"+380501234567"}
        """.utf8)
        let grant = try JSONDecoder.account.decode(RemoteCellularControlStartGrant.self, from: json)
        XCTAssertEqual(grant.requestID, requestID)
        XCTAssertEqual(grant.state, .iPhoneStartAuthorized)
        XCTAssertTrue(grant.startGranted)
        XCTAssertEqual(grant.phoneNumber, "+380501234567")
        XCTAssertTrue(grant.control.sameOwnerAuthorized)
    }

    func testPushEnvelopeIsOpaqueAndContainsOnlyRequestAndTargetAccountIdentity() throws {
        let requestID = UUID(), accountID = UUID()
        let envelope = try XCTUnwrap(RemoteCellularControlPushEnvelope.parse([
            "event": "remote_cellular_control",
            "requestID": requestID.uuidString,
            "accountID": accountID.uuidString,
        ]))
        XCTAssertEqual(envelope.requestID, requestID)
        XCTAssertEqual(envelope.accountID, accountID)
        XCTAssertEqual(Set(Mirror(reflecting: envelope).children.compactMap(\.label)), ["requestID", "accountID"])
        XCTAssertNil(RemoteCellularControlPushEnvelope.parse([
            "event": "remote_cellular_control", "requestID": requestID.uuidString,
        ]))
    }

    func testAccountAPIUsesOneAuthenticatedV3CreateWithNoTargetDeviceFields() async throws {
        let accountID = UUID(), requestID = UUID(), captured = LockedRequests()
        let tokens = InMemorySecureTokenStore()
        try tokens.save(
            AccountTokens(
                accessToken: "remote-control-access", accessExpiresAt: .distantFuture,
                refreshToken: "remote-control-refresh", refreshExpiresAt: .distantFuture
            ),
            for: accountID
        )
        let response = Self.view(requestID: requestID, state: .deliveryPending)
        AccountURLProtocol.handler = { request in
            captured.append(request)
            return (200, response)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        let client = AccountAPIClient(
            config: Self.config, tokenStore: tokens,
            session: URLSession(configuration: configuration), deviceID: UUID()
        )

        _ = try await client.createRemoteCellularControl(
            accountID: accountID, requestID: requestID, phoneNumber: "+380501234567"
        )

        let request = try XCTUnwrap(captured.values.first)
        XCTAssertEqual(captured.values.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/wifi-secure-call/v3/cellular-controls")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer remote-control-access")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["requestID", "phoneNumber"])
        XCTAssertEqual((json["requestID"] as? String)?.lowercased(), requestID.uuidString.lowercased())
        XCTAssertEqual(json["phoneNumber"] as? String, "+380501234567")
        XCTAssertNil(json["targetDeviceID"])
        XCTAssertNil(json["targetUserID"])
        XCTAssertNil(json["targetAccountID"])
    }

    func testAccountAPIReportsReceiptAttemptAndSafeResultWithoutPhone() async throws {
        let accountID = UUID(), requestID = UUID(), captured = LockedRequests()
        let tokens = InMemorySecureTokenStore()
        try tokens.save(
            AccountTokens(
                accessToken: "remote-control-access", accessExpiresAt: .distantFuture,
                refreshToken: "remote-control-refresh", refreshExpiresAt: .distantFuture
            ),
            for: accountID
        )
        let response = Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background)
        AccountURLProtocol.handler = { request in
            captured.append(request)
            return (200, response)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        let client = AccountAPIClient(
            config: Self.config, tokenStore: tokens,
            session: URLSession(configuration: configuration), deviceID: UUID()
        )

        _ = try await client.receiveRemoteCellularControl(
            accountID: accountID, requestID: requestID, mutationID: UUID(), context: .background
        )
        _ = try await client.markRemoteCellularControlStartAttempted(
            accountID: accountID, requestID: requestID, mutationID: UUID()
        )
        _ = try await client.completeRemoteCellularControlStart(
            accountID: accountID, requestID: requestID, mutationID: UUID(),
            result: .error, errorDomain: "PublicCellularAPI", errorCode: 7
        )

        XCTAssertEqual(captured.values.count, 3)
        let paths = captured.values.compactMap(\.url?.path)
        XCTAssertEqual(paths, [
            "/wifi-secure-call/v3/cellular-controls/\(requestID.uuidString.lowercased())/receive",
            "/wifi-secure-call/v3/cellular-controls/\(requestID.uuidString.lowercased())/start-attempted",
            "/wifi-secure-call/v3/cellular-controls/\(requestID.uuidString.lowercased())/start-result",
        ])
        let bodies = try captured.values.map { request -> [String: Any] in
            let data = try XCTUnwrap(request.httpBody)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(bodies[0]["receiptContext"] as? String, "background")
        XCTAssertEqual(bodies[2]["result"] as? String, "error")
        XCTAssertEqual(bodies[2]["safeErrorDomain"] as? String, "PublicCellularAPI")
        XCTAssertEqual(bodies[2]["safeErrorCode"] as? Int, 7)
        for body in bodies {
            XCTAssertNil(body["phoneNumber"])
            XCTAssertNil(body["errorDescription"])
        }
    }

    func testBackgroundReceiptClaimsAndAttemptsPublicStartExactlyOnce() async throws {
        let accountID = UUID(), requestID = UUID()
        let store = try Self.accountStore(accountID: accountID)
        let view = Self.view(
            requestID: requestID, state: .iPhoneBackgroundReceived,
            receiptContext: .background
        )
        let grantView = Self.view(requestID: requestID, state: .iPhoneStartAuthorized)
        let api = RemoteControlAPIStub(
            view: view,
            grant: RemoteCellularControlStartGrant(control: grantView, startGranted: true, phoneNumber: "+380501234567")
        )
        let starter = RemoteCellularStarterSpy(beforeStart: { await api.observeStarterInvocation() })
        let coordinator = try Self.configuredCoordinator(api: api, accountStore: store, starter: starter)

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "SYSTEM_START_ACCEPTED")
        XCTAssertEqual(coordinator.diagnostic?.receiptContext, .background)
        XCTAssertEqual(coordinator.diagnostic?.applicationStateAtReceipt, .background)
        XCTAssertEqual(starter.numbers, ["+380501234567"])
        XCTAssertFalse(coordinator.presentationRequested)
        let firstCounts = await api.counts()
        XCTAssertEqual(firstCounts.receive, 1)
        XCTAssertEqual(firstCounts.claim, 1)
        XCTAssertEqual(firstCounts.attempt, 1)
        XCTAssertEqual(firstCounts.completion, 1)
        let attemptCountsAtPublicCall = await api.starterAttemptObservations()
        XCTAssertEqual(attemptCountsAtPublicCall, [0])
        let claimCountsAtPublicCall = await api.starterClaimObservations()
        XCTAssertEqual(claimCountsAtPublicCall, [1])
        XCTAssertTrue(coordinator.diagnostic?.startClaimObtained == true)
        XCTAssertTrue(coordinator.diagnostic?.systemStartAttempted == true)
        XCTAssertEqual(coordinator.diagnostic?.publicStartReturnedSuccess, true)

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )
        XCTAssertEqual(starter.numbers.count, 1)
        let duplicateCounts = await api.counts()
        XCTAssertEqual(duplicateCounts.claim, 1)
        XCTAssertEqual(duplicateCounts.completion, 1)
    }

    func testInactiveReceiptAlsoExercisesPublicStartWithoutForegroundGuard() async throws {
        let accountID = UUID(), requestID = UUID()
        let store = try Self.accountStore(accountID: accountID)
        let view = Self.view(
            requestID: requestID, state: .iPhoneBackgroundReceived,
            receiptContext: .inactive
        )
        let grantView = Self.view(requestID: requestID, state: .iPhoneStartAuthorized)
        let api = RemoteControlAPIStub(
            view: view,
            grant: RemoteCellularControlStartGrant(control: grantView, startGranted: true, phoneNumber: "+380501234567")
        )
        let starter = RemoteCellularStarterSpy()
        let coordinator = try Self.configuredCoordinator(api: api, accountStore: store, starter: starter)
        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .inactive,
            applicationState: .inactive
        )
        XCTAssertEqual(starter.numbers.count, 1)
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 1)
        XCTAssertEqual(coordinator.diagnostic?.applicationStateAtReceipt, .inactive)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "SYSTEM_START_ACCEPTED")
    }

    func testForegroundReceiptRemainsManualComparisonPath() async throws {
        let accountID = UUID(), requestID = UUID()
        let store = try Self.accountStore(accountID: accountID)
        let view = Self.view(requestID: requestID, state: .iPhoneActionRequired, receiptContext: .foreground)
        let grant = RemoteCellularControlStartGrant(
            control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
            startGranted: true,
            phoneNumber: "+380501234567"
        )
        let api = RemoteControlAPIStub(view: view, grant: grant)
        let starter = RemoteCellularStarterSpy()
        let coordinator = try Self.configuredCoordinator(api: api, accountStore: store, starter: starter)

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .foreground,
            applicationState: .foreground
        )
        XCTAssertTrue(starter.numbers.isEmpty)
        let beforeCounts = await api.counts()
        XCTAssertEqual(beforeCounts.claim, 0)
        XCTAssertTrue(coordinator.diagnostic?.appConfirmationRequired == true)

        await coordinator.startPendingControl()
        XCTAssertEqual(starter.numbers.count, 1)
        let afterCounts = await api.counts()
        XCTAssertEqual(afterCounts.claim, 1)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "SYSTEM_START_ACCEPTED")
    }

    func testPublicStartFailureIsReportedOnceAndNeverAutomaticallyRetried() async throws {
        let accountID = UUID(), requestID = UUID()
        let store = try Self.accountStore(accountID: accountID)
        let view = Self.view(
            requestID: requestID, state: .iPhoneBackgroundReceived,
            receiptContext: .background
        )
        let grant = RemoteCellularControlStartGrant(
            control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
            startGranted: true,
            phoneNumber: "+380501234567"
        )
        let api = RemoteControlAPIStub(view: view, grant: grant)
        let starter = RemoteCellularStarterSpy(error: NSError(domain: "tel.380501234567", code: 7))
        let coordinator = try Self.configuredCoordinator(api: api, accountStore: store, starter: starter)

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )
        XCTAssertEqual(starter.numbers.count, 1)
        XCTAssertEqual(coordinator.diagnostic?.state, .publicStartError)
        XCTAssertEqual(coordinator.diagnostic?.publicStartReturnedSuccess, false)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "PUBLIC_START_ERROR_PublicCellularAPI_7")
        let firstResults = await api.results()
        XCTAssertEqual(firstResults, [.error])
        let firstDomains = await api.errorDomains()
        XCTAssertEqual(firstDomains, ["PublicCellularAPI"])

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )
        await coordinator.startPendingControl()
        XCTAssertEqual(starter.numbers.count, 1)
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 1)
        XCTAssertEqual(counts.completion, 1)
    }

    func testTerminalDuplicateReceiptCannotClaimOrStart() async throws {
        let accountID = UUID(), requestID = UUID()
        let store = try Self.accountStore(accountID: accountID)
        let terminalView = Self.view(requestID: requestID, state: .systemStartAccepted)
        let api = RemoteControlAPIStub(
            view: terminalView,
            grant: RemoteCellularControlStartGrant(control: terminalView, startGranted: false, phoneNumber: nil)
        )
        let starter = RemoteCellularStarterSpy()
        let coordinator = try Self.configuredCoordinator(api: api, accountStore: store, starter: starter)
        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .openedFromNotification,
            applicationState: .foreground
        )
        XCTAssertFalse(coordinator.diagnostic?.appConfirmationRequired == true)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "SYSTEM_START_ACCEPTED")
        await coordinator.startPendingControl()
        let claimCalls = await api.claimCalls()
        XCTAssertEqual(claimCalls, 0)
        XCTAssertTrue(starter.numbers.isEmpty)
    }

    func testUnknownLocalAccountCannotFetchOrStartRequest() async throws {
        let localAccount = UUID(), targetAccount = UUID(), requestID = UUID()
        let store = try Self.accountStore(accountID: localAccount)
        let view = Self.view(requestID: requestID, state: .iPhoneActionRequired)
        let grantView = Self.view(requestID: requestID, state: .iPhoneStartAuthorized)
        let api = RemoteControlAPIStub(
            view: view,
            grant: RemoteCellularControlStartGrant(control: grantView, startGranted: true, phoneNumber: "+380501234567")
        )
        let starter = RemoteCellularStarterSpy()
        let coordinator = try Self.configuredCoordinator(api: api, accountStore: store, starter: starter)
        await coordinator.receive(
            .init(requestID: requestID, accountID: targetAccount),
            context: .foreground,
            applicationState: .foreground
        )
        let receiveCalls = await api.receiveCalls()
        XCTAssertEqual(receiveCalls, 0)
        XCTAssertTrue(starter.numbers.isEmpty)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "LOCAL_ACCOUNT_NOT_FOUND")
    }

    func testSelectedCellularServiceIsResolvedByIDRegardlessOfListOrderAndDestinationIsUnchanged() async throws {
        let accountID = UUID(), requestID = UUID()
        let selectedID = UUID(), otherID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let api = RemoteControlAPIStub(
            view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
            grant: RemoteCellularControlStartGrant(
                control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
                startGranted: true,
                phoneNumber: "+380501234567"
            )
        )
        let starter = RemoteCellularStarterSpy(services: [
            .init(id: otherID, label: "Other line"),
            .init(id: selectedID, label: "Chosen line"),
        ])
        let suite = "RemoteCellularSelectedLine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let selection = RemoteCellularLineSelectionStore(defaults: defaults)
        selection.setSelectedServiceID(selectedID, for: accountID)
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: api, accountStore: accountStore, starter: starter, lineSelectionStore: selection
        )

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )

        XCTAssertEqual(starter.preparedServiceIDs, [selectedID])
        XCTAssertEqual(starter.startedServiceIDs, [selectedID])
        XCTAssertEqual(starter.numbers, ["+380501234567"])
        XCTAssertTrue(coordinator.explicitCellularServicePassed)
        XCTAssertEqual(coordinator.selectedCellularServiceID, selectedID)
    }

    func testCellularLineSelectionPersistsAcrossStoreReopenAndIsScopedPerAccount() throws {
        let firstAccount = UUID(), secondAccount = UUID(), selectedID = UUID()
        let suite = "RemoteCellularSelectionPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        RemoteCellularLineSelectionStore(defaults: defaults)
            .setSelectedServiceID(selectedID, for: firstAccount)
        let reopened = RemoteCellularLineSelectionStore(defaults: defaults)

        XCTAssertEqual(reopened.selectedServiceID(for: firstAccount), selectedID)
        XCTAssertNil(reopened.selectedServiceID(for: secondAccount))
        let persisted = defaults.dictionaryRepresentation()
            .filter { $0.key.contains("remoteCellular.selectedService") }
            .values.compactMap { $0 as? String }
        XCTAssertEqual(persisted, [selectedID.uuidString.lowercased()])
        XCTAssertFalse(persisted.joined().contains("+380"))
    }

    func testExecutionModeMigrationDefaultsToStrictAndOptInIsAccountScoped() throws {
        let firstAccount = UUID(), secondAccount = UUID()
        let suite = "RemoteCellularModePersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = RemoteCellularExecutionModeStore(defaults: defaults)

        XCTAssertEqual(store.mode(for: firstAccount), .strictExplicitSIM)
        XCTAssertEqual(store.mode(for: secondAccount), .strictExplicitSIM)

        store.setMode(.systemManagedDiagnostic, for: firstAccount)
        let reopened = RemoteCellularExecutionModeStore(defaults: defaults)
        XCTAssertEqual(reopened.mode(for: firstAccount), .systemManagedDiagnostic)
        XCTAssertEqual(reopened.mode(for: secondAccount), .strictExplicitSIM)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("+380")
        })
    }

    func testStrictEmptyCatalogCannotClaimOrUseSystemManagedStarter() async throws {
        let accountID = UUID(), requestID = UUID(), missingServiceID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let api = RemoteControlAPIStub(
            view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
            grant: RemoteCellularControlStartGrant(
                control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
                startGranted: true,
                phoneNumber: "+380501234567"
            )
        )
        let starter = RemoteCellularStarterSpy(services: [])
        let selection = Self.lineSelectionStore()
        selection.setSelectedServiceID(missingServiceID, for: accountID)
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: api,
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: selection,
            executionModeStore: Self.executionModeStore()
        )

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )

        XCTAssertEqual(coordinator.executionModeSnapshot, .strictExplicitSIM)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "SELECTED_CELLULAR_SERVICE_UNAVAILABLE")
        XCTAssertEqual(starter.preparedSystemManagedCount, 0)
        XCTAssertTrue(starter.startedModes.isEmpty)
        XCTAssertTrue(starter.numbers.isEmpty)
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 0)
        XCTAssertEqual(counts.attempt, 0)
    }

    func testExplicitSystemManagedOptInCanStartWithEmptyCatalogOnlyAfterClaim() async throws {
        let accountID = UUID(), requestID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let api = RemoteControlAPIStub(
            view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
            grant: RemoteCellularControlStartGrant(
                control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
                startGranted: true,
                phoneNumber: "+380501234567"
            )
        )
        let starter = RemoteCellularStarterSpy(
            services: [],
            beforeStart: { await api.observeStarterInvocation() }
        )
        let modeStore = Self.executionModeStore()
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: api,
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: Self.lineSelectionStore(),
            executionModeStore: modeStore
        )
        XCTAssertEqual(coordinator.executionMode, .strictExplicitSIM)
        coordinator.confirmSystemManagedDiagnosticOptIn()
        XCTAssertEqual(coordinator.executionMode, .systemManagedDiagnostic)

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )

        XCTAssertEqual(coordinator.executionModeSnapshot, .systemManagedDiagnostic)
        XCTAssertEqual(starter.preparedSystemManagedCount, 1)
        XCTAssertTrue(starter.preparedServiceIDs.isEmpty)
        XCTAssertEqual(starter.startedModes, [.systemManagedDiagnostic])
        XCTAssertEqual(starter.numbers, ["+380501234567"])
        XCTAssertFalse(coordinator.explicitCellularServicePassed)
        XCTAssertTrue(coordinator.systemManagedPublicStartUsed)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "SYSTEM_START_ACCEPTED")
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 1)
        XCTAssertEqual(counts.attempt, 1)
        XCTAssertEqual(counts.completion, 1)
        let attemptCountsAtPublicCall = await api.starterAttemptObservations()
        XCTAssertEqual(attemptCountsAtPublicCall, [0])
        let claimCountsAtPublicCall = await api.starterClaimObservations()
        XCTAssertEqual(claimCountsAtPublicCall, [1])
        let labels = Set(Mirror(reflecting: try XCTUnwrap(coordinator.diagnostic)).children.compactMap(\.label))
        XCTAssertFalse(labels.contains("connected"))
        XCTAssertFalse(labels.contains("simPickerSuppressed"))
        XCTAssertFalse(labels.contains("watchAudio"))
    }

    func testExecutionModeIsSnapshottedBeforePreparationAndClaim() async throws {
        let accountID = UUID(), requestID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let modeStore = Self.executionModeStore()
        modeStore.setMode(.systemManagedDiagnostic, for: accountID)
        let api = RemoteControlAPIStub(
            view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
            grant: RemoteCellularControlStartGrant(
                control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
                startGranted: true,
                phoneNumber: "+380501234567"
            )
        )
        let starter = RemoteCellularStarterSpy(
            services: [],
            beforePrepareSystemManaged: {
                modeStore.setMode(.strictExplicitSIM, for: accountID)
            }
        )
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: api,
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: Self.lineSelectionStore(),
            executionModeStore: modeStore
        )

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )

        XCTAssertEqual(modeStore.mode(for: accountID), .strictExplicitSIM)
        XCTAssertEqual(coordinator.executionModeSnapshot, .systemManagedDiagnostic)
        XCTAssertEqual(starter.startedModes, [.systemManagedDiagnostic])
        XCTAssertEqual(starter.numbers, ["+380501234567"])
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 1)
    }

    func testSystemManagedModeCannotInvokeStarterWithoutOneTimeGrant() async throws {
        let accountID = UUID(), requestID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let modeStore = Self.executionModeStore()
        modeStore.setMode(.systemManagedDiagnostic, for: accountID)
        let rejectedGrantView = Self.view(requestID: requestID, state: .iPhoneBackgroundReceived)
        let api = RemoteControlAPIStub(
            view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
            grant: RemoteCellularControlStartGrant(
                control: rejectedGrantView,
                startGranted: false,
                phoneNumber: nil
            )
        )
        let starter = RemoteCellularStarterSpy(services: [])
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: api,
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: Self.lineSelectionStore(),
            executionModeStore: modeStore
        )

        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )

        XCTAssertEqual(starter.preparedSystemManagedCount, 1)
        XCTAssertTrue(starter.startedModes.isEmpty)
        XCTAssertTrue(starter.numbers.isEmpty)
        XCTAssertFalse(coordinator.systemManagedPublicStartUsed)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "START_NOT_GRANTED")
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 1)
        XCTAssertEqual(counts.attempt, 0)
        XCTAssertEqual(counts.completion, 0)
    }

    func testSystemManagedFailureCannotRetrySameRequest() async throws {
        let accountID = UUID(), requestID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let modeStore = Self.executionModeStore()
        modeStore.setMode(.systemManagedDiagnostic, for: accountID)
        let api = RemoteControlAPIStub(
            view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
            grant: RemoteCellularControlStartGrant(
                control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
                startGranted: true,
                phoneNumber: "+380501234567"
            )
        )
        let starter = RemoteCellularStarterSpy(
            services: [],
            error: NSError(domain: "SystemManagedPublicAPI", code: 19)
        )
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: api,
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: Self.lineSelectionStore(),
            executionModeStore: modeStore
        )

        let envelope = RemoteCellularControlPushEnvelope(requestID: requestID, accountID: accountID)
        await coordinator.receive(envelope, context: .background, applicationState: .background)
        await coordinator.receive(envelope, context: .background, applicationState: .background)
        await coordinator.startPendingControl()

        XCTAssertEqual(starter.startedModes, [.systemManagedDiagnostic])
        XCTAssertEqual(starter.numbers.count, 1)
        XCTAssertEqual(coordinator.diagnostic?.state, .publicStartError)
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 1)
        XCTAssertEqual(counts.completion, 1)
    }

    func testCoordinatorReloadsAccountScopedModeWithoutInheritance() throws {
        let firstAccount = UUID(), secondAccount = UUID()
        let accountStore = try Self.accountStore(accountID: firstAccount)
        try accountStore.addLinkedAccount(
            accountID: secondAccount,
            userID: UUID(),
            phoneNumber: nil,
            displayLabel: "Second account",
            tokens: AccountTokens(
                accessToken: "second-access", accessExpiresAt: .distantFuture,
                refreshToken: "second-refresh", refreshExpiresAt: .distantFuture
            )
        )
        let modeStore = Self.executionModeStore()
        modeStore.setMode(.systemManagedDiagnostic, for: firstAccount)
        accountStore.switchAccount(to: secondAccount)
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: Self.unusedRemoteControlAPI(),
            accountStore: accountStore,
            starter: RemoteCellularStarterSpy(services: []),
            lineSelectionStore: Self.lineSelectionStore(),
            executionModeStore: modeStore
        )

        XCTAssertEqual(coordinator.executionMode, .strictExplicitSIM)
        accountStore.switchAccount(to: firstAccount)
        coordinator.activeAccountDidChange()
        XCTAssertEqual(coordinator.executionMode, .systemManagedDiagnostic)
        accountStore.switchAccount(to: secondAccount)
        coordinator.activeAccountDidChange()
        XCTAssertEqual(coordinator.executionMode, .strictExplicitSIM)
    }

    func testCellularServiceCatalogReportsLoadingThenEmptyWithUnknownCause() throws {
        let accountID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let starter = RemoteCellularStarterSpy(services: [])
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: Self.unusedRemoteControlAPI(),
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: Self.lineSelectionStore()
        )
        var stateObservedInsidePublicGetter: RemoteCellularServiceCatalogState?
        starter.beforeAvailableServices = {
            stateObservedInsidePublicGetter = coordinator.cellularServiceCatalogState
        }

        coordinator.refreshCellularLines()

        XCTAssertEqual(stateObservedInsidePublicGetter, .loading)
        XCTAssertEqual(coordinator.cellularServiceCatalogState, .emptyWithUnknownCause)
        XCTAssertEqual(coordinator.cellularServiceCatalogCount, 0)
        XCTAssertNotNil(coordinator.cellularServiceCatalogReadAt)
        XCTAssertEqual(coordinator.cellularServiceCatalogReadMethod, "SYNCHRONOUS_PUBLIC_GETTER")
        XCTAssertEqual(coordinator.defaultCallingRoleStatus, .unknownPublicAPINotExposed)
        XCTAssertEqual(coordinator.cellularLineSelectionState, "EMPTY_WITH_UNKNOWN_CAUSE")
        XCTAssertEqual(starter.availableServicesReadCount, 1)
    }

    func testCellularServiceCatalogReadIsIndependentFromAppAccount() throws {
        let suite = "RemoteCellularNoAccountCatalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let accountStore = AccountSessionStore(tokenStore: InMemorySecureTokenStore(), defaults: defaults)
        let service = RemoteCellularServiceOption(id: UUID(), label: "System line")
        let starter = RemoteCellularStarterSpy(services: [service])
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: Self.unusedRemoteControlAPI(),
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: Self.lineSelectionStore()
        )

        coordinator.refreshCellularLines()

        XCTAssertEqual(coordinator.cellularServiceCatalogState, .available)
        XCTAssertEqual(coordinator.cellularServiceCatalogCount, 1)
        XCTAssertEqual(coordinator.availableCellularServices, [service])
        XCTAssertEqual(coordinator.cellularLineSelectionState, "ACCOUNT_SESSION_REQUIRED")
        XCTAssertNil(coordinator.selectedCellularServiceID)
        XCTAssertEqual(starter.availableServicesReadCount, 1)
    }

    func testCellularServiceCatalogErrorDoesNotBecomeRoleDenialOrNoSIM() throws {
        let accountID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let starter = RemoteCellularStarterSpy(
            services: [],
            availableServicesError: NSError(domain: "PublicCellularCatalog", code: 9)
        )
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: Self.unusedRemoteControlAPI(),
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: Self.lineSelectionStore()
        )

        coordinator.refreshCellularLines()

        XCTAssertEqual(coordinator.cellularServiceCatalogState, .error)
        XCTAssertEqual(coordinator.defaultCallingRoleStatus, .unknownPublicAPINotExposed)
        XCTAssertEqual(coordinator.cellularLineSelectionState, "FAILED_SAFE")
        XCTAssertFalse(coordinator.cellularLineSelectionState.contains("NO_SIM"))
        XCTAssertFalse(coordinator.cellularLineSelectionState.contains("NOT_DEFAULT"))
        XCTAssertEqual(starter.availableServicesReadCount, 1)
    }

    func testAccountChangeReappliesOnlyThatAccountsStoredServiceAgainstCurrentCatalog() throws {
        let firstAccount = UUID(), secondAccount = UUID()
        let firstService = RemoteCellularServiceOption(id: UUID(), label: "First owner line")
        let secondService = RemoteCellularServiceOption(id: UUID(), label: "Second owner line")
        let accountStore = try Self.accountStore(accountID: firstAccount)
        try accountStore.addLinkedAccount(
            accountID: secondAccount,
            userID: UUID(),
            phoneNumber: nil,
            displayLabel: "Second account",
            tokens: AccountTokens(
                accessToken: "second-access", accessExpiresAt: .distantFuture,
                refreshToken: "second-refresh", refreshExpiresAt: .distantFuture
            )
        )
        let selection = Self.lineSelectionStore()
        selection.setSelectedServiceID(firstService.id, for: firstAccount)
        selection.setSelectedServiceID(secondService.id, for: secondAccount)
        let starter = RemoteCellularStarterSpy(services: [secondService, firstService])
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: Self.unusedRemoteControlAPI(),
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: selection
        )

        coordinator.refreshCellularLines()
        XCTAssertEqual(coordinator.selectedCellularServiceID, secondService.id)

        accountStore.switchAccount(to: firstAccount)
        coordinator.activeAccountDidChange()
        XCTAssertEqual(coordinator.selectedCellularServiceID, firstService.id)
        XCTAssertEqual(coordinator.selectedCellularServiceLabel, firstService.label)
        XCTAssertEqual(coordinator.storedCellularServiceIDMatchesCatalog, true)

        starter.services = [secondService]
        coordinator.refreshCellularLines()
        XCTAssertEqual(coordinator.selectedCellularServiceID, firstService.id)
        XCTAssertNil(coordinator.selectedCellularServiceLabel)
        XCTAssertEqual(coordinator.storedCellularServiceIDMatchesCatalog, false)
        XCTAssertEqual(coordinator.cellularLineSelectionState, "SELECTED_CELLULAR_SERVICE_UNAVAILABLE")
    }

    func testMissingEmptyOrAmbiguousCellularSelectionStopsBeforeClaimAndPublicStart() async throws {
        let cases: [(storedID: UUID?, services: [RemoteCellularServiceOption], expected: String)] = [
            (nil, [.init(id: UUID(), label: "Only line")], "OWNER_LINE_MAPPING_REQUIRED"),
            (UUID(), [], "SELECTED_CELLULAR_SERVICE_UNAVAILABLE"),
            (UUID(), [.init(id: UUID(), label: "Different line")], "SELECTED_CELLULAR_SERVICE_UNAVAILABLE"),
        ]

        for testCase in cases {
            let accountID = UUID(), requestID = UUID()
            let accountStore = try Self.accountStore(accountID: accountID)
            let api = RemoteControlAPIStub(
                view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
                grant: RemoteCellularControlStartGrant(
                    control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
                    startGranted: true,
                    phoneNumber: "+380501234567"
                )
            )
            let starter = RemoteCellularStarterSpy(services: testCase.services)
            let suite = "RemoteCellularUnavailableLine.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let selection = RemoteCellularLineSelectionStore(defaults: defaults)
            if let storedID = testCase.storedID {
                selection.setSelectedServiceID(storedID, for: accountID)
            }
            let coordinator = IOSRemoteCellularControlCoordinator(
                api: api, accountStore: accountStore, starter: starter, lineSelectionStore: selection
            )

            await coordinator.receive(
                .init(requestID: requestID, accountID: accountID),
                context: .background,
                applicationState: .background
            )

            let counts = await api.counts()
            XCTAssertEqual(counts.claim, 0, testCase.expected)
            XCTAssertEqual(counts.attempt, 0, testCase.expected)
            XCTAssertTrue(starter.numbers.isEmpty, testCase.expected)
            XCTAssertFalse(coordinator.explicitCellularServicePassed, testCase.expected)
            XCTAssertFalse(coordinator.diagnostic?.systemStartAttempted == true, testCase.expected)
            XCTAssertEqual(coordinator.diagnostic?.safeResult, testCase.expected)
        }

        let accountID = UUID(), requestID = UUID(), duplicateID = UUID()
        let accountStore = try Self.accountStore(accountID: accountID)
        let api = RemoteControlAPIStub(
            view: Self.view(requestID: requestID, state: .iPhoneBackgroundReceived, receiptContext: .background),
            grant: RemoteCellularControlStartGrant(
                control: Self.view(requestID: requestID, state: .iPhoneStartAuthorized),
                startGranted: true,
                phoneNumber: "+380501234567"
            )
        )
        let starter = RemoteCellularStarterSpy(services: [
            .init(id: duplicateID, label: "Line A"),
            .init(id: duplicateID, label: "Line B"),
        ])
        let suite = "RemoteCellularAmbiguousLine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let selection = RemoteCellularLineSelectionStore(defaults: defaults)
        selection.setSelectedServiceID(duplicateID, for: accountID)
        let coordinator = IOSRemoteCellularControlCoordinator(
            api: api, accountStore: accountStore, starter: starter, lineSelectionStore: selection
        )
        await coordinator.receive(
            .init(requestID: requestID, accountID: accountID),
            context: .background,
            applicationState: .background
        )
        let counts = await api.counts()
        XCTAssertEqual(counts.claim, 0)
        XCTAssertTrue(starter.numbers.isEmpty)
        XCTAssertEqual(coordinator.diagnostic?.safeResult, "AMBIGUOUS_CELLULAR_SERVICE_ID")
    }

    func testFirstPartyInternetCheckIsAnonymousBoundedAndIndependentFromNWPath() async throws {
        let captured = LockedRequests()
        let result = await CarrierCallingFirstPartyInternetCheck.run(config: Self.config) { request in
            captured.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil
            )!
            return (Data(#"{"ok":true}"#.utf8), response)
        }
        XCTAssertEqual(result, .success)
        let request = try XCTUnwrap(captured.values.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/wifi-secure-call/v1/health")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)

        var record = CarrierCallingDiagnosticRecord.baseline(platform: .watchOS)
        record.network = .init(status: "unsatisfied", interfaces: ["wifi"], isExpensive: false, isConstrained: false)
        record.firstPartyInternetCheck = .success
        let snapshot = CarrierCallingObservationSnapshot(record: record)
        XCTAssertTrue(snapshot.conciseDescription.contains("nwpath=unsatisfied/wifi"))
        XCTAssertTrue(snapshot.conciseDescription.contains("firstPartyInternet=SUCCESS"))
    }

    func testRemoteProbeUsesPublicBackgroundPathWithoutForegroundGuardPushKitTelOrAutomaticWatchDial() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let iOSSource = try String(
            contentsOf: root.appendingPathComponent("iOS/IOSRemoteCellularControl.swift"), encoding: .utf8
        )
        let watchSource = try String(
            contentsOf: root.appendingPathComponent("Watch/WatchRemoteCellularControlView.swift"), encoding: .utf8
        )
        let notificationSource = try String(
            contentsOf: root.appendingPathComponent("iOS/IOSNotificationController.swift"), encoding: .utf8
        )
        XCTAssertTrue(iOSSource.contains("StartCellularConversationAction(handle, cellularService: selectedService)"))
        XCTAssertTrue(iOSSource.contains("StartCellularConversationAction(handle)"))
        XCTAssertTrue(iOSSource.contains("TelephonyConversationManager.sharedInstance.startCellularConversation(action)"))
        XCTAssertTrue(iOSSource.contains("TelephonyConversationManager.sharedInstance.cellularServices"))
        XCTAssertTrue(iOSSource.contains("UNKNOWN_PUBLIC_API_NOT_EXPOSED"))
        XCTAssertFalse(iOSSource.contains("UIApplication.shared.isDefault"))
        XCTAssertFalse(iOSSource.contains("UIApplication.Category(rawValue:"))
        XCTAssertFalse(iOSSource.contains("UIApplication.shared.applicationState == .active"))
        XCTAssertFalse(iOSSource.contains("foregroundRequired"))
        XCTAssertFalse(iOSSource.contains("PushKit"))
        XCTAssertFalse(iOSSource.contains("cellularServices.first"))
        XCTAssertFalse(iOSSource.contains("UIApplication.shared.open"))
        XCTAssertFalse(iOSSource.contains("\"tel:"))
        XCTAssertFalse(iOSSource.contains("CellularService(id: UUID("))
        for source in [watchSource, notificationSource] {
            XCTAssertFalse(source.contains("StartCellularConversationAction"))
            XCTAssertFalse(source.contains("startCellularConversation("))
        }
        XCTAssertTrue(watchSource.contains("Button(\"Test cellular start on iPhone\")"))
        XCTAssertTrue(watchSource.contains("WatchSystemDialerNumber.appending"))
        XCTAssertTrue(watchSource.contains("WatchSystemDialerNumber.deletingLast"))
        XCTAssertTrue(watchSource.contains("BACKGROUND_EXECUTION_NOT_OBSERVED"))
        XCTAssertTrue(watchSource.contains("PUBLIC_START_ERROR"))
        XCTAssertTrue(watchSource.contains("SYSTEM_START_ACCEPTED"))
        XCTAssertFalse(watchSource.contains("PUBLIC_START_ERROR_\\(domain)"))
        XCTAssertFalse(watchSource.contains("openSystemURL("))
        XCTAssertFalse(watchSource.contains("tel:"))

        XCTAssertTrue(iOSSource.contains("Request within TTL now"))
        XCTAssertTrue(iOSSource.contains("App confirmation required"))
        XCTAssertTrue(iOSSource.contains("Explicit cellular service passed"))
        XCTAssertTrue(iOSSource.contains("System-managed public start used"))
        XCTAssertTrue(iOSSource.contains("Підтверджую контрольний режим"))
        XCTAssertTrue(iOSSource.contains("реальний мобільний виклик"))
        XCTAssertFalse(iOSSource.contains("Server verified fresh"))
        XCTAssertFalse(iOSSource.contains("User action required"))
        XCTAssertFalse(iOSSource.contains("SIM picker absent"))
        XCTAssertFalse(iOSSource.contains("CONNECTED"))

        let publicStart = try XCTUnwrap(
            iOSSource.range(of: "try await starter.startCellularConversation(to: transientNumber, using: preparedStart)")
        )
        let immediateClear = try XCTUnwrap(
            iOSSource.range(of: "transientNumber.removeAll(keepingCapacity: false)", range: publicStart.upperBound..<iOSSource.endIndex)
        )
        let serverAttemptReport = try XCTUnwrap(
            iOSSource.range(of: "api.markRemoteCellularControlStartAttempted", range: immediateClear.upperBound..<iOSSource.endIndex)
        )
        XCTAssertLessThan(publicStart.lowerBound, immediateClear.lowerBound)
        XCTAssertLessThan(immediateClear.lowerBound, serverAttemptReport.lowerBound)

        let voIPDelegate = try XCTUnwrap(notificationSource.range(of: "extension IOSNotificationController: PKPushRegistryDelegate"))
        XCTAssertFalse(notificationSource[voIPDelegate.lowerBound...].contains("remote_cellular_control"))
    }

    func testIOSRemoteNotificationBackgroundModeIsEnabledWithoutUnrelatedCapabilityChanges() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["iOS/WiFiSecureCall.entitlements", "Watch/WiFiSecureCallWatch.entitlements"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("com.apple.CommCenter.fine-grained"))
        }
        let iOSEntitlementsData = try Data(contentsOf: root.appendingPathComponent("iOS/WiFiSecureCall.entitlements"))
        let iOSEntitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: iOSEntitlementsData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(iOSEntitlements["aps-environment"] as? String, "production")
        XCTAssertEqual(iOSEntitlements["com.apple.developer.calling-app"] as? Bool, true)
        XCTAssertEqual(iOSEntitlements["com.apple.developer.dialing-app"] as? Bool, true)
        XCTAssertEqual(iOSEntitlements["com.apple.developer.applesignin"] as? [String], ["Default"])
        XCTAssertEqual(iOSEntitlements["com.apple.developer.usernotifications.time-sensitive"] as? Bool, true)

        let watchEntitlementsData = try Data(contentsOf: root.appendingPathComponent("Watch/WiFiSecureCallWatch.entitlements"))
        let watchEntitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: watchEntitlementsData, format: nil) as? [String: Any]
        )
        XCTAssertNil(watchEntitlements["com.apple.developer.calling-app"])
        XCTAssertNil(watchEntitlements["com.apple.developer.dialing-app"])

        let iOSPlistData = try Data(contentsOf: root.appendingPathComponent("iOS/Info.plist"))
        let iOSPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: iOSPlistData, format: nil) as? [String: Any])
        let iOSModes = iOSPlist["UIBackgroundModes"] as? [String]
        XCTAssertEqual(iOSModes, ["audio", "remote-notification", "voip"])
        XCTAssertEqual(iOSModes?.filter { $0 == "remote-notification" }.count, 1)
        XCTAssertFalse(iOSModes?.contains("fetch") == true)
        XCTAssertFalse(iOSModes?.contains("processing") == true)

        let watchPlistData = try Data(contentsOf: root.appendingPathComponent("Watch/Info.plist"))
        let watchPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: watchPlistData, format: nil) as? [String: Any])
        XCTAssertEqual(watchPlist["UIBackgroundModes"] as? [String], ["audio", "remote-notification", "voip"])

        let project = try String(
            contentsOf: root.appendingPathComponent("WiFiSecureCall.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertEqual(
            project.components(separatedBy: "CODE_SIGN_ENTITLEMENTS = iOS/WiFiSecureCall.entitlements;").count - 1,
            2
        )
        XCTAssertTrue(project.contains("PROVISIONING_PROFILE_SPECIFIER = WiFiSecureCallAppStoreD24;"))
        XCTAssertTrue(project.contains(
            "T10000000000000000000001 = {CreatedOnToolsVersion = 26.6; SystemCapabilities = {com.apple.BackgroundModes = {enabled = 1; }; }; };"
        ))
        XCTAssertTrue(project.contains(
            "T10000000000000000000002 = {CreatedOnToolsVersion = 26.6; };"
        ))
    }

    func testBackgroundFetchCompletionIsExactlyOnceAndDeadlineIsSubThirtySeconds() {
        var results: [UIBackgroundFetchResult] = []
        let completion = RemoteCellularExactlyOnceCompletion<UIBackgroundFetchResult> { results.append($0) }
        completion.finish(.failed)
        completion.finish(.newData)
        XCTAssertEqual(results.map(\.rawValue), [UIBackgroundFetchResult.failed.rawValue])
        XCTAssertGreaterThan(RemoteCellularControlPolicy.backgroundFetchCompletionDeadlineNanoseconds, 0)
        XCTAssertLessThan(
            RemoteCellularControlPolicy.backgroundFetchCompletionDeadlineNanoseconds,
            30_000_000_000
        )
    }

    func testRemoteSourcesDoNotLogOrPersistDestinationAndDoNotUsePrivateAPI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let paths = [
            "Shared/AccountModels.swift", "iOS/IOSRemoteCellularControl.swift",
            "Watch/WatchRemoteCellularControlView.swift",
        ]
        let sources = try paths.map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }
        let source = sources.joined(separator: "\n")
        for forbidden in [
            "Keychain", "FileManager", "Diagnostics.shared", "Logger(", "os_log", "print(",
            "NSClassFromString", "dlopen(", "dlsym(", "performSelector", "value(forKey:",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertFalse(sources[0].contains("UserDefaults"))
        XCTAssertFalse(sources[2].contains("UserDefaults"))
        XCTAssertTrue(sources[1].contains("defaults.set(serviceID.uuidString.lowercased()"))
        XCTAssertFalse(sources[1].contains("defaults.set(phoneNumber"))
        XCTAssertFalse(sources[1].contains("defaults.set(e164"))
    }

    private static let config = AppConfig(
        apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!,
        mediaURL: URL(string: "wss://example.invalid/wifi-secure-call/media")!,
        role: .B, bearerToken: String(repeating: "b", count: 64)
    )

    private static func unusedRemoteControlAPI() -> RemoteControlAPIStub {
        let requestID = UUID()
        let view = Self.view(requestID: requestID, state: .deliveryPending)
        return RemoteControlAPIStub(
            view: view,
            grant: RemoteCellularControlStartGrant(control: view, startGranted: false, phoneNumber: nil)
        )
    }

    private static func lineSelectionStore() -> RemoteCellularLineSelectionStore {
        let suite = "RemoteCellularCatalogSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RemoteCellularLineSelectionStore(defaults: defaults)
    }

    private static func executionModeStore() -> RemoteCellularExecutionModeStore {
        let suite = "RemoteCellularExecutionMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RemoteCellularExecutionModeStore(defaults: defaults)
    }

    private static func view(
        requestID: UUID,
        state: RemoteCellularControlState,
        receiptContext: RemoteCellularReceiptContext? = nil,
        terminalReason: String? = nil
    ) -> RemoteCellularControlView {
        RemoteCellularControlView(
            requestID: requestID, state: state,
            createdAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date().addingTimeInterval(120),
            deliveryStatus: "submission_accepted", sourcePlatform: "watchOS",
            targetPlatform: "iOS", sameOwnerAuthorized: true, mutationApplied: true,
            terminalReason: terminalReason, receiptContext: receiptContext,
            receivedAt: receiptContext == nil ? nil : Date(),
            startAttemptedAt: nil, startResultAt: nil
        )
    }

    private static func accountStore(accountID: UUID) throws -> AccountSessionStore {
        let suite = "RemoteCellularControlTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = AccountSessionStore(tokenStore: InMemorySecureTokenStore(), defaults: defaults)
        try store.addLinkedAccount(
            accountID: accountID, userID: UUID(), phoneNumber: nil,
            displayLabel: "Secure account",
            tokens: AccountTokens(
                accessToken: "access", accessExpiresAt: .distantFuture,
                refreshToken: "refresh", refreshExpiresAt: .distantFuture
            )
        )
        return store
    }

    private static func configuredCoordinator(
        api: any RemoteCellularControlAPI,
        accountStore: AccountSessionStore,
        starter: RemoteCellularStarterSpy
    ) throws -> IOSRemoteCellularControlCoordinator {
        let suite = "RemoteCellularLineSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let selectionStore = RemoteCellularLineSelectionStore(defaults: defaults)
        let accountID = try XCTUnwrap(accountStore.activeAccountID)
        selectionStore.setSelectedServiceID(RemoteCellularStarterSpy.defaultServiceID, for: accountID)
        return IOSRemoteCellularControlCoordinator(
            api: api,
            accountStore: accountStore,
            starter: starter,
            lineSelectionStore: selectionStore,
            executionModeStore: Self.executionModeStore()
        )
    }
}

@MainActor
private final class RemoteCellularStarterSpy: CellularConversationStarting {
    static let defaultServiceID = UUID(uuidString: "C4E98D68-8BD5-475B-98A5-24A0AD913638")!

    private(set) var numbers: [String] = []
    private(set) var preparedServiceIDs: [UUID] = []
    private(set) var startedServiceIDs: [UUID] = []
    private(set) var preparedSystemManagedCount = 0
    private(set) var startedModes: [RemoteCellularExecutionMode] = []
    private(set) var availableServicesReadCount = 0
    var services: [RemoteCellularServiceOption]
    private let error: Error?
    private let availableServicesError: Error?
    private let beforeStart: (() async -> Void)?
    private let beforePrepareSystemManaged: (() -> Void)?
    var beforeAvailableServices: (() -> Void)?

    init(
        services: [RemoteCellularServiceOption]? = nil,
        error: Error? = nil,
        availableServicesError: Error? = nil,
        beforePrepareSystemManaged: (() -> Void)? = nil,
        beforeStart: (() async -> Void)? = nil
    ) {
        self.services = services ?? [
            RemoteCellularServiceOption(id: Self.defaultServiceID, label: "Owner selected line")
        ]
        self.error = error
        self.availableServicesError = availableServicesError
        self.beforePrepareSystemManaged = beforePrepareSystemManaged
        self.beforeStart = beforeStart
    }

    func availableCellularServices() throws -> [RemoteCellularServiceOption] {
        availableServicesReadCount += 1
        beforeAvailableServices?()
        if let availableServicesError { throw availableServicesError }
        return services
    }

    func prepareCellularService(id: UUID) throws -> RemoteCellularPreparedStart {
        let matches = services.filter { $0.id == id }
        guard !matches.isEmpty else { throw RemoteCellularLocalError.selectedLineUnavailable }
        guard matches.count == 1, let selected = matches.first else {
            throw RemoteCellularLocalError.ambiguousLine
        }
        preparedServiceIDs.append(id)
        return RemoteCellularPreparedStart(
            mode: .strictExplicitSIM,
            explicitServiceID: selected.id,
            explicitServiceLabel: selected.label
        ) { _ in }
    }

    func prepareSystemManagedStart() throws -> RemoteCellularPreparedStart {
        beforePrepareSystemManaged?()
        preparedSystemManagedCount += 1
        return RemoteCellularPreparedStart(mode: .systemManagedDiagnostic) { _ in }
    }

    func startCellularConversation(to e164: String, using preparedStart: RemoteCellularPreparedStart) async throws {
        numbers.append(e164)
        startedModes.append(preparedStart.mode)
        if let serviceID = preparedStart.explicitServiceID {
            startedServiceIDs.append(serviceID)
        }
        await beforeStart?()
        if let error { throw error }
    }
}

private actor RemoteControlAPIStub: RemoteCellularControlAPI {
    private var viewValue: RemoteCellularControlView
    private let grantValue: RemoteCellularControlStartGrant
    private var receiveCount = 0
    private var claimCount = 0
    private var attemptCount = 0
    private var completionCount = 0
    private var completionValues: [RemoteCellularStartResult] = []
    private var completionErrorDomains: [String] = []
    private var attemptCountsAtStarterInvocation: [Int] = []
    private var claimCountsAtStarterInvocation: [Int] = []
    private var receiptContext: RemoteCellularReceiptContext?

    init(view: RemoteCellularControlView, grant: RemoteCellularControlStartGrant) {
        viewValue = view
        grantValue = grant
    }

    func createRemoteCellularControl(accountID: UUID, requestID: UUID, phoneNumber: String) async throws -> RemoteCellularControlView { viewValue }
    func remoteCellularControl(accountID: UUID, requestID: UUID) async throws -> RemoteCellularControlView { viewValue }
    func receiveRemoteCellularControl(accountID: UUID, requestID: UUID, mutationID: UUID, context: RemoteCellularReceiptContext) async throws -> RemoteCellularControlView {
        receiveCount += 1
        receiptContext = receiptContext ?? context
        return viewValue
    }
    func claimRemoteCellularControlStart(accountID: UUID, requestID: UUID, mutationID: UUID) async throws -> RemoteCellularControlStartGrant {
        claimCount += 1
        guard claimCount == 1 else {
            return RemoteCellularControlStartGrant(control: viewValue, startGranted: false, phoneNumber: nil)
        }
        return grantValue
    }
    func markRemoteCellularControlStartAttempted(accountID: UUID, requestID: UUID, mutationID: UUID) async throws -> RemoteCellularControlView {
        attemptCount += 1
        let background = receiptContext == .background || receiptContext == .inactive
        viewValue = replacing(
            state: background ? .iPhoneBackgroundStartAttempted : .iPhoneForegroundStartAttempted,
            startAttemptedAt: Date()
        )
        return viewValue
    }
    func completeRemoteCellularControlStart(
        accountID: UUID,
        requestID: UUID,
        mutationID: UUID,
        result: RemoteCellularStartResult,
        errorDomain: String?,
        errorCode: Int?
    ) async throws -> RemoteCellularControlView {
        completionCount += 1
        completionValues.append(result)
        if let errorDomain { completionErrorDomains.append(errorDomain) }
        viewValue = replacing(
            state: result == .accepted ? .systemStartAccepted : .publicStartError,
            startAttemptedAt: viewValue.startAttemptedAt ?? Date(),
            startResultAt: Date(),
            startResult: result,
            safeErrorDomain: errorDomain,
            safeErrorCode: errorCode
        )
        return viewValue
    }
    func cancelRemoteCellularControl(accountID: UUID, requestID: UUID, mutationID: UUID) async throws -> RemoteCellularControlView { viewValue }

    func receiveCalls() -> Int { receiveCount }
    func claimCalls() -> Int { claimCount }
    func counts() -> (receive: Int, claim: Int, attempt: Int, completion: Int) {
        (receiveCount, claimCount, attemptCount, completionCount)
    }
    func results() -> [RemoteCellularStartResult] { completionValues }
    func errorDomains() -> [String] { completionErrorDomains }
    func observeStarterInvocation() {
        attemptCountsAtStarterInvocation.append(attemptCount)
        claimCountsAtStarterInvocation.append(claimCount)
    }
    func starterAttemptObservations() -> [Int] { attemptCountsAtStarterInvocation }
    func starterClaimObservations() -> [Int] { claimCountsAtStarterInvocation }

    private func replacing(
        state: RemoteCellularControlState,
        startAttemptedAt: Date? = nil,
        startResultAt: Date? = nil,
        startResult: RemoteCellularStartResult? = nil,
        safeErrorDomain: String? = nil,
        safeErrorCode: Int? = nil
    ) -> RemoteCellularControlView {
        RemoteCellularControlView(
            requestID: viewValue.requestID,
            state: state,
            createdAt: viewValue.createdAt,
            expiresAt: viewValue.expiresAt,
            deliveryStatus: viewValue.deliveryStatus,
            sourcePlatform: viewValue.sourcePlatform,
            targetPlatform: viewValue.targetPlatform,
            sameOwnerAuthorized: viewValue.sameOwnerAuthorized,
            mutationApplied: true,
            terminalReason: resultTerminalReason(state),
            receiptContext: receiptContext ?? viewValue.receiptContext,
            receivedAt: viewValue.receivedAt ?? Date(),
            startAttemptedAt: startAttemptedAt,
            startResultAt: startResultAt,
            startResult: startResult,
            safeErrorDomain: safeErrorDomain,
            safeErrorCode: safeErrorCode
        )
    }

    private func resultTerminalReason(_ state: RemoteCellularControlState) -> String? {
        state == .publicStartError ? "public_start_error" : nil
    }
}
