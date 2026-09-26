import Foundation
import XCTest

@MainActor
final class CrossUserContractTests: XCTestCase {
    func testResolverEncodesAllSupportedRecipientFormsAndReturnsSafeIdentity() async throws {
        let accountID = UUID(), userID = UUID()
        let tokenStore = CrossUserTokenStore()
        try tokenStore.save(Self.tokens, for: accountID)
        let captured = CrossUserRequestCapture()
        let session = Self.session { request in
            captured.append(request)
            return (200, ResolvedRecipient(
                userID: userID, username: "alice", displayName: "Alice",
                publicIdentity: "wsc:user:alice", phoneNumber: "+380•••4567"
            ))
        }
        let client = AccountAPIClient(config: Self.config, tokenStore: tokenStore, session: session)

        for input in ["@Alice", "alice", "wsc:user:alice", "+380 50-123-4567"] {
            let response = try await client.resolveRecipient(input, accountID: accountID)
            XCTAssertEqual(response.userID, userID)
            XCTAssertEqual(response.username, "alice")
        }

        XCTAssertEqual(captured.values.count, 4)
        for (request, input) in zip(captured.values, ["@Alice", "alice", "wsc:user:alice", "+380 50-123-4567"]) {
            XCTAssertEqual(request.url?.path, "/wifi-secure-call/v3/recipients/resolve")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cross-user-access")
            let body = try JSONDecoder.account.decode(RecipientResolveRequest.self, from: try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.recipient, input)
        }

        let encoded = String(data: try JSONEncoder.account.encode(try await client.resolveRecipient("alice", accountID: accountID)), encoding: .utf8) ?? ""
        for forbidden in ["email", "appleSubject", "accountID", "deviceID", "accessToken", "refreshToken", "apns"] {
            XCTAssertFalse(encoded.lowercased().contains(forbidden.lowercased()))
        }
    }

