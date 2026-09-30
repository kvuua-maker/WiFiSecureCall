import Foundation

enum CallEndReason: Sendable { case remoteEnded, failed, unanswered, declined, localEnded }
enum CallEndRequestOrigin: Sendable { case appRequested, system }
enum CallEndDisposition: Sendable { case ended, preserveCall }
enum CallKitCoordinatorError: Error { case missingCoordinator, actionTimedOut, invalidAction }

@MainActor
protocol CallKitHandling: AnyObject {
    var diagnosticInstanceID: UUID { get }
    var onLifecycleDiagnostic: ((String, UUID?) -> Void)? { get set }
    var onPrepareAudio: (() throws -> Void)? { get set }
    var onActionFailed: ((UUID, String, Error) -> Void)? { get set }
    var onStartRequested: ((UUID, Date) async throws -> Void)? { get set }
    var onAnswerRequested: ((UUID, Date) async throws -> Void)? { get set }
    var onEndRequested: ((UUID, Date, CallEndRequestOrigin) async throws -> CallEndDisposition)? { get set }
    var onMutedRequested: ((UUID, Bool) throws -> Void)? { get set }
    var onActionTimedOut: ((UUID, String) -> Void)? { get set }
    var onAudioActivated: ((UUID) -> Void)? { get set }
    var onAudioDeactivated: ((UUID?) -> Void)? { get set }
    var onProviderReset: ((UUID?) -> Void)? { get set }
    func startOutgoing(id: UUID) async throws
    func reportIncoming(id: UUID) async throws
    func reportIncoming(id: UUID, callerName: String?) async throws
    func requestAnswer(id: UUID) async throws
    func requestEnd(id: UUID) async throws
    func requestSetMuted(id: UUID, muted: Bool) async throws
    func reportOutgoingStartedConnecting(id: UUID)
    func reportOutgoingConnected(id: UUID)
    func reportEnded(id: UUID, reason: CallEndReason)
}

extension CallKitHandling {
    func reportIncoming(id: UUID, callerName: String?) async throws {
        try await reportIncoming(id: id)
    }
}

struct AudioSendQueuePolicy { static let maximumFrames = 6 }

struct CallGeneration: Equatable, Sendable {
    let id: UUID
    let serverCallID: UUID
    let localCallKitUUID: UUID
}

private enum DiagnosticUpload: Sendable {
    case runtime(String, String, UUID?, String?, Int?)
    case callKit(String, UUID, NSError)
}
private enum RuntimeEvent: Sendable {
    case packet(AudioPacket, UUID)
    case disconnect(MediaDisconnect)
    case peerReady(UUID, UUID)
    case mediaDiagnostic(MediaTransportDiagnostic)
    case playoutDiagnostic(UUID, AudioPlayoutDiagnostic)
    case sendBackpressure(UUID, UUID)
    case audioDiagnostic(UUID, AudioEngineDiagnostic)
    case audioFailure(UUID, AudioEngineRuntimeFailure)
    case muteChanged(UUID, Bool)
}

private struct TerminalCompensation {
    let mutation: CallMutation
    let requestID: UUID
    let signaling: any CallSignaling
}

@MainActor
final class CallSession: ObservableObject {
    @Published private(set) var state: CallState = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var incomingCallerName: String?
    var isEndToEndEncryptedMedia: Bool {
        activeSignaling?.mediaPeerIdentity.protocolVersion == 2 && callAudioCryptor != nil
    }
    var requiresEndToEndEncryptedMedia: Bool { activeSignaling?.mediaPeerIdentity.protocolVersion == 2 }

    private let api: APIClient
    private let config: AppConfig
    private let audio: AudioEngineHandling
    private let media: MediaTransport
    private let callHistory: CallHistoryStore
    private let diagnostics = Diagnostics.shared
    private var callKit: CallKitHandling?
    private var generation: CallGeneration?
    private var mediaEpoch: UUID?
    private var pendingPeerReadyEpochs: Set<UUID> = []
    private var mediaToken: String?
    private var createRequestID: UUID?
    private var acceptRequestID: UUID?
    private var terminalRequestID: UUID?
    private var terminalMutation: CallMutation?
    private var terminalCompensations: [UUID: TerminalCompensation] = [:]
    private var activeSignaling: (any CallSignaling)?
    private var isOutgoingCall = false
    private var callKitReported = false
    private var activatedCallKitUUID: UUID?
    private var audioStartedForCallKitUUID: UUID?
    private var serverCallCreated = false
    private var serverCallAccepted = false
    private var suppressedSystemEndDuringAcceptance = false
    private var sequence: UInt64 = 0
    private var callAudioCryptor: CallAudioCryptor?
    private var callHistoryRecordID: UUID?
    private let playout = AudioPlayoutController()
    private var tasks: [Task<Void, Never>] = []
    private var mediaConnectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var activationWatchdog: Task<Void, Never>?
    private var peerWatchdog: Task<Void, Never>?
    private var audioFlowWatchdog: Task<Void, Never>?
    private var terminalObserver: Task<Void, Never>?
    private var diagnosticContinuation: AsyncStream<DiagnosticUpload>.Continuation?
    private var diagnosticTask: Task<Void, Never>?
    private var runtimeEventContinuation: AsyncStream<RuntimeEvent>.Continuation?
    private var runtimeEventTask: Task<Void, Never>?
    private var sendStream: AsyncStream<(UUID, UUID, Data)>?
    private var sendContinuation: AsyncStream<(UUID, UUID, Data)>.Continuation?
    private var sendTask: Task<Void, Never>?
    private var firstSentFrameReported = false
    private var firstRemoteFrameReported = false
    private var firstSendFailureReported = false
    private var transportActive = false
    private var audioOperational = false
    private var audioFlow = AudioFlowMilestones()
    private var audioRecoveryBudget = AudioRecoveryBudget()
    private var firstRemoteNonzeroReported = false
    private var firstSentNonzeroReported = false
    private var sendBackpressureDropReported = false
    private(set) var activeCallKitUUID: UUID?

