import XCTest

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
        for value in 1...20 { buffer.insert(AudioPacket(type: .audio, callID: id, sequence: UInt64(value), timestampMicroseconds: 0, payload: Data())) }
        XCTAssertLessThanOrEqual(buffer.packets.count, 6)
        var missing = JitterBuffer(); missing.insert(AudioPacket(type: .audio, callID: id, sequence: 4, timestampMicroseconds: 0, payload: Data()))
        _ = missing.pop(); XCTAssertNil(missing.pop())
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

    @MainActor
    func testCallSessionRetainsCallKitAdapter() {
        let config = AppConfig(
            apiBaseURL: URL(string: "https://example.invalid/v1")!,
            mediaURL: URL(string: "wss://example.invalid/media")!,
            role: .B,
            bearerToken: String(repeating: "a", count: 64)
        )
        let session = CallSession(config: config)
        var adapter: RetainedCallKitMock? = RetainedCallKitMock()
        weak var retained = adapter
        session.attach(callKit: adapter!)
        adapter = nil
        XCTAssertNotNil(retained)
        XCTAssertNotNil(retained?.onPrepareAudio)
        XCTAssertNotNil(retained?.onActionFailed)
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
        let session = CallSession(config: config)
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
}

@MainActor
private final class RetainedCallKitMock: CallKitHandling {
    var onPrepareAudio: (() throws -> Void)?
    var onActionFailed: ((UUID, String, Error) -> Void)?
    var onStartApproved: ((UUID) -> Void)?
    var onAnswerApproved: ((UUID) -> Void)?
    var onEndApproved: ((UUID) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var startError: Error?
    func startOutgoing(id: UUID) async throws { if let startError { throw startError } }
    func reportIncoming(id: UUID) async throws {}
    func requestAnswer(id: UUID) async throws {}
    func requestEnd(id: UUID) async throws {}
    func reportEnded(id: UUID) {}
}