    func testMalformedLocalPhoneReceivesStableInvalidRecipientWithoutFallback() async throws {
        let accountID = UUID(), tokenStore = CrossUserTokenStore()
        try tokenStore.save(Self.tokens, for: accountID)
        let session = Self.session { request in
            let body = try JSONDecoder.account.decode(RecipientResolveRequest.self, from: try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.recipient, "050 123 4567")
            return (400, AccountAPIErrorResponse(error: "invalid_recipient", retryAt: nil))
        }
        let client = AccountAPIClient(config: Self.config, tokenStore: tokenStore, session: session)
        do {
            _ = try await client.resolveRecipient("050 123 4567", accountID: accountID)
            XCTFail("local phone unexpectedly resolved")
        } catch let AccountAPIError.status(status, response) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(response?.error, "invalid_recipient")
        }
    }

    func testCrossUserCreateUsesV3TargetUserIDAndLegacyCallStaysV2TargetDeviceID() async throws {
        let accountID = UUID(), targetUserID = UUID(), targetDeviceID = UUID(), callID = UUID()
        let tokenStore = CrossUserTokenStore()
        try tokenStore.save(Self.tokens, for: accountID)
        let captured = CrossUserRequestCapture()
        let session = Self.session { request in
            captured.append(request)
            if request.url?.path == "/wifi-secure-call/v3/calls" {
                return (200, Self.userCall(callID: callID, side: .caller, state: .ringing))
            }
            return (200, Self.accountCall(callID: callID, side: .caller, state: .ringing))
        }
        let client = AccountAPIClient(config: Self.config, tokenStore: tokenStore, session: session)
        let requestID = UUID()
        _ = try await client.createUserCall(accountID: accountID, callID: callID, requestID: requestID, targetUserID: targetUserID)
        _ = try await client.createCall(accountID: accountID, callID: callID, requestID: requestID, targetDeviceID: targetDeviceID)

        let userRequest = try XCTUnwrap(captured.values.first { $0.url?.path == "/wifi-secure-call/v3/calls" })
        let userBody = try JSONDecoder.account.decode(CrossUserCallCreateRequest.self, from: try XCTUnwrap(userRequest.httpBody))
        XCTAssertEqual(userBody.targetUserID, targetUserID)
        XCTAssertEqual(userBody.requestID, requestID)
        let legacyRequest = try XCTUnwrap(captured.values.first { $0.url?.path == "/wifi-secure-call/v2/calls" })
        let legacyBody = try JSONDecoder.account.decode(AccountCallCreateRequest.self, from: try XCTUnwrap(legacyRequest.httpBody))
        XCTAssertEqual(legacyBody.targetDeviceID, targetDeviceID)
        XCTAssertEqual(captured.values.count, 2)
    }

    func testRecipientUnavailableMapsToSafeCallFailure() async throws {
        let accountID = UUID(), targetUserID = UUID(), tokenStore = CrossUserTokenStore()
        try tokenStore.save(Self.tokens, for: accountID)
        let session = Self.session { _ in
            (409, AccountAPIErrorResponse(error: "recipient_unavailable", retryAt: nil))
        }
        let client = AccountAPIClient(config: Self.config, tokenStore: tokenStore, session: session)
        let signaling = CrossUserCallSignaling(client: client, accountID: accountID, targetUserID: targetUserID, localSide: .caller)
        do {
            _ = try await signaling.create(callID: UUID(), requestID: UUID())
            XCTFail("unavailable recipient unexpectedly started")
        } catch let failure as CallFailure {
            XCTAssertEqual(failure, .targetUnavailable)
        }
    }

    func testIncomingV3IdentityIsStrictAndV1V2RemainCompatible() {
        let callID = UUID(), accountID = UUID()
        let caller = CrossUserCallerIdentity(username: "alice", displayName: "Alice", publicIdentity: "wsc:user:alice")
        XCTAssertEqual(IncomingNotificationEnvelope.parse([
            "event": "incoming_call_v3", "serverCallID": callID.uuidString,
            "accountID": accountID.uuidString, "callerUsername": "Alice",
            "callerPublicIdentity": "wsc:user:alice", "callerDisplayName": "Alice"
        ]), .user(callID: callID, accountID: accountID, caller: caller))
        XCTAssertEqual(IncomingNotificationEnvelope.parse([
            "event": "incoming_call", "serverCallID": callID.uuidString
        ]), .legacy(callID: callID))
        XCTAssertEqual(IncomingNotificationEnvelope.parse([
            "event": "incoming_call_v2", "serverCallID": callID.uuidString, "accountID": accountID.uuidString
        ]), .account(callID: callID, accountID: accountID))
        XCTAssertNil(IncomingNotificationEnvelope.parse([
            "event": "incoming_call_v3", "serverCallID": callID.uuidString,
            "accountID": accountID.uuidString, "callerUsername": "alice",
            "callerPublicIdentity": "wsc:user:mallory"
        ]))
    }

    func testCrossUserSignalingMapsAnsweredElsewhereWithoutMediaToken() async throws {
        let accountID = UUID(), targetUserID = UUID(), callID = UUID(), tokenStore = CrossUserTokenStore()
        try tokenStore.save(Self.tokens, for: accountID)
        let session = Self.session { _ in
            (200, Self.userCall(
                callID: callID, side: .callee, state: .accepted,
                legState: .answeredElsewhere, mediaToken: "must-not-reach-loser",
                caller: CrossUserCallerIdentity(username: "alice", displayName: nil, publicIdentity: "wsc:user:alice")
            ))
        }
        let client = AccountAPIClient(config: Self.config, tokenStore: tokenStore, session: session)
        let signaling = CrossUserCallSignaling(client: client, accountID: accountID, targetUserID: targetUserID, localSide: .callee)
        let view = try await signaling.call(callID)
        XCTAssertTrue(view.answeredElsewhere)
        XCTAssertNil(view.mediaToken)
        XCTAssertEqual(view.incomingCallerName, "@alice")
    }

    func testAnsweredElsewhereStopsLocalRingingWithoutRejectOrEnd() async throws {
        let callID = UUID()
        let signaling = CrossUserSessionSignaling(callID: callID, answersElsewhereAfterFirstRead: true)
        let session = CallSession(config: Self.config, audio: CrossUserAudioMock(), media: CrossUserMediaMock())
        let callKit = CrossUserCallKitMock()
        session.attach(callKit: callKit)
        await session.handleIncomingVoIP(callID: callID, signaling: signaling)
        await Self.eventually { session.state == .failed(callID, .answeredElsewhere) }
        XCTAssertEqual(session.state, .failed(callID, .answeredElsewhere))
        XCTAssertTrue(signaling.mutations.isEmpty)
        XCTAssertEqual(callKit.endedReasons, [.declined])
    }

    func testAnsweredElsewhereRaceNeverSendsEndOrReject() async throws {
        let callID = UUID()
        let signaling = CrossUserSessionSignaling(
            callID: callID, answersElsewhereAfterFirstRead: true,
            acceptDelayNanoseconds: 800_000_000, acceptReturnsAnsweredElsewhere: true
        )
        let session = CallSession(config: Self.config, audio: CrossUserAudioMock(), media: CrossUserMediaMock())
        let callKit = CrossUserCallKitMock()
        session.attach(callKit: callKit)
        await session.handleIncoming(callID: callID, requestAnswer: false, signaling: signaling)
        let answer = Task { await session.accept() }
        await Self.eventually { session.state == .failed(callID, .answeredElsewhere) }
        await answer.value
        XCTAssertEqual(session.state, .failed(callID, .answeredElsewhere))
        XCTAssertEqual(signaling.mutations, [.accept])
        XCTAssertFalse(signaling.mutations.contains(.reject))
        XCTAssertFalse(signaling.mutations.contains(.end))
    }

    func testCrossUserRejectMutatesOnlyRejectAndPreservesCallerIdentity() async throws {
        let callID = UUID()
        let identity = CrossUserCallerIdentity(username: "alice", displayName: "Alice", publicIdentity: "wsc:user:alice")
        let signaling = CrossUserSessionSignaling(callID: callID, callerIdentity: identity)
        let session = CallSession(config: Self.config, audio: CrossUserAudioMock(), media: CrossUserMediaMock())
        let callKit = CrossUserCallKitMock()
        session.attach(callKit: callKit)
        await session.handleIncoming(callID: callID, requestAnswer: false, signaling: signaling)
        XCTAssertEqual(callKit.incomingName, "Alice (@alice)")
        await session.reject()
        await Self.eventually { signaling.mutations.contains(.reject) }
        XCTAssertEqual(signaling.mutations, [.reject])
        XCTAssertFalse(signaling.mutations.contains(.end))
        XCTAssertFalse(signaling.mutations.contains(.cancel))
    }

    private static let config = AppConfig(
        apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!,
        mediaURL: URL(string: "wss://example.invalid/wifi-secure-call/media")!,
        role: .B, bearerToken: String(repeating: "b", count: 64)
    )
    private static let tokens = AccountTokens(
        accessToken: "cross-user-access", accessExpiresAt: .distantFuture,
        refreshToken: "cross-user-refresh", refreshExpiresAt: .distantFuture
    )

    private static func session(handler: @escaping (URLRequest) throws -> (Int, Encodable)) -> URLSession {
        CrossUserURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrossUserURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func userCall(
        callID: UUID, side: CallPartySide, state: ServerCallState,
        legState: CrossUserLegState? = nil, mediaToken: String? = nil,
        caller: CrossUserCallerIdentity? = nil
    ) -> CrossUserCallResponse {
        CrossUserCallResponse(
            callID: callID, localSide: side, state: state, legState: legState,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000), mediaToken: mediaToken,
            ringExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), acceptedAt: state == .accepted ? Date() : nil,
            terminalAt: nil, terminalReason: nil, deliveryStatus: "submission_accepted",
            peerReady: false, createdNew: true, mutationApplied: nil, caller: caller
        )
    }

    private static func accountCall(callID: UUID, side: CallPartySide, state: ServerCallState) -> AccountCallResponse {
        AccountCallResponse(
            callID: callID, localSide: side, state: state,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000), mediaToken: nil,
            ringExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), acceptedAt: nil,
            terminalAt: nil, terminalReason: nil, deliveryStatus: "submission_accepted",
            peerReady: false, createdNew: true, mutationApplied: nil
        )
    }

    private static func eventually(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<300 where !predicate() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

private final class CrossUserTokenStore: SecureTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: AccountTokens] = [:]
    func tokens(for accountID: UUID) throws -> AccountTokens? { lock.withLock { values[accountID] } }
    func save(_ tokens: AccountTokens, for accountID: UUID) throws { lock.withLock { values[accountID] = tokens } }
    func delete(accountID: UUID) throws { lock.withLock { values[accountID] = nil } }
    func deleteIfRefreshTokenMatches(accountID: UUID, refreshToken: String) throws -> Bool {
        lock.withLock {
            guard values[accountID]?.refreshToken == refreshToken else { return false }
            values[accountID] = nil
            return true
        }
    }
}