    init(config: AppConfig, api: APIClient? = nil, audio: AudioEngineHandling = AudioEngine(), media: MediaTransport? = nil, callHistory: CallHistoryStore? = nil) {
        self.config = config
        let effectiveAPI = api ?? APIClient(config: config)
        self.api = effectiveAPI
        self.audio = audio
        self.media = media ?? WebSocketMediaTransport(baseURL: config.mediaURL)
        self.callHistory = callHistory ?? .shared
        let runtimeEvents = AsyncStream<RuntimeEvent>(bufferingPolicy: .bufferingNewest(256)) { self.runtimeEventContinuation = $0 }
        let eventContinuation = self.runtimeEventContinuation
        self.media.onPacket = { packet, epoch in eventContinuation?.yield(.packet(packet, epoch)) }
        self.media.onDisconnect = { event in eventContinuation?.yield(.disconnect(event)) }
        self.media.onPeerReady = { callID, epoch in eventContinuation?.yield(.peerReady(callID, epoch)) }
        self.media.onDiagnostic = { event in eventContinuation?.yield(.mediaDiagnostic(event)) }
        self.runtimeEventTask = Task { @MainActor [weak self] in
            for await event in runtimeEvents {
                guard let self else { return }
                switch event {
                case let .packet(packet, epoch): self.receive(packet, mediaEpoch: epoch)
                case let .disconnect(value): self.mediaDisconnected(value)
                case let .peerReady(callID, epoch): self.peerReady(callID: callID, mediaEpoch: epoch)
                case let .mediaDiagnostic(value): self.recordRuntimeDiagnostic(value.event, status: value.status, callID: value.callID, domain: value.errorDomain, code: value.errorCode)
                case let .playoutDiagnostic(generationID, value):
                    guard let current = self.generation, current.id == generationID else { continue }
                    self.recordRuntimeDiagnostic(value.event, status: value.status, callID: current.serverCallID)
                case let .sendBackpressure(generationID, callID):
                    guard let current = self.generation, current.id == generationID, current.serverCallID == callID else { continue }
                    if !self.sendBackpressureDropReported {
                        self.sendBackpressureDropReported = true
                        self.recordRuntimeDiagnostic("audio_send_backpressure_drop", status: "oldest_stale_frame_dropped", callID: callID)
                    }
                case let .audioDiagnostic(generationID, value):
                    guard let current = self.generation, current.id == generationID else { continue }
                    self.observeAudioDiagnostic(value, generation: current)
                    self.recordRuntimeDiagnostic(value.event, status: value.status, callID: current.serverCallID, domain: value.errorDomain, code: value.errorCode)
                case let .audioFailure(generationID, value): if self.generation?.id == generationID { self.audioFailed(value) }
                case let .muteChanged(generationID, value): if self.generation?.id == generationID { self.isMuted = value }
                }
            }
        }
        let uploads = AsyncStream<DiagnosticUpload>(bufferingPolicy: .bufferingNewest(100)) { self.diagnosticContinuation = $0 }
        self.diagnosticTask = Task { [effectiveAPI] in
            for await upload in uploads {
                switch upload {
                case let .runtime(event, status, callID, domain, code):
                    await effectiveAPI.reportRuntimeDiagnostic(event: event, status: status, callID: callID, errorDomain: domain, errorCode: code)
                case let .callKit(stage, callID, error):
                    await effectiveAPI.reportCallKitError(stage: stage, callID: callID, error: error)
                }
            }
        }
    }

    func attach(callKit: CallKitHandling) {
        self.callKit = callKit
        callKit.onLifecycleDiagnostic = { [weak self, weak callKit] event, localID in
            guard let self else { return }
            let current = self.generation
            guard localID == nil || current?.localCallKitUUID == localID else { return }
            let instance = callKit?.diagnosticInstanceID.uuidString ?? "unknown"
            let generation = current?.id.uuidString ?? "none"
            self.recordLifecycleDiagnostic(event, status: "instance=\(instance) generation=\(generation)", callID: current?.serverCallID)
        }
        callKit.onPrepareAudio = { [weak self] in guard let self else { throw CallKitCoordinatorError.missingCoordinator }; try self.audio.configureSession() }
        callKit.onStartRequested = { [weak self] localID, deadline in
            guard let self else { throw CallKitCoordinatorError.missingCoordinator }
            try await self.performStart(localID: localID, deadline: deadline)
        }
        callKit.onAnswerRequested = { [weak self] localID, deadline in
            guard let self else { throw CallKitCoordinatorError.missingCoordinator }
            try await self.performAnswer(localID: localID, deadline: deadline)
        }
        callKit.onEndRequested = { [weak self] localID, deadline, origin in
            guard let self else { throw CallKitCoordinatorError.missingCoordinator }
            return try await self.performEnd(localID: localID, deadline: deadline, origin: origin)
        }
        callKit.onMutedRequested = { [weak self] localID, muted in
            guard let self, self.generation?.localCallKitUUID == localID else { throw CallKitCoordinatorError.invalidAction }
            try self.audio.setMuted(muted)
            self.isMuted = muted
            self.recordRuntimeDiagnostic("mute_state_changed", status: muted ? "muted" : "unmuted", callID: self.generation?.serverCallID)
        }
        callKit.onActionTimedOut = { [weak self] localID, stage in self?.actionTimedOut(localID: localID, stage: stage) }
        callKit.onActionFailed = { [weak self] localID, stage, error in self?.actionFailed(localID: localID, stage: stage, error: error) }
        callKit.onAudioActivated = { [weak self] localID in self?.didActivate(localID: localID) }
        callKit.onAudioDeactivated = { [weak self] localID in self?.didDeactivate(localID: localID) }
        callKit.onProviderReset = { [weak self] localID in self?.providerReset(localID: localID) }
    }

    func startCall() async {
        await startCall(signaling: LegacyCallSignaling(api: api, role: config.role))
    }

    func startCall(signaling: any CallSignaling) async {
        guard await prepareForIndependentCall() else { recordRuntimeDiagnostic("new_call_blocked", status: "busy", callID: state.callID); return }
        guard config.isProductionSafe else { transition(.failed(nil, .serverUnavailable)); return }
        guard case .idle = state else { recordRuntimeDiagnostic("new_call_blocked", status: "permission_race_busy", callID: state.callID); return }
        guard callKit != nil else { transition(.failed(nil, .callKitRejected)); return }
        let serverID = UUID(), localID = distinctLocalCallKitUUID(from: serverID)
        let current = beginGeneration(serverID: serverID, localID: localID, outgoing: true, signaling: signaling)
        transition(.outgoingRinging(serverID))
        let permission = await audio.ensureRecordPermission()
        guard isCurrent(current) else { return }
        recordRuntimeDiagnostic("microphone_permission", status: permission ? "granted" : "denied", callID: serverID)
        guard permission else { await fail(current, .permissionDenied, reportCallKit: false); return }
        recordRuntimeDiagnostic("callkit_start_requested", status: "started generation=\(current.id.uuidString)", callID: serverID)
        do {
            try await callKit?.startOutgoing(id: localID)
            guard isCurrent(current) else { return }
        } catch {
            guard isCurrent(current) else { return }
            recordCallKitError(stage: "startOutgoing", callID: serverID, error: error)
            await fail(current, .callKitRejected, reportCallKit: false)
        }
    }

    func handleIncomingVoIP(callID: UUID) async {
        await handleIncomingVoIP(callID: callID, signaling: LegacyCallSignaling(api: api, role: config.role))
    }

    func handleIncomingVoIP(callID: UUID, signaling: any CallSignaling) async {
        if generation?.serverCallID == callID { return }
        guard await prepareForIndependentCall() else { recordRuntimeDiagnostic("new_call_blocked", status: "incoming_busy", callID: callID); return }
        await reportIncoming(callID: callID, requestAnswer: false, validateBeforeReport: false, signaling: signaling)
    }

    func handleIncoming(callID: UUID, requestAnswer: Bool) async {
        await handleIncoming(callID: callID, requestAnswer: requestAnswer, signaling: LegacyCallSignaling(api: api, role: config.role))
    }

    func handleIncoming(callID: UUID, requestAnswer: Bool, signaling: any CallSignaling) async {
        if generation?.serverCallID == callID {
            if requestAnswer { await accept() }
            return
        }
        guard await prepareForIndependentCall() else { return }
        await reportIncoming(callID: callID, requestAnswer: requestAnswer, validateBeforeReport: true, signaling: signaling)
    }

