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
}