private final class CrossUserRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class CrossUserURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Encodable))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                captured.httpBody = data
            }
            let (status, value) = try handler(captured)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder.account.encode(CrossUserAnyEncodable(value)))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private struct CrossUserAnyEncodable: Encodable {
    let encodeValue: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

private final class CrossUserSessionSignaling: CallSignaling, @unchecked Sendable {
    let mediaPeerIdentity: MediaPeerIdentity = .account(.callee)
    let incomingCallerName: String?
    let requiresIncomingReconciliation = true
    private let callID: UUID
    private let answersElsewhereAfterFirstRead: Bool
    private let acceptDelayNanoseconds: UInt64
    private let acceptReturnsAnsweredElsewhere: Bool
    private let lock = NSLock()
    private var reads = 0
    private var mutationStorage: [CallMutation] = []
    var mutations: [CallMutation] { lock.withLock { mutationStorage } }

    init(callID: UUID, callerIdentity: CrossUserCallerIdentity? = nil, answersElsewhereAfterFirstRead: Bool = false, acceptDelayNanoseconds: UInt64 = 0, acceptReturnsAnsweredElsewhere: Bool = false) {
        self.callID = callID
        self.incomingCallerName = callerIdentity?.callKitName
        self.answersElsewhereAfterFirstRead = answersElsewhereAfterFirstRead
        self.acceptDelayNanoseconds = acceptDelayNanoseconds
        self.acceptReturnsAnsweredElsewhere = acceptReturnsAnsweredElsewhere
    }

    func create(callID: UUID, requestID: UUID) async throws -> CallSignalView { view(state: .ringing) }
    func call(_ id: UUID) async throws -> CallSignalView {
        let answered = lock.withLock { reads += 1; return answersElsewhereAfterFirstRead && reads > 1 }
        return view(state: answered ? .accepted : .ringing, answeredElsewhere: answered)
    }
    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallSignalView {
        lock.withLock { mutationStorage.append(action) }
        switch action {
        case .accept:
            if acceptDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: acceptDelayNanoseconds) }
            return view(state: .accepted, answeredElsewhere: acceptReturnsAnsweredElsewhere, mediaToken: acceptReturnsAnsweredElsewhere ? nil : "winner-token")
        case .reject: return view(state: .rejected)
        case .cancel: return view(state: .cancelled)
        case .end: return view(state: .ended)
        }
    }
    private func view(state: ServerCallState, answeredElsewhere: Bool = false, mediaToken: String? = nil) -> CallSignalView {
        CallSignalView(
            callID: callID, localSide: .callee, state: state,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000), mediaToken: mediaToken,
            ringExpiresAt: Date(timeIntervalSince1970: 2_000_000_000), acceptedAt: state == .accepted ? Date() : nil,
            terminalAt: nil, terminalReason: nil, deliveryStatus: "test", peerReady: false,
            createdNew: true, mutationApplied: true, answeredElsewhere: answeredElsewhere,
            incomingCallerName: incomingCallerName
        )
    }
}

