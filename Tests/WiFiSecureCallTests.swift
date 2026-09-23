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

    func testAccountPushCoordinatorRegistersEveryAccountAndInvalidatesIndependently() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AccountPushCoordinator.\(UUID())"))
        let secrets = InMemorySecureTokenStore()
        let store = AccountSessionStore(tokenStore: secrets, defaults: defaults)
        let first = accountResponse(phone: "+380501234567", access: "access-one", refresh: "refresh-one")
        let second = accountResponse(phone: "+14155550123", access: "access-two", refresh: "refresh-two")
        try store.add(first)
        try store.add(second)
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
        XCTAssertEqual(requests.values.count, 2)
        XCTAssertEqual(Set(requests.values.compactMap { $0.value(forHTTPHeaderField: "Authorization") }), ["Bearer access-one", "Bearer access-two"])
        for request in requests.values {
            let body = try JSONDecoder.account.decode(AccountDeviceRegistrationRequest.self, from: try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.deviceID, deviceID)
            XCTAssertEqual(body.pushType, .alert)
            XCTAssertEqual(body.token, "aabb")
            XCTAssertEqual(body.installationGeneration, 7)
        }

        store.switchAccount(to: first.account.accountID)
        await coordinator.update(token: Data([0xcc, 0xdd]), pushType: .voip, capabilities: caps)
        XCTAssertEqual(requests.values.count, 4)

        let linked = accountResponse(phone: "+442071838750", access: "access-watch", refresh: "refresh-watch")
        try store.addLinkedAccount(accountID: linked.account.accountID, phoneNumber: linked.account.phoneNumber, tokens: linked.tokens)
        await coordinator.registerKnownTokens(for: linked.account.accountID)
        XCTAssertEqual(requests.values.count, 6)

        await coordinator.invalidate(pushType: .voip, expectedToken: Data([0xcc, 0xdd]))
        XCTAssertEqual(requests.values.count, 9)
        let invalidations = try requests.values.suffix(3).map { try JSONDecoder.account.decode(AccountDeviceRegistrationRequest.self, from: XCTUnwrap($0.httpBody)) }
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

private final class InMemorySecureTokenStore: SecureTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: AccountTokens] = [:]
    func tokens(for accountID: UUID) throws -> AccountTokens? { lock.withLock { values[accountID] } }
    func save(_ tokens: AccountTokens, for accountID: UUID) throws { lock.withLock { values[accountID] = tokens } }
    func delete(accountID: UUID) throws { lock.withLock { values[accountID] = nil } }
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