    private func reportIncoming(callID: UUID, requestAnswer: Bool, validateBeforeReport: Bool, signaling: any CallSignaling) async {
        guard let callKit else { transition(.failed(nil, .callKitRejected)); return }
        if validateBeforeReport {
            do {
                let response = try await signaling.call(callID)
                guard case .idle = state, response.callID == callID, response.localSide == .callee, response.state == .ringing else { return }
            } catch { return }
        }
        let localID = distinctLocalCallKitUUID(from: callID)
        let current = beginGeneration(serverID: callID, localID: localID, outgoing: false, signaling: signaling)
        transition(.incomingRinging(callID))
        let validation: Task<CallSignalView, Error>?
        if validateBeforeReport {
            validation = nil
        } else {
            recordLifecycleDiagnostic("incoming_validation_started", status: "parallel", callID: callID)
            validation = Task { try await signaling.call(callID) }
        }
        do {
            recordLifecycleDiagnostic("incoming_callkit_report_started", status: "prompt", callID: callID)
            try await callKit.reportIncoming(id: localID, callerName: signaling.incomingCallerName)
            guard isCurrent(current) else { return }
            callKitReported = true
            recordRuntimeDiagnostic("incoming_callkit_reported", status: "success", callID: callID)
            if requestAnswer { await accept() }
            if let validation { reconcileIncoming(current, validation: validation) }
            if signaling.requiresIncomingReconciliation, isCurrent(current), case .incomingRinging = state { startIncomingReconciliation(current) }
        } catch {
            validation?.cancel()
            guard isCurrent(current) else { return }
            recordCallKitError(stage: "reportIncoming", callID: callID, error: error)
            await terminalMutationForIncomingFailure(current, signaling: signaling)
            await fail(current, .callKitRejected, reportCallKit: false)
        }
    }

    private func reconcileIncoming(_ current: CallGeneration, validation: Task<CallSignalView, Error>) {
        spawn { [weak self] in
            guard let self else { return }
            do {
                let response = try await validation.value
                guard self.isCurrent(current) else { return }
                self.recordLifecycleDiagnostic("validation_result", status: response.state.rawValue, callID: current.serverCallID)
                if response.answeredElsewhere || response.state != .ringing && response.state != .accepted {
                    self.recordLifecycleDiagnostic("stale_incoming_ended", status: response.state.rawValue, callID: current.serverCallID)
                    await self.remoteTerminal(response, generation: current)
                }
            } catch {
                guard self.isCurrent(current) else { return }
                self.recordRuntimeDiagnostic("incoming_reconcile_failed", status: "transient", callID: current.serverCallID)
            }
        }
    }

    func accept() async {
        guard case .incomingRinging = state, let current = generation else { return }
        do { try await callKit?.requestAnswer(id: current.localCallKitUUID) }
        catch { guard isCurrent(current) else { return }; recordCallKitError(stage: "requestAnswer", callID: current.serverCallID, error: error); await fail(current, .callKitRejected) }
    }

    func reject() async { await endCall() }
    func cancel() async { await endCall() }

    func endCall() async {
        guard let current = generation else { return }
        do { try await callKit?.requestEnd(id: current.localCallKitUUID) }
        catch { guard isCurrent(current) else { return }; recordCallKitError(stage: "requestEnd", callID: current.serverCallID, error: error); _ = try? await performEnd(localID: current.localCallKitUUID, deadline: Date().addingTimeInterval(1), origin: .appRequested) }
    }

    func toggleMute() {
        guard let current = generation else { return }
        spawn { [weak self] in
            guard let self else { return }
            do { try await self.callKit?.requestSetMuted(id: current.localCallKitUUID, muted: !self.isMuted) }
            catch { guard self.isCurrent(current) else { return }; self.recordCallKitError(stage: "requestMute", callID: current.serverCallID, error: error) }
        }
    }

    func reset() { guard state.isTerminal else { return }; invalidateGeneration(); transition(.idle) }

    func failToStart(_ failure: CallFailure) {
        guard case .idle = state else { return }
        transition(.failed(nil, failure))
    }

    private func performStart(localID: UUID, deadline: Date) async throws {
        guard let current = generation, current.localCallKitUUID == localID, case .outgoingRinging = state else { throw CallKitCoordinatorError.invalidAction }
        let callSignaling = try signaling(for: current)
        recordRuntimeDiagnostic("callkit_start_approved", status: "success", callID: current.serverCallID)
        callKit?.reportOutgoingStartedConnecting(id: localID)
        let requestID = createRequestID ?? UUID(); createRequestID = requestID
        let response: CallSignalView
        recordRuntimeDiagnostic("server_call_create_started", status: "started", callID: current.serverCallID)
        do { response = try await callSignaling.create(callID: current.serverCallID, requestID: requestID) }
        catch { guard isCurrent(current) else { throw CancellationError() }; recordRuntimeDiagnostic("server_call_create_failed", status: "failed", callID: current.serverCallID, domain: (error as NSError).domain, code: (error as NSError).code); throw error }
        guard response.callID == current.serverCallID, response.localSide == .caller, response.state == .ringing else {
            throw CallKitCoordinatorError.invalidAction
        }
        guard isCurrent(current) else {
            registerTerminalCompensation(current, mutation: .cancel, signaling: callSignaling, requestID: UUID())
            await deliverTerminalCompensation(current)
            throw CancellationError()
        }
        serverCallCreated = true
        guard Date() < deadline else {
            await compensateAfterStart(current, signaling: callSignaling)
            throw CallKitCoordinatorError.actionTimedOut
        }
        callKitReported = true
        recordRuntimeDiagnostic("server_call_create_succeeded", status: response.createdNew == false ? "reconciled" : "created", callID: current.serverCallID)
        startRingingPoll(current, ringExpiresAt: response.ringExpiresAt ?? response.expiresAt)
    }

    private func performAnswer(localID: UUID, deadline: Date) async throws {
        guard let current = generation, current.localCallKitUUID == localID, case .incomingRinging = state else { throw CallKitCoordinatorError.invalidAction }
        guard await audio.ensureRecordPermission() else { throw CallFailure.permissionDenied }
        guard isCurrent(current), Date() < deadline else { throw CallKitCoordinatorError.actionTimedOut }
        let callSignaling = try signaling(for: current)
        let requestID = acceptRequestID ?? UUID(); acceptRequestID = requestID
        let response: CallSignalView
        do {
            response = try await callSignaling.mutate(.accept, callID: current.serverCallID, requestID: requestID)
        } catch let CallSignalingError.postCommitValidation(callID, state, mutationApplied, _) where callID == current.serverCallID && state == .accepted {
            serverCallAccepted = true
            terminalRequestID = terminalRequestID ?? UUID()
            registerTerminalCompensation(current, mutation: .end, signaling: callSignaling)
            await deliverTerminalCompensation(current)
            recordRuntimeDiagnostic("accepted_media_validation_failed", status: mutationApplied == false ? "reconciled" : "committed", callID: current.serverCallID)
            throw CallFailure.invalidServerState
        }
        guard isCurrent(current) else {
            if response.state == .accepted, !response.answeredElsewhere, response.mediaToken?.isEmpty == false { registerTerminalCompensation(current, mutation: .end, signaling: callSignaling, requestID: UUID()); await deliverTerminalCompensation(current) }
            throw CancellationError()
        }
        if response.answeredElsewhere {
            await teardownLocal(current, finalState: .failed(current.serverCallID, .answeredElsewhere), reportReason: .declined)
            throw CallFailure.answeredElsewhere
        }
        guard Date() < deadline, response.callID == current.serverCallID, response.state == .accepted, let token = response.mediaToken, !token.isEmpty else {
            if response.state == .accepted { await compensateAfterAccept(current, signaling: callSignaling) }
            throw response.state == .expired ? CallFailure.callExpired : CallFailure.invalidServerState
        }
        try configureAcceptedEncryption(response, signaling: callSignaling)
        mediaToken = token
        serverCallAccepted = true
        transition(.connecting(current.serverCallID))
        beginActivationWatchdog(current)
        startTerminalObserver(current)
    }