@MainActor
private final class CrossUserCallKitMock: CallKitHandling {
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
    var incomingName: String?
    var endedReasons: [CallEndReason] = []
    func startOutgoing(id: UUID) async throws {}
    func reportIncoming(id: UUID) async throws { try await reportIncoming(id: id, callerName: nil) }
    func reportIncoming(id: UUID, callerName: String?) async throws { incomingName = callerName }
    func requestAnswer(id: UUID) async throws {
        guard let handler = onAnswerRequested else { return }
        try await handler(id, Date().addingTimeInterval(10))
    }
    func requestEnd(id: UUID) async throws {
        guard let handler = onEndRequested else { return }
        _ = try await handler(id, Date().addingTimeInterval(10), .appRequested)
    }
    func requestSetMuted(id: UUID, muted: Bool) async throws { try onMutedRequested?(id, muted) }
    func reportOutgoingStartedConnecting(id: UUID) {}
    func reportOutgoingConnected(id: UUID) {}
    func reportEnded(id: UUID, reason: CallEndReason) { endedReasons.append(reason) }
}

private final class CrossUserAudioMock: AudioEngineHandling, @unchecked Sendable {
    var onFrame: (@Sendable (Data) -> Void)?
    var onDiagnostic: (@Sendable (AudioEngineDiagnostic) -> Void)?
    var onFailure: (@Sendable (AudioEngineRuntimeFailure) -> Void)?
    var onMuteChanged: (@Sendable (Bool) -> Void)?
    func ensureRecordPermission() async -> Bool { true }
    func configureSession() throws {}
    func start(muted: Bool) throws {}
    func stop() {}
    func setMuted(_ value: Bool) throws { onMuteChanged?(value) }
    func play(_ payload: Data) {}
}

private final class CrossUserMediaMock: MediaTransport, @unchecked Sendable {
    var onPacket: (@Sendable (AudioPacket, UUID) -> Void)?
    var onDisconnect: (@Sendable (MediaDisconnect) -> Void)?
    var onPeerReady: (@Sendable (UUID, UUID) -> Void)?
    var onDiagnostic: (@Sendable (MediaTransportDiagnostic) -> Void)?
    func connect(callID: UUID, peer: MediaPeerIdentity, token: String) async throws -> UUID { UUID() }
    func send(_ packet: AudioPacket, connectionID: UUID) async throws {}
    func close(connectionID: UUID?) async {}
}
