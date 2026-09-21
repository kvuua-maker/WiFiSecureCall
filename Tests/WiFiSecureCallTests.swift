import AVFoundation
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
        XCTAssertTrue(data.contains { $0 != 0 }, "Conversion must preserve nonzero signal energy")
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
    func testIncomingPushCreatesOneDistinctLocalCallKitUUIDAndReportsBeforeGET() async throws {
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
        XCTAssertEqual(Array(capture.events.prefix(2)), ["report", "get"])
        XCTAssertEqual(adapter.answerIDs.count, 0)
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
        await eventually { audio.played.contains(remoteFrame) }
        XCTAssertTrue(audio.played.contains(remoteFrame))
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
    private func eventually(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class RetainedCallKitMock: CallKitHandling {
    var onPrepareAudio: (() throws -> Void)?
    var onActionFailed: ((UUID, String, Error) -> Void)?
    var onStartRequested: ((UUID, Date) async throws -> Void)?
    var onAnswerRequested: ((UUID, Date) async throws -> Void)?
    var onEndRequested: ((UUID, Date) async throws -> Void)?
    var onMutedRequested: ((UUID, Bool) throws -> Void)?
    var onActionTimedOut: ((UUID, String) -> Void)?
    var onAudioActivated: ((UUID) -> Void)?
    var onAudioDeactivated: ((UUID?) -> Void)?
    var onProviderReset: ((UUID?) -> Void)?
    var startError: Error?
    var startedIDs: [UUID] = []
    var incomingIDs: [UUID] = []
    var answerIDs: [UUID] = []
    var endRequestIDs: [UUID] = []
    var endedIDs: [UUID] = []
    var startedConnectingIDs: [UUID] = []
    var connectedIDs: [UUID] = []
    var mutedRequests: [(UUID, Bool)] = []
    var onReportIncoming: (() -> Void)?
    func startOutgoing(id: UUID) async throws { startedIDs.append(id); if let startError { throw startError } }
    func reportIncoming(id: UUID) async throws { incomingIDs.append(id); onReportIncoming?() }
    func requestAnswer(id: UUID) async throws { answerIDs.append(id) }
    func requestEnd(id: UUID) async throws { endRequestIDs.append(id) }
    func requestSetMuted(id: UUID, muted: Bool) async throws { mutedRequests.append((id, muted)); try onMutedRequested?(id, muted) }
    func reportOutgoingStartedConnecting(id: UUID) { startedConnectingIDs.append(id) }
    func reportOutgoingConnected(id: UUID) { connectedIDs.append(id) }
    func reportEnded(id: UUID, reason: CallEndReason) { endedIDs.append(id) }
    func approveStart(_ id: UUID) async throws { try await onStartRequested?(id, Date().addingTimeInterval(10)) }
    func approveAnswer(_ id: UUID) async throws { try await onAnswerRequested?(id, Date().addingTimeInterval(10)) }
    func approveEnd(_ id: UUID) async throws { try await onEndRequested?(id, Date().addingTimeInterval(10)) }
}

private final class AudioEngineMock: AudioEngineHandling, @unchecked Sendable {
    var onFrame: (@Sendable (Data) -> Void)?
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)?
    var onFailure: (@Sendable (AudioEngineRuntimeFailure) -> Void)?
    var onMuteChanged: (@Sendable (Bool) -> Void)?
    var permission = true
    var startCount = 0
    var stopCount = 0
    var played: [Data] = []
    func ensureRecordPermission() async -> Bool { permission }
    func configureSession() throws {}
    func start() throws { startCount += 1 }
    func stop() { stopCount += 1 }
    func setMuted(_ value: Bool) throws {}
    func play(_ payload: Data) { played.append(payload) }
}

private final class MediaTransportMock: MediaTransport, @unchecked Sendable {
    var onPacket: (@Sendable (AudioPacket, UUID) -> Void)?
    var onDisconnect: (@Sendable (MediaDisconnect) -> Void)?
    var onPeerReady: (@Sendable (UUID, UUID) -> Void)?
    var onDiagnostic: (@Sendable (MediaTransportDiagnostic) -> Void)?
    private(set) var connectedCallIDs: [UUID] = []
    private(set) var sentPackets: [AudioPacket] = []
    private(set) var connectionIDs: [UUID] = []
    func connect(callID: UUID, role: DeviceRole, token: String) async throws -> UUID { let id = UUID(); connectedCallIDs.append(callID); connectionIDs.append(id); return id }
    func send(_ packet: AudioPacket, connectionID: UUID) async throws { sentPackets.append(packet) }
    func close(connectionID: UUID?) async {}
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private var _events: [String] = []
    private var _createdCallID: UUID?
    private var _callKitDiagnostic: [String: Any]?
    var mutationState: ServerCallState = .ended
    var getState: ServerCallState = .ringing
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

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        onRequest?(request)
        let path = request.url?.path ?? ""
        lock.withLock { _paths.append(path) }
        let requestBody = bodyData(from: request)
        if path.hasSuffix("/devices/diagnostics"), let body = requestBody,
           let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
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