    private func performEnd(localID: UUID, deadline: Date, origin: CallEndRequestOrigin) async throws -> CallEndDisposition {
        guard let current = generation, current.localCallKitUUID == localID else { throw CallKitCoordinatorError.invalidAction }
        let callSignaling = try signaling(for: current)
        let originStatus = origin == .appRequested ? "appRequested" : "system"
        recordRuntimeDiagnostic("callkit_end_action_received", status: "origin=\(originStatus) state=\(String(describing: state))", callID: current.serverCallID)

        if origin == .system, config.role == .B, isOutgoingCall {
            if suppressedSystemEndDuringAcceptance, serverCallAccepted,
               case .connecting = state, !transportActive {
                recordRuntimeDiagnostic("system_end_duplicate_preserved_during_connecting", status: "preserved", callID: current.serverCallID)
                return .preserveCall
            }
            if case .outgoingRinging = state {
                recordRuntimeDiagnostic("system_end_reconcile_started", status: "started", callID: current.serverCallID)
                do {
                    let response = try await callSignaling.call(current.serverCallID)
                    guard isCurrent(current), response.callID == current.serverCallID else { throw CancellationError() }
                    switch response.state {
                    case .accepted:
                        guard let token = response.mediaToken, !token.isEmpty else {
                            recordRuntimeDiagnostic("system_end_reconcile_result", status: "failed", callID: current.serverCallID)
                            break
                        }
                        try configureAcceptedEncryption(response, signaling: callSignaling)
                        recordRuntimeDiagnostic("system_end_reconcile_result", status: "accepted", callID: current.serverCallID)
                        mediaToken = token
                        serverCallAccepted = true
                        suppressedSystemEndDuringAcceptance = true
                        transition(.connecting(current.serverCallID))
                        beginActivationWatchdog(current)
                        startTerminalObserver(current)
                        startMediaIfReady(current)
                        recordRuntimeDiagnostic("system_end_preserved_after_remote_accept", status: "accepted", callID: current.serverCallID)
                        return .preserveCall
                    case .ringing:
                        recordRuntimeDiagnostic("system_end_reconcile_result", status: "ringing", callID: current.serverCallID)
                    case .rejected, .cancelled, .expired, .ended:
                        recordRuntimeDiagnostic("system_end_reconcile_result", status: "terminal", callID: current.serverCallID)
                        await remoteTerminal(response, generation: current)
                        return .ended
                    }
                } catch {
                    guard isCurrent(current) else { throw error }
                    recordRuntimeDiagnostic("system_end_reconcile_result", status: "failed", callID: current.serverCallID, domain: (error as NSError).domain, code: (error as NSError).code)
                }
            }
        }

        suppressedSystemEndDuringAcceptance = false
        let mutation = terminalMutationForCurrentState()
        terminalMutation = mutation
        terminalRequestID = terminalRequestID ?? UUID()
        registerTerminalCompensation(current, mutation: mutation, signaling: callSignaling)
        await teardownLocal(current, finalState: .ended(current.serverCallID), reportReason: nil)
        guard Date() < deadline else { enqueueTerminalMutation(current, mutation: mutation); return .ended }
        enqueueTerminalMutation(current, mutation: mutation)
        return .ended
    }

    private func actionTimedOut(localID: UUID, stage: String) {
        guard let current = generation, current.localCallKitUUID == localID else { return }
        recordRuntimeDiagnostic("callkit_action_timeout", status: stage, callID: current.serverCallID)
        spawn { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            guard let callSignaling = try? self.signaling(for: current) else { return }
            if stage.contains("Start") || stage.lowercased().contains("start") { await self.compensateAfterStart(current, signaling: callSignaling) }
            else if stage.contains("Answer") || stage.lowercased().contains("answer") {
                if self.serverCallAccepted { await self.compensateAfterAccept(current, signaling: callSignaling) }
                else { await self.terminalMutationForIncomingFailure(current, signaling: callSignaling) }
            }
            await self.fail(current, .callKitRejected, reportCallKit: false)
        }
    }

    private func actionFailed(localID: UUID, stage: String, error: Error) {
        guard let current = generation, current.localCallKitUUID == localID else { return }
        recordCallKitError(stage: stage, callID: current.serverCallID, error: error)
        if stage == "mute" { return }
        spawn { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            guard let callSignaling = try? self.signaling(for: current) else { return }
            if stage == "start" && self.serverCallCreated { await self.compensateAfterStart(current, signaling: callSignaling) }
            if stage == "answer" {
                if self.serverCallAccepted { await self.compensateAfterAccept(current, signaling: callSignaling) }
                else { await self.terminalMutationForIncomingFailure(current, signaling: callSignaling) }
            }
            let failure = stage == "start" ? (error as? CallFailure ?? .callKitRejected) : .callKitRejected
            await self.fail(current, failure, reportCallKit: self.callKitReported)
        }
    }

    private func didActivate(localID: UUID) {
        guard let current = generation, current.localCallKitUUID == localID else { return }
        activatedCallKitUUID = localID
        recordRuntimeDiagnostic("callkit_did_activate", status: "success", callID: current.serverCallID)
        startMediaIfReady(current)
    }

    private func didDeactivate(localID: UUID?) {
        guard let current = generation, localID == nil || current.localCallKitUUID == localID else { return }
        activatedCallKitUUID = nil
        audioStartedForCallKitUUID = nil
        playout.stop()
        audioFlowWatchdog?.cancel(); audioFlowWatchdog = nil
        audioFlow = AudioFlowMilestones(); audioOperational = false
        audio.stop()
        recordRuntimeDiagnostic("callkit_did_deactivate", status: "success", callID: current.serverCallID)
    }

    private func providerReset(localID: UUID?) {
        guard let current = generation, localID == nil || current.localCallKitUUID == localID else { return }
        guard let callSignaling = try? signaling(for: current) else { return }
        let mutation = terminalMutationForCurrentState()
        let requestID = terminalRequestID ?? UUID(); terminalRequestID = requestID
        registerTerminalCompensation(current, mutation: mutation, signaling: callSignaling, requestID: requestID)
        enqueueTerminalMutation(current, mutation: mutation)
        spawn { [weak self] in guard let self, self.isCurrent(current) else { return }; await self.teardownLocal(current, finalState: .failed(current.serverCallID, .callKitRejected), reportReason: nil) }
    }

    private func startRingingPoll(_ current: CallGeneration, ringExpiresAt: Date) {
        spawn { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isCurrent(current), Date() < ringExpiresAt {
                do {
                    let response = try await self.signaling(for: current).call(current.serverCallID)
                    guard self.isCurrent(current), response.callID == current.serverCallID else { return }
                    switch response.state {
                    case .accepted:
                        guard let token = response.mediaToken, !token.isEmpty else { await self.fail(current, .invalidServerState); return }
                        do { try self.configureAcceptedEncryption(response, signaling: try self.signaling(for: current)) }
                        catch { await self.fail(current, .invalidServerState); return }
                        self.mediaToken = token; self.serverCallAccepted = true; self.transition(.connecting(current.serverCallID)); self.beginActivationWatchdog(current); self.startTerminalObserver(current); return
                    case .ringing: break
                    default: await self.remoteTerminal(response, generation: current); return
                    }
                } catch { self.recordRuntimeDiagnostic("call_state_poll_failure", status: "transient", callID: current.serverCallID, domain: (error as NSError).domain, code: (error as NSError).code) }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
            guard self.isCurrent(current) else { return }
            do { let response = try await self.signaling(for: current).call(current.serverCallID); guard self.isCurrent(current) else { return }; await self.remoteTerminal(response, generation: current) }
            catch { await self.fail(current, .serverUnavailable) }
        }
    }

    private func beginActivationWatchdog(_ current: CallGeneration) {
        activationWatchdog?.cancel()
        if activatedCallKitUUID == current.localCallKitUUID { startMediaIfReady(current); return }
        activationWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(CallTimeouts.audioActivation * 1_000_000_000)) } catch { return }
            guard let self, self.isCurrent(current), self.audioStartedForCallKitUUID == nil else { return }
            await self.fail(current, .audioActivationTimeout)
        }
    }

    private func startMediaIfReady(_ current: CallGeneration) {
        guard isCurrent(current), activatedCallKitUUID == current.localCallKitUUID,
              audioStartedForCallKitUUID != current.localCallKitUUID,
              state.callID == current.serverCallID, let token = mediaToken,
              state.isMediaEstablishing else { return }
        activationWatchdog?.cancel()
        audioStartedForCallKitUUID = current.localCallKitUUID
        configureFramePump(current)
        mediaConnectTask?.cancel()
        mediaConnectTask = Task { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            do {
                try self.audio.start(muted: self.isMuted)
                guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID else { return }
                if let existingEpoch = self.mediaEpoch {
                    self.startPlayout(current, mediaEpoch: existingEpoch)
                    if self.transportActive { self.beginAudioFlowWatchdog(current) }
                    return
                }
                let epoch = try await self.media.connect(callID: current.serverCallID, peer: try self.signaling(for: current).mediaPeerIdentity, token: token)
                guard self.isCurrent(current) else { await self.media.close(connectionID: epoch); return }
                self.mediaEpoch = epoch
                self.startPlayout(current, mediaEpoch: epoch)
                if self.pendingPeerReadyEpochs.remove(epoch) != nil { self.peerReady(callID: current.serverCallID, mediaEpoch: epoch) }
                else { self.beginPeerWatchdog(current, mediaEpoch: epoch) }
            } catch {
                guard self.isCurrent(current) else { return }
                await self.fail(current, (error as? CallFailure) == .audioFailed ? .audioFailed : .mediaConnectionFailed)
            }
        }
    }

    private func peerReady(callID: UUID, mediaEpoch: UUID) {
        guard let current = generation, current.serverCallID == callID else { return }
        guard self.mediaEpoch == mediaEpoch else {
            if self.mediaEpoch == nil { pendingPeerReadyEpochs.insert(mediaEpoch) }
            return
        }
        peerWatchdog?.cancel()
        transportActive = true
        suppressedSystemEndDuringAcceptance = false
        if state != .active(callID) { transition(.active(callID)); startDuration(current); if isOutgoingCall { callKit?.reportOutgoingConnected(id: current.localCallKitUUID) } }
        recordRuntimeDiagnostic("media_peer_ready", status: "ready", callID: callID)
        beginAudioFlowWatchdog(current)
    }

    private func beginPeerWatchdog(_ current: CallGeneration, mediaEpoch: UUID) {
        peerWatchdog?.cancel()
        peerWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, self.isCurrent(current), self.mediaEpoch == mediaEpoch, self.state != .active(current.serverCallID) else { return }
            await self.media.close(connectionID: mediaEpoch)
            self.mediaDisconnected(.init(callID: current.serverCallID, connectionID: mediaEpoch, closeCode: nil, reason: .peerUnavailable))
        }
    }

    private func mediaDisconnected(_ event: MediaDisconnect) {
        guard let current = generation, current.serverCallID == event.callID, mediaEpoch == event.connectionID, state.isAcceptedLifecycle, let token = mediaToken else { return }
        mediaEpoch = nil; transportActive = false; audioOperational = false; audioFlowWatchdog?.cancel(); playout.stop()
        if event.reason == .authFailed || event.reason == .protocolViolation {
            spawn { [weak self] in guard let self, self.isCurrent(current) else { return }; await self.fail(current, .invalidServerState) }
            return
        }
        if event.reason == .remoteClosed {
            spawn { [weak self] in
                guard let self, self.isCurrent(current) else { return }
                do { await self.remoteTerminal(try await self.signaling(for: current).call(current.serverCallID), generation: current) }
                catch { await self.fail(current, .networkLost) }
            }
            return
        }
        transition(.reconnecting(current.serverCallID))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + CallTimeouts.reconnectTotal; var delay = 0.25
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard self.isCurrent(current) else { return }
                do {
                    let epoch = try await self.media.connect(callID: current.serverCallID, peer: try self.signaling(for: current).mediaPeerIdentity, token: token)
                    guard self.isCurrent(current) else { await self.media.close(connectionID: epoch); return }
                    self.mediaEpoch = epoch; self.startPlayout(current, mediaEpoch: epoch)
                    if self.pendingPeerReadyEpochs.remove(epoch) != nil { self.peerReady(callID: current.serverCallID, mediaEpoch: epoch) }
                    else { self.beginPeerWatchdog(current, mediaEpoch: epoch) }
                    return
                } catch { delay = min(delay * 2, 2) }
            }
            guard self.isCurrent(current) else { return }
            await self.fail(current, .networkLost)
        }
    }

    private func configureFramePump(_ current: CallGeneration) {
        sendTask?.cancel(); sendContinuation?.finish()
        let stream = AsyncStream<(UUID, UUID, Data)>(bufferingPolicy: .bufferingNewest(AudioSendQueuePolicy.maximumFrames)) { continuation in self.sendContinuation = continuation }
        sendStream = stream
        let frameContinuation = sendContinuation
        let events = runtimeEventContinuation
        audio.onFrame = { data in
            if case .dropped = frameContinuation?.yield((current.id, current.serverCallID, data)) {
                events?.yield(.sendBackpressure(current.id, current.serverCallID))
            }
        }
        sendTask = Task { [weak self] in
            guard let self else { return }
            for await (generationID, callID, data) in stream {
                guard let active = self.generation, active.id == generationID, active.serverCallID == callID, let epoch = self.mediaEpoch else { continue }
                self.sequence &+= 1
                let packet: AudioPacket
                do {
                    if let cryptor = self.callAudioCryptor {
                        packet = try cryptor.encrypt(data, sequence: self.sequence, timestampMicroseconds: self.sequence &* 20_000)
                    } else {
                        packet = AudioPacket(type: .audio, callID: callID, sequence: self.sequence, timestampMicroseconds: self.sequence &* 20_000, payload: data)
                    }
                } catch {
                    self.mediaDisconnected(.init(callID: callID, connectionID: epoch, closeCode: nil, reason: .protocolViolation))
                    continue
                }
                do {
                    try await self.media.send(packet, connectionID: epoch)
                    guard self.generation?.id == generationID else { continue }
                    self.audioFlow.networkFrameSent = true
                    self.updateAudioOperational()
                    if !self.firstSentFrameReported {
                        self.firstSentFrameReported = true
                        let metrics = AudioEngine.signalMetrics(forCanonicalPCM: data)
                        self.recordRuntimeDiagnostic("first_network_audio_frame_sent", status: "bytes=\(data.count) rms=\(metrics?.rms ?? 0) peak=\(metrics?.peak ?? 0) nonzero=\(metrics?.nonzeroCount ?? 0)", callID: callID)
                    }
                    if !self.firstSentNonzeroReported, let metrics = AudioEngine.signalMetrics(forCanonicalPCM: data), metrics.hasNonzeroSignal {
                        self.firstSentNonzeroReported = true
                        self.recordRuntimeDiagnostic("first_network_audio_nonzero_sent", status: "rms=\(metrics.rms) peak=\(metrics.peak) nonzero=\(metrics.nonzeroCount)", callID: callID)
                    }
                } catch {
                    guard self.generation?.id == generationID else { continue }
                    if !self.firstSendFailureReported { self.firstSendFailureReported = true; self.recordRuntimeDiagnostic("first_network_audio_frame_send_failure", status: "failed", callID: callID, domain: (error as NSError).domain, code: (error as NSError).code) }
                    self.mediaDisconnected(.init(callID: callID, connectionID: epoch, closeCode: nil, reason: .sendFailed))
                }
            }
        }
    }

    private func receive(_ receivedPacket: AudioPacket, mediaEpoch: UUID) {
        guard let current = generation, receivedPacket.callID == current.serverCallID, self.mediaEpoch == mediaEpoch, receivedPacket.type == .audio else { return }
        let packet: AudioPacket
        do {
            if let cryptor = callAudioCryptor { packet = try cryptor.decrypt(receivedPacket) }
            else { guard receivedPacket.protocolVersion == AudioPacket.legacyVersion else { return }; packet = receivedPacket }
        } catch { return }
        guard packet.payload.count == AudioEngine.bytesPerFrame else { return }
        audioFlow.remoteFrameReceived = true
        updateAudioOperational()
        let metrics = AudioEngine.signalMetrics(forCanonicalPCM: packet.payload)
        if let metrics, metrics.hasNonzeroSignal {
            if !firstRemoteNonzeroReported {
                firstRemoteNonzeroReported = true
                recordRuntimeDiagnostic("first_remote_audio_nonzero", status: "sequence=\(packet.sequence) bytes=\(packet.payload.count) rms=\(metrics.rms) peak=\(metrics.peak) nonzero=\(metrics.nonzeroCount)", callID: packet.callID)
            }
            updateAudioOperational()
        }
        if !firstRemoteFrameReported {
            firstRemoteFrameReported = true
            recordRuntimeDiagnostic("first_remote_audio_frame_received", status: "sequence=\(packet.sequence) bytes=\(packet.payload.count) rms=\(metrics?.rms ?? 0) peak=\(metrics?.peak ?? 0) nonzero=\(metrics?.nonzeroCount ?? 0)", callID: packet.callID)
        }
        playout.insert(packet)
    }

    private func startPlayout(_ current: CallGeneration, mediaEpoch: UUID) {
        let audio = self.audio
        let events = runtimeEventContinuation
        playout.start(
            onFrame: { payload in audio.play(payload) },
            onDiagnostic: { value in events?.yield(.playoutDiagnostic(current.id, value)) }
        )
    }

    private func startIncomingReconciliation(_ current: CallGeneration) {
        spawn { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isCurrent(current), case .incomingRinging = self.state {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard self.isCurrent(current), case .incomingRinging = self.state else { return }
                do {
                    let response = try await self.signaling(for: current).call(current.serverCallID)
                    guard self.isCurrent(current) else { return }
                    if response.answeredElsewhere || response.state != .ringing {
                        await self.remoteTerminal(response, generation: current)
                        return
                    }
                } catch {
                    self.recordRuntimeDiagnostic("incoming_reconcile_failed", status: "transient", callID: current.serverCallID)
                }
            }
        }
    }

    private func startTerminalObserver(_ current: CallGeneration) {
        terminalObserver?.cancel()
        terminalObserver = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isCurrent(current) {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard self.isCurrent(current) else { return }
                do { let response = try await self.signaling(for: current).call(current.serverCallID); guard self.isCurrent(current) else { return }; if response.state != .accepted { await self.remoteTerminal(response, generation: current); return } }
                catch { self.recordRuntimeDiagnostic("terminal_observer_failure", status: "transient", callID: current.serverCallID) }
            }
        }
    }

    private func remoteTerminal(_ response: CallSignalView, generation current: CallGeneration) async {
        guard isCurrent(current), response.callID == current.serverCallID else { return }
        if response.answeredElsewhere {
            await teardownLocal(current, finalState: .failed(current.serverCallID, .answeredElsewhere), reportReason: .declined)
            return
        }
        let failure: CallFailure?
        let reason: CallEndReason
        switch response.state {
        case .rejected: failure = .callRejected; reason = .declined
        case .cancelled: failure = .callCancelled; reason = .remoteEnded
        case .expired: failure = .callExpired; reason = .unanswered
        case .ended: failure = nil; reason = .remoteEnded
        default: return
        }
        if let failure { await fail(current, failure, reportReason: reason) }
        else { await teardownLocal(current, finalState: .ended(current.serverCallID), reportReason: reason) }
    }

    private func audioFailed(_ failure: AudioEngineRuntimeFailure) {
        guard let current = generation, state.isAcceptedLifecycle else { return }
        if activatedCallKitUUID == current.localCallKitUUID, audioRecoveryBudget.claim() {
            recordRuntimeDiagnostic("audio_watchdog_recovery_started", status: "runtime_failure=\(String(describing: failure))", callID: current.serverCallID)
            recoverAudioOnly(current)
        } else {
            recordRuntimeDiagnostic("audio_watchdog_degraded_but_call_preserved", status: "runtime_failure=\(String(describing: failure))", callID: current.serverCallID)
        }
    }

    private func observeAudioDiagnostic(_ value: AudioEngineDiagnostic, generation current: CallGeneration) {
        guard isCurrent(current) else { return }
        switch value.event {
        case "first_mic_callback", "first_mic_buffer": audioFlow.micCallback = true
        case "first_network_pcm_generated", "first_network_audio_frame_generated": audioFlow.networkPCMGenerated = true
        case "first_playback_buffer_scheduled": audioFlow.playbackScheduled = true
        case "first_playback_buffer_rendered": audioFlow.playbackRendered = true
        default: break
        }
        updateAudioOperational()
    }

    private func updateAudioOperational() {
        let wasOperational = audioOperational
        audioOperational = audioFlow.isOperational(transportActive: transportActive)
        if audioOperational, !wasOperational, let callID = generation?.serverCallID {
            recordRuntimeDiagnostic("audio_operational", status: "transport=ready audio=ready", callID: callID)
            audioFlowWatchdog?.cancel()
        }
    }

    private func beginAudioFlowWatchdog(_ current: CallGeneration) {
        audioFlowWatchdog?.cancel()
        audioFlowWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, self.isCurrent(current), self.transportActive, !self.audioOperational else { return }
            guard let stage = self.audioFlow.failureStage else { self.updateAudioOperational(); return }
            self.recordRuntimeDiagnostic("audio_flow_watchdog", status: stage.rawValue, callID: current.serverCallID)
            let recoveryAvailable = AudioWatchdogPolicy.action(for: stage, recoveryAvailable: !self.audioRecoveryBudget.used) == .recover
            if recoveryAvailable, self.audioRecoveryBudget.claim() {
                self.recordRuntimeDiagnostic("audio_watchdog_recovery_started", status: stage.rawValue, callID: current.serverCallID)
                self.recoverAudioOnly(current)
            } else {
                self.recordRuntimeDiagnostic("audio_watchdog_degraded_but_call_preserved", status: stage.rawValue, callID: current.serverCallID)
            }
        }
    }

    private func recoverAudioOnly(_ current: CallGeneration) {
        guard isCurrent(current), activatedCallKitUUID == current.localCallKitUUID else { return }
        playout.stop()
        audio.stop()
        audioFlow = AudioFlowMilestones()
        audioOperational = false
        do {
            try audio.start(muted: isMuted)
            guard isCurrent(current), activatedCallKitUUID == current.localCallKitUUID else { audio.stop(); return }
            audioStartedForCallKitUUID = current.localCallKitUUID
            if let epoch = mediaEpoch { startPlayout(current, mediaEpoch: epoch) }
            recordRuntimeDiagnostic("audio_watchdog_recovery_succeeded", status: "audio_graph_restarted", callID: current.serverCallID)
            if transportActive { beginAudioFlowWatchdog(current) }
        } catch {
            recordRuntimeDiagnostic("audio_recovery", status: "failed", callID: current.serverCallID, domain: (error as NSError).domain, code: (error as NSError).code)
            spawn { [weak self] in guard let self else { return }; await self.fail(current, .audioFailed) }
        }
    }

    private func compensateAfterStart(_ current: CallGeneration, signaling: any CallSignaling) async {
        guard isCurrent(current), serverCallCreated else { return }
        terminalRequestID = terminalRequestID ?? UUID(); registerTerminalCompensation(current, mutation: .cancel, signaling: signaling); await deliverTerminalCompensation(current)
    }
    private func compensateAfterAccept(_ current: CallGeneration, signaling: any CallSignaling) async {
        guard isCurrent(current) else { return }
        terminalRequestID = terminalRequestID ?? UUID(); registerTerminalCompensation(current, mutation: .end, signaling: signaling); await deliverTerminalCompensation(current)
    }
    private func terminalMutationForIncomingFailure(_ current: CallGeneration, signaling: any CallSignaling) async { terminalRequestID = terminalRequestID ?? UUID(); registerTerminalCompensation(current, mutation: .reject, signaling: signaling); await deliverTerminalCompensation(current) }

    private func terminalMutationForCurrentState() -> CallMutation {
        switch state { case .outgoingRinging: return .cancel; case .incomingRinging: return .reject; default: return .end }
    }

    private func enqueueTerminalMutation(_ current: CallGeneration, mutation: CallMutation) {
        guard terminalCompensations[current.id]?.mutation == mutation else { return }
        Task { @MainActor [weak self] in await self?.deliverTerminalCompensation(current) }
    }

    private func registerTerminalCompensation(_ current: CallGeneration, mutation: CallMutation, signaling: any CallSignaling, requestID: UUID? = nil) {
        if let retained = terminalCompensations[current.id] {
            terminalCompensations[current.id] = TerminalCompensation(mutation: mutation, requestID: requestID ?? retained.requestID, signaling: retained.signaling)
            return
        }
        if terminalCompensations.count >= 8, let oldest = terminalCompensations.keys.first { terminalCompensations.removeValue(forKey: oldest) }
        terminalCompensations[current.id] = TerminalCompensation(mutation: mutation, requestID: requestID ?? terminalRequestID ?? UUID(), signaling: signaling)
    }

    private func deliverTerminalCompensation(_ current: CallGeneration) async {
        guard let retained = terminalCompensations[current.id] else { return }
        for delay: UInt64 in [0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000] {
            if delay > 0 { do { try await Task.sleep(nanoseconds: delay) } catch { return } }
            guard terminalCompensations[current.id]?.mutation == retained.mutation, terminalCompensations[current.id]?.requestID == retained.requestID else { return }
            do {
                _ = try await retained.signaling.mutate(retained.mutation, callID: current.serverCallID, requestID: retained.requestID)
                terminalCompensations.removeValue(forKey: current.id)
                return
            } catch { continue }
        }
        recordRuntimeDiagnostic("terminal_mutation_failed", status: retained.mutation.rawValue, callID: current.serverCallID)
    }

    private func fail(_ current: CallGeneration, _ failure: CallFailure, reportCallKit: Bool = true, reportReason: CallEndReason = .failed) async {
        guard isCurrent(current) else { return }
        if state.isAcceptedLifecycle, let callSignaling = try? signaling(for: current) {
            registerTerminalCompensation(current, mutation: .end, signaling: callSignaling)
            enqueueTerminalMutation(current, mutation: .end)
        }
        await teardownLocal(current, finalState: .failed(current.serverCallID, failure), reportReason: reportCallKit ? reportReason : nil)
    }

    private func teardownLocal(_ current: CallGeneration, finalState: CallState, reportReason: CallEndReason?) async {
        guard isCurrent(current) else { return }
        cancelCallTasks()
        let epoch = mediaEpoch; mediaEpoch = nil; pendingPeerReadyEpochs.removeAll(keepingCapacity: false)
        playout.stop(); audio.stop(); isMuted = false; audioStartedForCallKitUUID = nil; activatedCallKitUUID = nil; transportActive = false; audioOperational = false
        if let epoch { await media.close(connectionID: epoch) }
        guard isCurrent(current) else { return }
        if let reportReason, callKitReported || isOutgoingCall { callKit?.reportEnded(id: current.localCallKitUUID, reason: reportReason) }
        if case .ended(let id) = finalState {
            if state != .ending(id) { transition(.ending(id)) }
            transition(.ended(id))
        } else {
            transition(finalState)
        }
        finishCallHistory(finalState: finalState)
        invalidateGeneration(expected: current)
    }

    private func prepareForIndependentCall() async -> Bool {
        if state.isTerminal { invalidateGeneration(); transition(.idle) }
        guard case .idle = state else { return false }
        return true
    }

    @discardableResult private func beginGeneration(serverID: UUID, localID: UUID, outgoing: Bool, signaling: any CallSignaling) -> CallGeneration {
        cancelCallTasks(); audio.stop()
        let next = CallGeneration(id: UUID(), serverCallID: serverID, localCallKitUUID: localID)
        generation = next; activeSignaling = signaling; activeCallKitUUID = localID; isOutgoingCall = outgoing; callKitReported = false; incomingCallerName = outgoing ? nil : signaling.incomingCallerName
        callHistoryRecordID = callHistory.begin(
            accountID: signaling.historyAccountID,
            logicalCallID: serverID,
            direction: outgoing ? .outgoing : .incoming,
            peerDisplayName: signaling.historyPeerDisplayName,
            targetUserID: signaling.historyTargetUserID
        )
        let events = runtimeEventContinuation
        audio.onDiagnostic = { value in events?.yield(.audioDiagnostic(next.id, value)) }
        audio.onFailure = { value in events?.yield(.audioFailure(next.id, value)) }
        audio.onMuteChanged = { value in events?.yield(.muteChanged(next.id, value)) }
        callAudioCryptor?.erase(); callAudioCryptor = nil
        mediaToken = nil; mediaEpoch = nil; pendingPeerReadyEpochs.removeAll(keepingCapacity: false); createRequestID = nil; acceptRequestID = nil; terminalRequestID = nil; terminalMutation = nil
        activatedCallKitUUID = nil; audioStartedForCallKitUUID = nil; serverCallCreated = false; serverCallAccepted = false; suppressedSystemEndDuringAcceptance = false; sequence = 0; isMuted = false; elapsedSeconds = 0
        firstSentFrameReported = false; firstRemoteFrameReported = false; firstSendFailureReported = false
        transportActive = false; audioOperational = false; audioFlow = AudioFlowMilestones(); audioRecoveryBudget = AudioRecoveryBudget()
        firstRemoteNonzeroReported = false; firstSentNonzeroReported = false; sendBackpressureDropReported = false
        return next
    }

    private func invalidateGeneration(expected: CallGeneration? = nil) {
        if let expected, generation != expected { return }
        cancelCallTasks(); sendContinuation?.finish(); sendContinuation = nil; sendStream = nil; sendTask?.cancel(); sendTask = nil
        activeSignaling?.eraseSecrets(); callAudioCryptor?.erase(); callAudioCryptor = nil
        generation = nil; activeSignaling = nil; activeCallKitUUID = nil; mediaEpoch = nil; mediaToken = nil; isOutgoingCall = false; callKitReported = false; incomingCallerName = nil; suppressedSystemEndDuringAcceptance = false
        callHistoryRecordID = nil
    }

    private func configureAcceptedEncryption(_ response: CallSignalView, signaling: any CallSignaling) throws {
        if signaling.mediaPeerIdentity.protocolVersion == 2 {
            guard let keys = response.audioKeys else { throw CallFailure.invalidServerState }
            callAudioCryptor?.erase()
            callAudioCryptor = CallAudioCryptor(callID: response.callID, keys: keys)
        } else {
            callAudioCryptor?.erase()
            callAudioCryptor = nil
        }
    }

    private func cancelCallTasks() {
        for task in tasks { task.cancel() }; tasks.removeAll(keepingCapacity: true)
        mediaConnectTask?.cancel(); reconnectTask?.cancel(); durationTask?.cancel(); activationWatchdog?.cancel(); peerWatchdog?.cancel(); audioFlowWatchdog?.cancel(); terminalObserver?.cancel()
        playout.stop()
        mediaConnectTask = nil; reconnectTask = nil; durationTask = nil; activationWatchdog = nil; peerWatchdog = nil; audioFlowWatchdog = nil; terminalObserver = nil
    }

    private func startDuration(_ current: CallGeneration) {
        durationTask?.cancel(); elapsedSeconds = 0
        durationTask = Task { [weak self] in while !Task.isCancelled { do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }; guard let self, self.isCurrent(current) else { return }; self.elapsedSeconds += 1 } }
    }

    private func transition(_ next: CallState) {
        guard CallStateTransition.isLegal(from: state, to: next), state.callID == nil || next.callID == nil || state.callID == next.callID else {
            recordRuntimeDiagnostic("illegal_state_transition", status: "from=\(String(describing: state)) to=\(String(describing: next))", callID: state.callID)
            return
        }
        diagnostics.record(role: config.role, callID: next.callID, category: "state", value: String(describing: next)); state = next
        if case .active = next, let callHistoryRecordID { callHistory.markActive(callHistoryRecordID) }
    }

    private func finishCallHistory(finalState: CallState) {
        guard let callHistoryRecordID else { return }
        let terminal: CallHistoryStatus
        switch finalState {
        case let .failed(_, failure):
            switch failure {
            case .callRejected: terminal = .rejected
            case .callExpired, .callCancelled, .answeredElsewhere:
                terminal = isOutgoingCall ? .failed : .missed
            default: terminal = .failed
            }
        case .ended:
            terminal = isOutgoingCall ? .failed : .rejected
        default:
            terminal = .failed
        }
        callHistory.finish(callHistoryRecordID, status: terminal)
    }

    private func isCurrent(_ current: CallGeneration) -> Bool { generation == current }
    private func signaling(for current: CallGeneration) throws -> any CallSignaling {
        guard generation == current, let activeSignaling else { throw CancellationError() }
        return activeSignaling
    }
    private func distinctLocalCallKitUUID(from server: UUID) -> UUID { var value = UUID(); while value == server { value = UUID() }; return value }
    private func spawn(_ operation: @escaping @MainActor () async -> Void) { let task = Task { @MainActor in await operation() }; tasks.append(task) }
    private func recordCallKitError(stage: String, callID: UUID, error: Error) { let value = error as NSError; diagnostics.record(role: config.role, callID: callID, category: "callKitError", value: "stage=\(stage) domain=\(value.domain) code=\(value.code)"); diagnosticContinuation?.yield(.callKit(stage, callID, value)) }
    func recordLifecycleDiagnostic(_ event: String, status: String, callID: UUID?) {
        diagnostics.record(role: config.role, callID: callID, category: event, value: status)
        let serverEvent: String
        switch event {
        case "callkit_provider_created", "start_transaction_submitted": serverEvent = "callkit_start_requested"
        case "start_transaction_accepted", "provider_perform_start_received", "start_action_fulfilled": serverEvent = "callkit_start_approved"
        case "start_action_timed_out", "provider_reset": serverEvent = "callkit_action_timeout"
        case "push_received", "incoming_validation_started", "incoming_callkit_report_started", "validation_result", "stale_incoming_ended": serverEvent = "incoming_callkit_reported"
        default: serverEvent = event
        }
        diagnosticContinuation?.yield(.runtime(serverEvent, "\(event) \(status)", callID, nil, nil))
    }
    private func recordRuntimeDiagnostic(_ event: String, status: String, callID: UUID?, domain: String? = nil, code: Int? = nil) { diagnostics.record(role: config.role, callID: callID, category: event, value: status); diagnosticContinuation?.yield(.runtime(event, status, callID, domain, code)) }
}

private extension CallState {
    var isAcceptedLifecycle: Bool { switch self { case .connecting, .active, .reconnecting: return true; default: return false } }
    var isMediaEstablishing: Bool { switch self { case .connecting, .reconnecting, .active: return true; default: return false } }
}
