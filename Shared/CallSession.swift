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

private struct AuthoritativeTerminalCall: Error {
    let response: CallSignalView
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
    var activeAccountID: UUID? { activeSignaling?.historyAccountID }

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
    private var terminalDeliveriesInProgress: Set<UUID> = []
    private var explicitUserEndRequested = false
    private var explicitUserEndRequestID: UUID?
    private var explicitUserEndRequestedAt: Date?
    private var explicitUserEndServerCallID: UUID?
    private var activeSignaling: (any CallSignaling)?
    private var isOutgoingCall = false
    private var callKitReported = false
    private var activatedCallKitUUID: UUID?
    private var audioStartedForCallKitUUID: UUID?
    private var callKitActivationEpoch: UInt64 = 0
    private var hasEverActivatedCallKitAudio = false
    private var awaitingCallKitReactivation = false
    private var callKitReactivationTask: Task<Void, Never>?
    private var callKitContinuationAttempted = false
    private var continuationCallKitUUID: UUID?
    private var outgoingConnectedReported = false
    private var serverCallCreated = false
    private var serverCallAccepted = false
    private var suppressedSystemEndDuringAcceptance = false
    private var acceptanceSystemEndProtectionDeadline: Date?
    private var systemEndReconciliationInProgress = false
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
    private var audioRecoveryTask: Task<Void, Never>?
    private var audioRecoverySettleTask: Task<Void, Never>?
    private var terminalObserver: Task<Void, Never>?
    private var ringingPollTask: Task<Void, Never>?
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
    private var audioRecoveryGeneration: UInt64 = 0
    private var audioRecoveryAttempts = 0
    private var audioRecoveryWindowStartedAt: Date?
    private var audioRecoveryPending = false
    private var audioRecoveryEventSequence: UInt64 = 0
    private var audioRecoveryStartedForEventSequence: UInt64 = 0
    private var audioRecoveryCooldownUntil: Date?
    private var audioRecoveryExpectedGraphGeneration: UInt64?
    private var audioRecoveryBaseline = AudioProgressCounters()
    private var bufferedRecoveryPackets: [AudioPacket] = []
    private var audioProgress = AudioProgressCounters()
    private var lastRecordedAudioGraphGeneration: UInt64 = 0
    private var decryptFailureCount = 0
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
                    if value.event == "audio_graph_generation",
                       let valueGeneration = Self.graphGeneration(from: value.status) {
                        guard valueGeneration > self.lastRecordedAudioGraphGeneration else { continue }
                        self.lastRecordedAudioGraphGeneration = valueGeneration
                    }
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
        guard let callSignaling = try? signaling(for: current) else { return }
        if config.role == .A {
            recordRuntimeDiagnostic("watch_user_end_pressed", status: "current_generation", callID: current.serverCallID)
        }
        latchExplicitUserEnd(current, signaling: callSignaling)
        suppressRecoveryAfterExplicitUserEnd(current)
        enqueueTerminalMutation(current, mutation: terminalMutationForCurrentState())
        do { try await callKit?.requestEnd(id: current.localCallKitUUID) }
        catch {
            recordCallKitError(stage: "requestEnd", callID: current.serverCallID, error: error)
        }
        guard isCurrent(current) else { return }
        await teardownLocal(current, finalState: .ended(current.serverCallID), reportReason: nil)
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
        guard let current = generation, current.localCallKitUUID == localID else { throw CallKitCoordinatorError.invalidAction }
        if continuationCallKitUUID == localID, state.isAcceptedLifecycle, serverCallAccepted {
            guard Date() < deadline else { throw CallKitCoordinatorError.actionTimedOut }
            callKitReported = true
            callKit?.reportOutgoingStartedConnecting(id: localID)
            reportOutgoingConnectedIfNeeded(current)
            recordRuntimeDiagnostic("callkit_start_approved", status: "continuation", callID: current.serverCallID)
            return
        }
        guard case .outgoingRinging = state else { throw CallKitCoordinatorError.invalidAction }
        let callSignaling = try signaling(for: current)
        recordRuntimeDiagnostic("callkit_start_approved", status: "success", callID: current.serverCallID)
        callKit?.reportOutgoingStartedConnecting(id: localID)
        let requestID = createRequestID ?? UUID(); createRequestID = requestID
        let response: CallSignalView
        recordRuntimeDiagnostic("server_call_create_started", status: "started", callID: current.serverCallID)
        do { response = try await callSignaling.create(callID: current.serverCallID, requestID: requestID) }
        catch {
            guard isCurrent(current) else { throw CancellationError() }
            if let reconciled = try? await callSignaling.rawCall(current.serverCallID), reconciled.state == .ringing || reconciled.state == .accepted {
                guard isCurrent(current) else {
                    let mutation: CallMutation = reconciled.state == .accepted ? .end : .cancel
                    registerTerminalCompensation(current, mutation: mutation, signaling: callSignaling, requestID: UUID())
                    await deliverTerminalCompensation(current)
                    throw CancellationError()
                }
                serverCallCreated = true
                serverCallAccepted = reconciled.state == .accepted
                let mutation: CallMutation = reconciled.state == .accepted ? .end : .cancel
                registerTerminalCompensation(current, mutation: mutation, signaling: callSignaling, requestID: UUID())
                await deliverTerminalCompensation(current)
            }
            recordRuntimeDiagnostic("server_call_create_failed", status: "failed", callID: current.serverCallID, domain: (error as NSError).domain, code: (error as NSError).code); throw error
        }
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
        } catch let CallSignalingError.postCommitValidation(callID, state, mutationApplied, permanent, underlying) where callID == current.serverCallID && state == .accepted {
            serverCallAccepted = true
            if !permanent {
                do { response = try await verifiedAcceptedResponse(callSignaling, current: current, deadline: deadline) }
                catch let terminal as AuthoritativeTerminalCall {
                    await remoteTerminal(terminal.response, generation: current)
                    throw terminal
                }
                catch {
                    terminalRequestID = terminalRequestID ?? UUID()
                    registerTerminalCompensation(current, mutation: .end, signaling: callSignaling)
                    await deliverTerminalCompensation(current)
                    recordRuntimeDiagnostic("accepted_media_validation_failed", status: mutationApplied == false ? "reconciled" : "bounded_timeout", callID: current.serverCallID, domain: (underlying as NSError).domain, code: (underlying as NSError).code)
                    throw CallFailure.invalidServerState
                }
            } else {
                terminalRequestID = terminalRequestID ?? UUID()
                registerTerminalCompensation(current, mutation: .end, signaling: callSignaling)
                await deliverTerminalCompensation(current)
                recordRuntimeDiagnostic("accepted_media_validation_failed", status: permanent ? "permanent" : (mutationApplied == false ? "reconciled" : "bounded_timeout"), callID: current.serverCallID, domain: (underlying as NSError).domain, code: (underlying as NSError).code)
                throw CallFailure.invalidServerState
            }
        } catch {
            guard isCurrent(current) else { throw CancellationError() }
            if let reconciled = try? await callSignaling.rawCall(current.serverCallID) {
                guard isCurrent(current) else {
                    if reconciled.state == .accepted || reconciled.state == .ringing {
                        let mutation: CallMutation = reconciled.state == .accepted ? .end : .reject
                        registerTerminalCompensation(current, mutation: mutation, signaling: callSignaling, requestID: UUID())
                        await deliverTerminalCompensation(current)
                    }
                    throw CancellationError()
                }
                let mutation: CallMutation
                if reconciled.state == .accepted { serverCallAccepted = true; mutation = .end }
                else if reconciled.state == .ringing { mutation = .reject }
                else { throw error }
                registerTerminalCompensation(current, mutation: mutation, signaling: callSignaling, requestID: UUID())
                await deliverTerminalCompensation(current)
            }
            throw error
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
        try enterVerifiedAcceptedConnecting(response, signaling: callSignaling, current: current)
    }

    private func performEnd(localID: UUID, deadline: Date, origin: CallEndRequestOrigin) async throws -> CallEndDisposition {
        guard let current = generation else { throw CallKitCoordinatorError.invalidAction }
        let remappedExplicitEnd = current.localCallKitUUID != localID && explicitUserEndRequested && explicitUserEndServerCallID == current.serverCallID
        guard current.localCallKitUUID == localID || remappedExplicitEnd else { throw CallKitCoordinatorError.invalidAction }
        if remappedExplicitEnd {
            recordRuntimeDiagnostic("stale_end_uuid_remapped", status: "current_generation", callID: current.serverCallID)
        }
        let effectiveOrigin: CallEndRequestOrigin = explicitUserEndRequested ? .appRequested : origin
        let callSignaling = try signaling(for: current)
        let originStatus = effectiveOrigin == .appRequested ? "appRequested" : "system"
        recordRuntimeDiagnostic("callkit_end_received", status: "origin=\(originStatus)", callID: current.serverCallID)

        if explicitUserEndRequested, explicitUserEndServerCallID == current.serverCallID {
            suppressRecoveryAfterExplicitUserEnd(current)
            if let mutation = terminalCompensations[current.id]?.mutation {
                enqueueTerminalMutation(current, mutation: mutation)
            }
            await teardownLocal(current, finalState: .ended(current.serverCallID), reportReason: nil)
            return .ended
        }

        if effectiveOrigin == .system, suppressedSystemEndDuringAcceptance, serverCallAccepted,
           case let .connecting(callID) = state, callID == current.serverCallID,
           !audioOperational, activeCallKitUUID == localID,
           let protectionDeadline = acceptanceSystemEndProtectionDeadline,
           Date() < protectionDeadline {
            recordRuntimeDiagnostic("system_end_duplicate_preserved_during_connecting", status: "preserved", callID: current.serverCallID)
            return .preserveCall
        }

        if effectiveOrigin == .system, suppressedSystemEndDuringAcceptance,
           acceptanceSystemEndProtectionDeadline.map({ Date() < $0 }) == true,
           serverCallAccepted, state.isAcceptedLifecycle,
           activeCallKitUUID == localID, transportActive {
            let expectedEpoch = mediaEpoch
            let baseline = audioProgress
            let graceDeadline = min(Date().addingTimeInterval(1), deadline.addingTimeInterval(-0.25))
            recordRuntimeDiagnostic("system_end_reconcile_started", status: "origin=system", callID: current.serverCallID)
            repeat {
                do {
                    let response = try await callSignaling.rawCall(current.serverCallID)
                    guard isCurrent(current), activeCallKitUUID == localID,
                          mediaEpoch == expectedEpoch, response.callID == current.serverCallID else { throw CancellationError() }
                    recordRuntimeDiagnostic("system_end_reconcile_server_state", status: "state=\(response.state.rawValue)", callID: current.serverCallID)
                    if response.state != .accepted {
                        await remoteTerminal(response, generation: current)
                        return .ended
                    }
                    if audioProgress.sent > baseline.sent || audioProgress.received > baseline.received ||
                        audioProgress.scheduled > baseline.scheduled || audioProgress.rendered > baseline.rendered {
                        recordRuntimeDiagnostic("system_end_preserved_after_accept", status: "state=accepted", callID: current.serverCallID)
                        return .preserveCall
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard isCurrent(current), activeCallKitUUID == localID, mediaEpoch == expectedEpoch else { throw CancellationError() }
                    recordRuntimeDiagnostic("system_end_reconcile_server_state", status: "state=transient", callID: current.serverCallID)
                }
                guard Date() < graceDeadline else { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            } while Date() < graceDeadline
            guard isCurrent(current), activeCallKitUUID == localID, mediaEpoch == expectedEpoch else { throw CancellationError() }
            if audioOperational {
                recordRuntimeDiagnostic("system_end_preserved_after_accept", status: "state=accepted", callID: current.serverCallID)
                return .preserveCall
            }
        }
        if suppressedSystemEndDuringAcceptance,
           acceptanceSystemEndProtectionDeadline.map({ Date() >= $0 }) == true {
            suppressedSystemEndDuringAcceptance = false
            acceptanceSystemEndProtectionDeadline = nil
        }

        if effectiveOrigin == .system, isOutgoingCall, case .outgoingRinging = state {
            if systemEndReconciliationInProgress { return .preserveCall }
            systemEndReconciliationInProgress = true
            defer { systemEndReconciliationInProgress = false }
            ringingPollTask?.cancel(); ringingPollTask = nil
            let graceDeadline = min(Date().addingTimeInterval(2), deadline.addingTimeInterval(-0.25))
            let pollingDeadline = graceDeadline.addingTimeInterval(-0.15)
            recordRuntimeDiagnostic("system_end_reconcile_started", status: "origin=system", callID: current.serverCallID)
            repeat {
                guard isCurrent(current), activeCallKitUUID == localID else { throw CancellationError() }
                if state.isAcceptedLifecycle {
                    recordRuntimeDiagnostic("system_end_preserved_after_accept", status: "state=accepted", callID: current.serverCallID)
                    return .preserveCall
                }
                do {
                    let response = try await callSignaling.rawCall(current.serverCallID)
                    guard isCurrent(current), activeCallKitUUID == localID,
                          response.callID == current.serverCallID else { throw CancellationError() }
                    recordRuntimeDiagnostic("system_end_reconcile_server_state", status: "state=\(response.state.rawValue)", callID: current.serverCallID)
                    switch response.state {
                    case .accepted:
                        serverCallAccepted = true
                        do {
                            let verified = try await verifiedAcceptedResponse(callSignaling, current: current, deadline: graceDeadline)
                            guard isCurrent(current), activeCallKitUUID == localID else { throw CancellationError() }
                            try enterVerifiedAcceptedConnecting(verified, signaling: callSignaling, current: current)
                            startMediaIfReady(current)
                            recordRuntimeDiagnostic("system_end_preserved_after_accept", status: "state=accepted", callID: current.serverCallID)
                            return .preserveCall
                        } catch let terminal as AuthoritativeTerminalCall {
                            await remoteTerminal(terminal.response, generation: current)
                            return .ended
                        } catch {
                            guard isCurrent(current) else { throw error }
                            terminalRequestID = terminalRequestID ?? UUID()
                            registerTerminalCompensation(current, mutation: .end, signaling: callSignaling)
                            recordRuntimeDiagnostic("terminal_mutation", status: "mutation=end reason=accepted_verification_failed", callID: current.serverCallID)
                            await fail(current, .invalidServerState)
                            return .ended
                        }
                    case .rejected, .cancelled, .expired, .ended:
                        await remoteTerminal(response, generation: current)
                        return .ended
                    case .ringing:
                        break
                    }
                } catch {
                    guard isCurrent(current) else { throw error }
                    recordRuntimeDiagnostic("system_end_reconcile_server_state", status: "state=transient", callID: current.serverCallID, domain: (error as NSError).domain, code: (error as NSError).code)
                }
                guard Date() < pollingDeadline else { break }
                try? await Task.sleep(nanoseconds: 125_000_000)
            } while Date() < pollingDeadline
            guard isCurrent(current), activeCallKitUUID == localID else { throw CancellationError() }
            if state.isAcceptedLifecycle {
                recordRuntimeDiagnostic("system_end_preserved_after_accept", status: "state=accepted", callID: current.serverCallID)
                return .preserveCall
            }
            do {
                let final = try await callSignaling.rawCall(current.serverCallID)
                guard isCurrent(current), activeCallKitUUID == localID else { throw CancellationError() }
                if final.state == .accepted {
                    serverCallAccepted = true
                    do {
                        let verified = try await verifiedAcceptedResponse(callSignaling, current: current, deadline: graceDeadline)
                        try enterVerifiedAcceptedConnecting(verified, signaling: callSignaling, current: current)
                        startMediaIfReady(current)
                        recordRuntimeDiagnostic("system_end_preserved_after_accept", status: "state=accepted", callID: current.serverCallID)
                        return .preserveCall
                    } catch let terminal as AuthoritativeTerminalCall {
                        await remoteTerminal(terminal.response, generation: current)
                        return .ended
                    } catch {
                        terminalRequestID = terminalRequestID ?? UUID()
                        registerTerminalCompensation(current, mutation: .end, signaling: callSignaling)
                        recordRuntimeDiagnostic("terminal_mutation", status: "mutation=end reason=accepted_verification_failed", callID: current.serverCallID)
                        await fail(current, .invalidServerState)
                        return .ended
                    }
                }
                if final.state != .ringing { await remoteTerminal(final, generation: current); return .ended }
            } catch { guard isCurrent(current) else { throw error } }
            if serverCallAccepted {
                terminalRequestID = terminalRequestID ?? UUID()
                registerTerminalCompensation(current, mutation: .end, signaling: callSignaling)
                recordRuntimeDiagnostic("terminal_mutation", status: "mutation=end reason=accepted_verification_failed", callID: current.serverCallID)
                await fail(current, .invalidServerState)
                return .ended
            }
        }

        suppressedSystemEndDuringAcceptance = false
        acceptanceSystemEndProtectionDeadline = nil
        let mutation = terminalMutationForCurrentState()
        let reason = effectiveOrigin == .appRequested ? "explicit_user_end" : "system_end"
        recordRuntimeDiagnostic("terminal_mutation", status: "mutation=\(mutation.rawValue) reason=\(reason)", callID: current.serverCallID)
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
            if self.continuationCallKitUUID == localID {
                self.recordRuntimeDiagnostic("callkit_reactivation_failed", status: "reason=timeout", callID: current.serverCallID)
                await self.fail(current, .callKitReactivationFailed, reportCallKit: false)
                return
            }
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
            if self.continuationCallKitUUID == localID {
                self.recordRuntimeDiagnostic("callkit_reactivation_failed", status: "reason=action", callID: current.serverCallID)
                await self.fail(current, .callKitReactivationFailed, reportCallKit: false)
                return
            }
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
        guard let current = generation, current.localCallKitUUID == localID, !explicitUserEndRequested else {
            if explicitUserEndRequested { recordRuntimeDiagnostic("recovery_suppressed_after_user_end", status: "did_activate", callID: generation?.serverCallID) }
            return
        }
        let wasAwaitingReactivation = awaitingCallKitReactivation
        if activatedCallKitUUID != localID { callKitActivationEpoch &+= 1 }
        activatedCallKitUUID = localID
        hasEverActivatedCallKitAudio = true
        awaitingCallKitReactivation = false
        activationWatchdog?.cancel(); activationWatchdog = nil
        callKitReactivationTask?.cancel(); callKitReactivationTask = nil
        recordRuntimeDiagnostic("callkit_did_activate", status: "success", callID: current.serverCallID)
        if continuationCallKitUUID == localID {
            recordRuntimeDiagnostic("callkit_continuation_activated", status: "success", callID: current.serverCallID)
            reportOutgoingConnectedIfNeeded(current)
        } else if wasAwaitingReactivation {
            recordRuntimeDiagnostic("callkit_reactivated", status: "success", callID: current.serverCallID)
        }
        if let epoch = mediaEpoch, state.isAcceptedLifecycle {
            requestAudioRecovery(current, reason: "callkit_reactivated")
            if !transportActive { beginPeerWatchdog(current, mediaEpoch: epoch) }
        }
        else { startMediaIfReady(current) }
    }

    private func didDeactivate(localID: UUID?) {
        guard let current = generation, let localID, current.localCallKitUUID == localID else { return }
        callKitActivationEpoch &+= 1
        activatedCallKitUUID = nil
        audioStartedForCallKitUUID = nil
        mediaConnectTask?.cancel(); mediaConnectTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        peerWatchdog?.cancel(); peerWatchdog = nil
        audioRecoveryTask?.cancel(); audioRecoveryTask = nil; audioRecoveryPending = false
        audioRecoveryExpectedGraphGeneration = nil; bufferedRecoveryPackets.removeAll(keepingCapacity: true)
        playout.stop()
        audioFlowWatchdog?.cancel(); audioFlowWatchdog = nil
        audioFlow = AudioFlowMilestones(); audioProgress = AudioProgressCounters(); audioOperational = false
        audio.stop()
        if explicitUserEndRequested {
            recordRuntimeDiagnostic("recovery_suppressed_after_user_end", status: "did_deactivate", callID: current.serverCallID)
            return
        }
        if state.isAcceptedLifecycle {
            awaitingCallKitReactivation = true
            recordRuntimeDiagnostic("callkit_reactivation_wait_started", status: "started", callID: current.serverCallID)
            beginCallKitReactivationWatchdog(current)
        }
        recordRuntimeDiagnostic("callkit_did_deactivate", status: "success", callID: current.serverCallID)
    }

    private func beginCallKitReactivationWatchdog(_ current: CallGeneration) {
        callKitReactivationTask?.cancel()
        let expectedActivation = callKitActivationEpoch
        callKitReactivationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, self.isCurrent(current), self.awaitingCallKitReactivation,
                  self.activatedCallKitUUID == nil, self.callKitActivationEpoch == expectedActivation,
                  self.state.isAcceptedLifecycle else { return }
            await self.startCallKitContinuation(current)
        }
    }

    private func startCallKitContinuation(_ current: CallGeneration) async {
        guard isCurrent(current), state.isAcceptedLifecycle, serverCallAccepted,
              !callKitContinuationAttempted, let callKit else { return }
        callKitContinuationAttempted = true
        let newLocalID = distinctLocalCallKitUUID(from: current.serverCallID)
        let replacement = CallGeneration(id: current.id, serverCallID: current.serverCallID, localCallKitUUID: newLocalID)
        generation = replacement
        activeCallKitUUID = newLocalID
        continuationCallKitUUID = newLocalID
        outgoingConnectedReported = false
        activatedCallKitUUID = nil
        audioStartedForCallKitUUID = nil
        callKitActivationEpoch &+= 1
        let expectedActivation = callKitActivationEpoch
        recordRuntimeDiagnostic("callkit_continuation_started", status: "started", callID: current.serverCallID)
        startTerminalObserver(replacement)
        do {
            try await callKit.startOutgoing(id: newLocalID)
        } catch {
            guard isCurrent(replacement) else { return }
            recordRuntimeDiagnostic("callkit_reactivation_failed", status: "reason=start", callID: replacement.serverCallID)
            await fail(replacement, .callKitReactivationFailed, reportCallKit: false)
            return
        }
        guard isCurrent(replacement), awaitingCallKitReactivation else { return }
        callKitReactivationTask?.cancel()
        callKitReactivationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(CallTimeouts.audioActivation * 1_000_000_000)) } catch { return }
            guard let self, self.isCurrent(replacement), self.awaitingCallKitReactivation,
                  self.activatedCallKitUUID == nil, self.callKitActivationEpoch == expectedActivation else { return }
            self.recordRuntimeDiagnostic("callkit_reactivation_failed", status: "reason=timeout", callID: replacement.serverCallID)
            await self.fail(replacement, .callKitReactivationFailed)
        }
    }

    private func providerReset(localID: UUID?) {
        guard let current = generation, let localID, current.localCallKitUUID == localID else { return }
        recordRuntimeDiagnostic("provider_reset", status: "current_generation", callID: current.serverCallID)
        if state.isAcceptedLifecycle {
            didDeactivate(localID: localID)
            return
        }
        guard let callSignaling = try? signaling(for: current) else { return }
        let mutation = terminalMutationForCurrentState()
        recordRuntimeDiagnostic("terminal_mutation", status: "mutation=\(mutation.rawValue) reason=provider_reset", callID: current.serverCallID)
        let requestID = terminalRequestID ?? UUID(); terminalRequestID = requestID
        registerTerminalCompensation(current, mutation: mutation, signaling: callSignaling, requestID: requestID)
        enqueueTerminalMutation(current, mutation: mutation)
        spawn { [weak self] in guard let self, self.isCurrent(current) else { return }; await self.teardownLocal(current, finalState: .failed(current.serverCallID, .callKitRejected), reportReason: nil) }
    }

    private func startRingingPoll(_ current: CallGeneration, ringExpiresAt: Date) {
        ringingPollTask?.cancel()
        ringingPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isCurrent(current), Date() < ringExpiresAt {
                do {
                    let response = try await self.signaling(for: current).rawCall(current.serverCallID)
                    guard self.isCurrent(current), response.callID == current.serverCallID else { return }
                    switch response.state {
                    case .accepted:
                        let signaling = try self.signaling(for: current)
                        // Server acceptance is authoritative even if fetching or
                        // verifying the media keys fails while the UI is ringing.
                        self.serverCallAccepted = true
                        let verified: CallSignalView
                        do { verified = try await self.verifiedAcceptedResponse(signaling, current: current, deadline: ringExpiresAt) }
                        catch let terminal as AuthoritativeTerminalCall { await self.remoteTerminal(terminal.response, generation: current); return }
                        catch {
                            self.terminalRequestID = self.terminalRequestID ?? UUID()
                            self.registerTerminalCompensation(current, mutation: .end, signaling: signaling)
                            await self.deliverTerminalCompensation(current)
                            await self.fail(current, .invalidServerState)
                            return
                        }
                        guard self.isCurrent(current), verified.callID == current.serverCallID,
                              verified.state == .accepted, let token = verified.mediaToken, !token.isEmpty else {
                            await self.fail(current, .invalidServerState); return
                        }
                        do { try self.enterVerifiedAcceptedConnecting(verified, signaling: signaling, current: current) }
                        catch { await self.fail(current, .invalidServerState); return }
                        return
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
        guard !hasEverActivatedCallKitAudio else { return }
        activationWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(CallTimeouts.audioActivation * 1_000_000_000)) } catch { return }
            guard let self, self.isCurrent(current), self.audioStartedForCallKitUUID == nil else { return }
            await self.fail(current, .audioActivationTimeout)
        }
    }

    private func startMediaIfReady(_ current: CallGeneration) {
        guard isCurrent(current), activatedCallKitUUID == current.localCallKitUUID,
              !explicitUserEndRequested,
              audioStartedForCallKitUUID != current.localCallKitUUID,
              state.callID == current.serverCallID, let token = mediaToken,
              state.isMediaEstablishing else { return }
        activationWatchdog?.cancel()
        audioStartedForCallKitUUID = current.localCallKitUUID
        let activation = callKitActivationEpoch
        configureFramePump(current)
        mediaConnectTask?.cancel()
        mediaConnectTask = Task { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            do {
                try self.audio.start(muted: self.isMuted)
                guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                      self.callKitActivationEpoch == activation else { return }
                if let existingEpoch = self.mediaEpoch {
                    self.startPlayout(current, mediaEpoch: existingEpoch)
                    if self.transportActive { self.beginAudioFlowWatchdog(current) }
                    return
                }
                let epoch = try await self.media.connect(callID: current.serverCallID, peer: try self.signaling(for: current).mediaPeerIdentity, token: token)
                guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                      self.callKitActivationEpoch == activation else { await self.media.close(connectionID: epoch); return }
                self.mediaEpoch = epoch
                self.startPlayout(current, mediaEpoch: epoch)
                if self.pendingPeerReadyEpochs.remove(epoch) != nil { self.peerReady(callID: current.serverCallID, mediaEpoch: epoch) }
                else { self.beginPeerWatchdog(current, mediaEpoch: epoch) }
            } catch {
                guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                      self.callKitActivationEpoch == activation else { return }
                await self.fail(current, (error as? CallFailure) == .audioFailed ? .audioFailed : .mediaConnectionFailed)
            }
        }
    }

    private func peerReady(callID: UUID, mediaEpoch: UUID) {
        guard let current = generation, current.serverCallID == callID, !explicitUserEndRequested else {
            if explicitUserEndRequested { recordRuntimeDiagnostic("recovery_suppressed_after_user_end", status: "peer_ready", callID: callID) }
            return
        }
        guard self.mediaEpoch == mediaEpoch else {
            if self.mediaEpoch == nil { pendingPeerReadyEpochs.insert(mediaEpoch) }
            return
        }
        peerWatchdog?.cancel()
        transportActive = true
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
        guard !explicitUserEndRequested else {
            recordRuntimeDiagnostic("recovery_suppressed_after_user_end", status: "media_disconnect", callID: current.serverCallID)
            return
        }
        recordRuntimeDiagnostic("media_disconnect_reason", status: "reason=\(String(describing: event.reason))", callID: current.serverCallID)
        mediaEpoch = nil; transportActive = false; audioOperational = false; audioFlowWatchdog?.cancel(); playout.stop()
        if event.reason == .authFailed || event.reason == .protocolViolation {
            spawn { [weak self] in guard let self, self.isCurrent(current) else { return }; await self.fail(current, .invalidServerState) }
            return
        }
        if event.reason == .remoteClosed {
            spawn { [weak self] in
                guard let self, self.isCurrent(current) else { return }
                do {
                    let response = try await self.signaling(for: current).rawCall(current.serverCallID)
                    guard self.isCurrent(current) else { return }
                    if response.state == .accepted { self.startMediaReconnect(current, token: token, reconcileServerState: true) }
                    else { await self.remoteTerminal(response, generation: current) }
                }
                catch { self.startMediaReconnect(current, token: token, reconcileServerState: true) }
            }
            return
        }
        startMediaReconnect(current, token: token)
    }

    private func startMediaReconnect(_ current: CallGeneration, token: String, reconcileServerState: Bool = false) {
        guard isCurrent(current), state.isAcceptedLifecycle, !explicitUserEndRequested else {
            if explicitUserEndRequested { recordRuntimeDiagnostic("recovery_suppressed_after_user_end", status: "media_reconnect", callID: current.serverCallID) }
            return
        }
        recordRuntimeDiagnostic("media_reconnect_started", status: "started", callID: current.serverCallID)
        transition(.reconnecting(current.serverCallID))
        let activation = callKitActivationEpoch
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + CallTimeouts.reconnectTotal; var delay = 0.25
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                      self.callKitActivationEpoch == activation else { return }
                if reconcileServerState {
                    do {
                        let response = try await self.signaling(for: current).rawCall(current.serverCallID)
                        guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                              self.callKitActivationEpoch == activation else { return }
                        if response.state != .accepted { await self.remoteTerminal(response, generation: current); return }
                    } catch {
                        delay = min(delay * 2, 2)
                        continue
                    }
                }
                do {
                    let epoch = try await self.media.connect(callID: current.serverCallID, peer: try self.signaling(for: current).mediaPeerIdentity, token: token)
                    guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                          self.callKitActivationEpoch == activation else { await self.media.close(connectionID: epoch); return }
                    self.mediaEpoch = epoch; self.startPlayout(current, mediaEpoch: epoch)
                    self.recordRuntimeDiagnostic("media_reconnect_succeeded", status: "success", callID: current.serverCallID)
                    if self.pendingPeerReadyEpochs.remove(epoch) != nil { self.peerReady(callID: current.serverCallID, mediaEpoch: epoch) }
                    else { self.beginPeerWatchdog(current, mediaEpoch: epoch) }
                    return
                } catch {
                    guard !Task.isCancelled, self.callKitActivationEpoch == activation else { return }
                    delay = min(delay * 2, 2)
                }
            }
            guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                  self.callKitActivationEpoch == activation else { return }
            self.recordRuntimeDiagnostic("media_reconnect_exhausted", status: "reason=networkLost", callID: current.serverCallID)
            self.recordRuntimeDiagnostic("terminal_mutation", status: "mutation=end reason=media_reconnect_exhausted", callID: current.serverCallID)
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
                    self.audioProgress.sent &+= 1
                    self.confirmAudioRecoveryIfReady()
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
        guard let current = generation, !explicitUserEndRequested, receivedPacket.callID == current.serverCallID, self.mediaEpoch == mediaEpoch, receivedPacket.type == .audio else { return }
        let packet: AudioPacket
        do {
            if let cryptor = callAudioCryptor { packet = try cryptor.decrypt(receivedPacket) }
            else { guard receivedPacket.protocolVersion == AudioPacket.legacyVersion else { return }; packet = receivedPacket }
        } catch {
            decryptFailureCount += 1
            if decryptFailureCount == 1 || decryptFailureCount.isMultiple(of: 10) {
                recordRuntimeDiagnostic("encrypted_audio_authentication_drop", status: "count=\(decryptFailureCount)", callID: current.serverCallID)
            }
            if decryptFailureCount >= 20 { mediaDisconnected(.init(callID: current.serverCallID, connectionID: mediaEpoch, closeCode: nil, reason: .protocolViolation)) }
            return
        }
        guard packet.payload.count == AudioEngine.bytesPerFrame else { return }
        audioFlow.remoteFrameReceived = true
        audioProgress.received &+= 1
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
        if audioRecoveryTask != nil, audioRecoveryExpectedGraphGeneration == nil {
            bufferedRecoveryPackets.append(packet)
            if bufferedRecoveryPackets.count > 20 { bufferedRecoveryPackets.removeFirst(bufferedRecoveryPackets.count - 20) }
        } else {
            playout.insert(packet, epoch: mediaEpoch)
        }
        confirmAudioRecoveryIfReady()
    }

    private func startPlayout(_ current: CallGeneration, mediaEpoch: UUID) {
        let audio = self.audio
        let events = runtimeEventContinuation
        playout.start(
            epoch: mediaEpoch,
            onFrame: { payload in audio.play(payload) },
            onDiagnostic: { value in events?.yield(.playoutDiagnostic(current.id, value)) }
        )
    }

    private func startIncomingReconciliation(_ current: CallGeneration) {
        spawn { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self else { return }
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
        guard let current = generation, state.isAcceptedLifecycle,
              activatedCallKitUUID == current.localCallKitUUID,
              audioStartedForCallKitUUID == current.localCallKitUUID else { return }
        audioRecoveryEventSequence &+= 1
        let eventSequence = audioRecoveryEventSequence
        recordRuntimeDiagnostic("recovery_request_source", status: "source=runtime_failure_\(String(describing: failure))", callID: current.serverCallID)
        recordRuntimeDiagnostic("recovery_event_sequence", status: "sequence=\(eventSequence)", callID: current.serverCallID)
        requestAudioRecovery(current, reason: "runtime_failure=\(String(describing: failure))", eventSequence: eventSequence)
    }

    private static func graphGeneration(from status: String) -> UInt64? {
        guard let range = status.range(of: "generation=") else { return nil }
        let suffix = status[range.upperBound...]
        return UInt64(suffix.prefix { $0.isNumber })
    }

    private func observeAudioDiagnostic(_ value: AudioEngineDiagnostic, generation current: CallGeneration) {
        guard isCurrent(current) else { return }
        switch value.event {
        case "first_mic_callback", "first_mic_buffer": audioFlow.micCallback = true
        case "first_network_pcm_generated", "first_network_audio_frame_generated": audioFlow.networkPCMGenerated = true
        case "first_playback_buffer_scheduled": audioFlow.playbackScheduled = true; audioProgress.scheduled &+= 1
        case "first_playback_buffer_rendered": audioFlow.playbackRendered = true; audioProgress.rendered &+= 1
        case "playback_render_progress": audioProgress.rendered &+= 250
        default: break
        }
        confirmAudioRecoveryIfReady()
        updateAudioOperational()
    }

    private func updateAudioOperational() {
        let wasOperational = audioOperational
        audioOperational = audioFlow.isOperational(transportActive: transportActive)
        if audioOperational, !wasOperational, let callID = generation?.serverCallID {
            suppressedSystemEndDuringAcceptance = false
            acceptanceSystemEndProtectionDeadline = nil
            recordRuntimeDiagnostic("audio_operational", status: "transport=ready audio=ready", callID: callID)
            if let current = generation {
                if state != .active(callID) {
                    transition(.active(callID)); startDuration(current)
                    reportOutgoingConnectedIfNeeded(current)
                }
                beginAudioFlowWatchdog(current)
            }
        }
    }

    private func reportOutgoingConnectedIfNeeded(_ current: CallGeneration) {
        guard isCurrent(current), (isOutgoingCall || continuationCallKitUUID == current.localCallKitUUID),
              !outgoingConnectedReported else { return }
        outgoingConnectedReported = true
        callKit?.reportOutgoingConnected(id: current.localCallKitUUID)
        recordRuntimeDiagnostic("outgoing_connected_reported", status: "success", callID: current.serverCallID)
    }

    private func beginAudioFlowWatchdog(_ current: CallGeneration) {
        audioFlowWatchdog?.cancel()
        let baseline = audioProgress
        let expectedEpoch = mediaEpoch
        let expectedActivation = callKitActivationEpoch
        audioFlowWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, self.isCurrent(current), self.transportActive,
                  self.mediaEpoch == expectedEpoch, self.callKitActivationEpoch == expectedActivation else { return }
            self.recordRuntimeDiagnostic(
                "audio_flow_progress",
                status: "sent=\(self.audioProgress.sent) received=\(self.audioProgress.received) scheduled=\(self.audioProgress.scheduled) rendered=\(self.audioProgress.rendered)",
                callID: current.serverCallID
            )
            if self.audioOperational, self.audioProgress.stalledStage(since: baseline) == nil {
                self.beginAudioFlowWatchdog(current)
                return
            }
            let stage = self.audioFlow.failureStage ?? self.audioProgress.stalledStage(since: baseline) ?? .noMicCallback
            self.recordRuntimeDiagnostic("audio_flow_watchdog", status: stage.rawValue, callID: current.serverCallID)
            if stage == .sendFailure || stage == .receiveAbsent {
                self.recoverMediaFlow(current)
            } else {
                self.requestAudioRecovery(current, reason: stage.rawValue)
            }
        }
    }

    private func recoverMediaFlow(_ current: CallGeneration) {
        guard isCurrent(current), activatedCallKitUUID == current.localCallKitUUID,
              let token = mediaToken, let oldEpoch = mediaEpoch else { return }
        mediaEpoch = nil; transportActive = false; audioOperational = false
        playout.stop()
        transition(.reconnecting(current.serverCallID))
        spawn { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            await self.media.close(connectionID: oldEpoch)
            guard self.isCurrent(current) else { return }
            self.startMediaReconnect(current, token: token, reconcileServerState: true)
        }
    }

    private func verifiedAcceptedResponse(_ signaling: any CallSignaling, current: CallGeneration, deadline: Date) async throws -> CallSignalView {
        var lastError: Error = CallSignalingError.invalidResponse
        while isCurrent(current), Date() < deadline {
            do {
                let response = try await signaling.call(current.serverCallID)
                guard response.callID == current.serverCallID else { throw CallSignalingError.invalidResponse }
                switch response.state {
                case .accepted: break
                case .rejected, .cancelled, .expired, .ended: throw AuthoritativeTerminalCall(response: response)
                case .ringing: throw CallSignalingError.invalidResponse
                }
                guard response.mediaToken?.isEmpty == false else { throw CallSignalingError.invalidResponse }
                return response
            } catch {
                if error is AuthoritativeTerminalCall { throw error }
                if isPermanentSecureCallValidationError(error) { throw error }
                lastError = error
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try await Task.sleep(nanoseconds: UInt64(min(0.25, remaining) * 1_000_000_000))
            }
        }
        throw lastError
    }

    private func recoverAudioOnly(_ current: CallGeneration) {
        audioRecoveryEventSequence &+= 1
        requestAudioRecovery(current, reason: "audio_flow_watchdog", eventSequence: audioRecoveryEventSequence)
    }

    private func requestAudioRecovery(_ current: CallGeneration, reason: String, eventSequence: UInt64? = nil) {
        guard isCurrent(current), activatedCallKitUUID == current.localCallKitUUID, state.isAcceptedLifecycle, !explicitUserEndRequested else {
            if explicitUserEndRequested { recordRuntimeDiagnostic("recovery_suppressed_after_user_end", status: reason, callID: current.serverCallID) }
            return
        }
        let requestSequence: UInt64
        if let eventSequence { requestSequence = eventSequence }
        else { audioRecoveryEventSequence &+= 1; requestSequence = audioRecoveryEventSequence }
        recordRuntimeDiagnostic("recovery_request_source", status: "source=\(reason)", callID: current.serverCallID)
        recordRuntimeDiagnostic("recovery_event_sequence", status: "sequence=\(requestSequence)", callID: current.serverCallID)
        if audioRecoveryTask != nil {
            audioRecoveryPending = false
            recordRuntimeDiagnostic("recovery_event_ignored_during_rebuild", status: "sequence=\(requestSequence)", callID: current.serverCallID)
            return
        }
        let now = Date()
        if let cooldown = audioRecoveryCooldownUntil, now < cooldown {
            recordRuntimeDiagnostic("recovery_pending_event_discarded", status: "sequence=\(requestSequence) cooldown=active", callID: current.serverCallID)
            return
        }
        if audioRecoveryWindowStartedAt.map({ now.timeIntervalSince($0) >= 8 }) != false {
            audioRecoveryWindowStartedAt = now; audioRecoveryAttempts = 0
        }
        guard audioRecoveryAttempts < 3 else {
            if hasLiveRecoveryProgress() {
                preserveDegradedAudioRecovery(current, reason: reason)
                return
            }
            recordRuntimeDiagnostic("audio_recovery_exhausted", status: reason, callID: current.serverCallID)
            spawn { [weak self] in guard let self, self.isCurrent(current) else { return }; await self.fail(current, .audioFailed) }
            return
        }
        audioRecoveryPending = false
        audioRecoveryStartedForEventSequence = requestSequence
        audioRecoveryGeneration &+= 1
        let recoveryID = audioRecoveryGeneration
        let expectedEpoch = mediaEpoch
        let expectedActivation = callKitActivationEpoch
        audioRecoveryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                  self.callKitActivationEpoch == expectedActivation, self.mediaEpoch == expectedEpoch,
                  self.audioRecoveryGeneration == recoveryID else { return }
            self.audioRecoveryAttempts += 1
            self.recordRuntimeDiagnostic("audio_recovery_started", status: "attempt=\(self.audioRecoveryAttempts) reason=\(reason)", callID: current.serverCallID)
            self.audioFlowWatchdog?.cancel(); self.audioFlowWatchdog = nil
            self.playout.stop(); self.audio.stop(); self.audioOperational = false
            self.audioFlow.micCallback = false; self.audioFlow.networkPCMGenerated = false
            self.audioFlow.networkFrameSent = false; self.audioFlow.playbackScheduled = false; self.audioFlow.playbackRendered = false
            self.audioRecoveryExpectedGraphGeneration = nil
            do {
                try self.audio.start(muted: self.isMuted)
            } catch {
                self.recordRuntimeDiagnostic("playback_failure", status: "graph_restart_failed", callID: current.serverCallID, domain: (error as NSError).domain, code: (error as NSError).code)
                self.audioRecoveryTask = nil
                self.requestAudioRecovery(current, reason: "graph_restart_failed")
                return
            }
            guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                  self.callKitActivationEpoch == expectedActivation, self.mediaEpoch == expectedEpoch,
                  self.audioRecoveryGeneration == recoveryID else { self.audio.stop(); return }
            self.audioStartedForCallKitUUID = current.localCallKitUUID
            self.audioRecoveryExpectedGraphGeneration = self.audio.graphGeneration
            let restartedGraph = self.audio.graphGeneration
            self.lastRecordedAudioGraphGeneration = max(self.lastRecordedAudioGraphGeneration, restartedGraph)
            self.recordRuntimeDiagnostic("audio_graph_restarted", status: "generation=\(restartedGraph)", callID: current.serverCallID)
            if let epoch = expectedEpoch {
                self.startPlayout(current, mediaEpoch: epoch)
                let buffered = self.bufferedRecoveryPackets.sorted { $0.sequence < $1.sequence }
                self.bufferedRecoveryPackets.removeAll(keepingCapacity: true)
                for packet in buffered { self.playout.insert(packet, epoch: epoch) }
            }
            self.audioRecoveryBaseline = self.audioProgress
            self.recordRuntimeDiagnostic("audio_recovery_validating", status: "generation=\(recoveryID)", callID: current.serverCallID)
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard self.isCurrent(current), self.activatedCallKitUUID == current.localCallKitUUID,
                  self.callKitActivationEpoch == expectedActivation, self.mediaEpoch == expectedEpoch,
                  self.audioRecoveryGeneration == recoveryID,
                  self.audioRecoveryExpectedGraphGeneration == self.audio.graphGeneration else { return }
            self.recordRuntimeDiagnostic("audio_recovery_validation_timeout", status: "attempt=\(self.audioRecoveryAttempts)", callID: current.serverCallID)
            if self.hasLiveRecoveryProgress() {
                self.preserveDegradedAudioRecovery(current, reason: "validation_timeout")
                return
            }
            self.audioRecoveryTask = nil
            self.audioRecoveryExpectedGraphGeneration = nil
            self.requestAudioRecovery(current, reason: "validation_timeout")
        }
    }

    private func confirmAudioRecoveryIfReady() {
        guard let current = generation, audioRecoveryTask != nil,
              audioRecoveryExpectedGraphGeneration == audio.graphGeneration,
              audioFlow.micCallback, audioFlow.networkPCMGenerated,
              audioProgress.sent > audioRecoveryBaseline.sent,
              audioProgress.received > audioRecoveryBaseline.received,
              audioProgress.scheduled > audioRecoveryBaseline.scheduled,
              audioProgress.rendered > audioRecoveryBaseline.rendered else { return }
        audioRecoveryTask?.cancel(); audioRecoveryTask = nil
        recordRuntimeDiagnostic("recovery_confirmation_cancelled_watchdog", status: "generation=\(audioRecoveryGeneration)", callID: current.serverCallID)
        if audioRecoveryPending || audioRecoveryEventSequence > audioRecoveryStartedForEventSequence {
            recordRuntimeDiagnostic("recovery_pending_event_discarded", status: "through_sequence=\(audioRecoveryEventSequence)", callID: current.serverCallID)
        }
        audioRecoveryPending = false
        audioRecoveryExpectedGraphGeneration = nil; bufferedRecoveryPackets.removeAll(keepingCapacity: true)
        recordRuntimeDiagnostic("audio_recovery_confirmed", status: "generation=\(audioRecoveryGeneration)", callID: current.serverCallID)
        updateAudioOperational()
        beginAudioRecoverySettlePeriod(current)
    }

    private func hasLiveRecoveryProgress() -> Bool {
        guard transportActive,
              audioProgress.sent > audioRecoveryBaseline.sent,
              audioProgress.received > audioRecoveryBaseline.received else { return false }
        return audioOperational || audioProgress.scheduled > audioRecoveryBaseline.scheduled ||
            audioProgress.rendered > audioRecoveryBaseline.rendered
    }

    private func preserveDegradedAudioRecovery(_ current: CallGeneration, reason: String) {
        guard isCurrent(current) else { return }
        audioRecoveryTask?.cancel(); audioRecoveryTask = nil
        audioRecoveryPending = false; audioRecoveryExpectedGraphGeneration = nil
        bufferedRecoveryPackets.removeAll(keepingCapacity: true)
        recordRuntimeDiagnostic("audio_recovery_degraded_call_preserved", status: "reason=\(reason)", callID: current.serverCallID)
        beginAudioRecoverySettlePeriod(current)
    }

    private func beginAudioRecoverySettlePeriod(_ current: CallGeneration) {
        audioRecoverySettleTask?.cancel()
        let recoveryID = audioRecoveryGeneration
        let expectedLocalID = current.localCallKitUUID
        let expectedEpoch = mediaEpoch
        audioRecoveryCooldownUntil = Date().addingTimeInterval(0.5)
        audioRecoverySettleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, self.isCurrent(current), self.activeCallKitUUID == expectedLocalID,
                  self.mediaEpoch == expectedEpoch, self.audioRecoveryGeneration == recoveryID else { return }
            self.audioRecoveryAttempts = 0; self.audioRecoveryWindowStartedAt = nil
            self.audioRecoveryCooldownUntil = nil; self.audioRecoverySettleTask = nil
            if self.transportActive { self.beginAudioFlowWatchdog(current) }
        }
    }

    private func compensateAfterStart(_ current: CallGeneration, signaling: any CallSignaling) async {
        guard isCurrent(current), serverCallCreated else { return }
        let mutation: CallMutation = serverCallAccepted ? .end : .cancel
        terminalRequestID = terminalRequestID ?? UUID(); registerTerminalCompensation(current, mutation: mutation, signaling: signaling); await deliverTerminalCompensation(current)
    }
    private func compensateAfterAccept(_ current: CallGeneration, signaling: any CallSignaling) async {
        guard isCurrent(current) else { return }
        terminalRequestID = terminalRequestID ?? UUID(); registerTerminalCompensation(current, mutation: .end, signaling: signaling); await deliverTerminalCompensation(current)
    }
    private func terminalMutationForIncomingFailure(_ current: CallGeneration, signaling: any CallSignaling) async { terminalRequestID = terminalRequestID ?? UUID(); registerTerminalCompensation(current, mutation: .reject, signaling: signaling); await deliverTerminalCompensation(current) }

    private func terminalMutationForCurrentState() -> CallMutation {
        if serverCallAccepted { return .end }
        switch state { case .outgoingRinging: return .cancel; case .incomingRinging: return .reject; default: return .end }
    }

    private func latchExplicitUserEnd(_ current: CallGeneration, signaling: any CallSignaling) {
        guard isCurrent(current) else { return }
        if !explicitUserEndRequested {
            explicitUserEndRequested = true
            explicitUserEndRequestID = UUID()
            explicitUserEndRequestedAt = Date()
            explicitUserEndServerCallID = current.serverCallID
            recordRuntimeDiagnostic("explicit_user_end_latched", status: "current_generation", callID: current.serverCallID)
            recordRuntimeDiagnostic("explicit_user_end_request_id_created", status: "created", callID: current.serverCallID)
        }
        let mutation = terminalMutationForCurrentState()
        terminalMutation = mutation
        terminalRequestID = explicitUserEndRequestID
        registerTerminalCompensation(current, mutation: mutation, signaling: signaling, requestID: explicitUserEndRequestID)
        recordRuntimeDiagnostic("terminal_mutation", status: "mutation=\(mutation.rawValue) reason=explicit_user_end", callID: current.serverCallID)
    }

    private func suppressRecoveryAfterExplicitUserEnd(_ current: CallGeneration) {
        guard isCurrent(current), explicitUserEndRequested else { return }
        awaitingCallKitReactivation = false
        mediaConnectTask?.cancel(); mediaConnectTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        activationWatchdog?.cancel(); activationWatchdog = nil
        peerWatchdog?.cancel(); peerWatchdog = nil
        audioFlowWatchdog?.cancel(); audioFlowWatchdog = nil
        audioRecoveryTask?.cancel(); audioRecoveryTask = nil
        audioRecoverySettleTask?.cancel(); audioRecoverySettleTask = nil
        callKitReactivationTask?.cancel(); callKitReactivationTask = nil
        audioRecoveryPending = false
        playout.stop(); audio.stop()
        recordRuntimeDiagnostic("recovery_suppressed_after_user_end", status: "latched", callID: current.serverCallID)
    }

    private func enqueueTerminalMutation(_ current: CallGeneration, mutation: CallMutation) {
        guard terminalCompensations[current.id]?.mutation == mutation else { return }
        guard !terminalDeliveriesInProgress.contains(current.id) else { return }
        terminalDeliveriesInProgress.insert(current.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.deliverTerminalCompensation(current)
            self.terminalDeliveriesInProgress.remove(current.id)
        }
    }

    private func registerTerminalCompensation(_ current: CallGeneration, mutation: CallMutation, signaling: any CallSignaling, requestID: UUID? = nil) {
        if let retained = terminalCompensations[current.id] {
            // Once an accepted call requires `end`, later CallKit failure paths
            // must not downgrade the legal server transition to `cancel`.
            if retained.mutation == .end && mutation != .end { return }
            terminalCompensations[current.id] = TerminalCompensation(mutation: mutation, requestID: retained.mutation == mutation ? retained.requestID : (requestID ?? UUID()), signaling: retained.signaling)
            return
        }
        if terminalCompensations.count >= 8, let oldest = terminalCompensations.keys.first { terminalCompensations.removeValue(forKey: oldest) }
        terminalCompensations[current.id] = TerminalCompensation(mutation: mutation, requestID: requestID ?? terminalRequestID ?? UUID(), signaling: signaling)
    }

    private func deliverTerminalCompensation(_ current: CallGeneration) async {
        guard let retained = terminalCompensations[current.id] else { return }
        recordRuntimeDiagnostic("terminal_end_delivery_started", status: retained.mutation.rawValue, callID: current.serverCallID)
        for (attempt, delay): (Int, UInt64) in [0, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000].enumerated() {
            if delay > 0 { do { try await Task.sleep(nanoseconds: delay) } catch { return } }
            guard terminalCompensations[current.id]?.mutation == retained.mutation, terminalCompensations[current.id]?.requestID == retained.requestID else { return }
            do {
                _ = try await retained.signaling.mutate(retained.mutation, callID: current.serverCallID, requestID: retained.requestID)
                terminalCompensations.removeValue(forKey: current.id)
                recordRuntimeDiagnostic("terminal_end_delivery_succeeded", status: retained.mutation.rawValue, callID: current.serverCallID)
                return
            } catch {
                if attempt < 4 {
                    recordRuntimeDiagnostic("terminal_end_delivery_retry", status: "attempt=\(attempt + 1)", callID: current.serverCallID)
                }
                continue
            }
        }
        recordRuntimeDiagnostic("terminal_end_delivery_failed", status: retained.mutation.rawValue, callID: current.serverCallID)
        recordRuntimeDiagnostic("terminal_mutation_failed", status: retained.mutation.rawValue, callID: current.serverCallID)
    }

    private func fail(_ current: CallGeneration, _ failure: CallFailure, reportCallKit: Bool = true, reportReason: CallEndReason = .failed) async {
        guard isCurrent(current) else { return }
        recordRuntimeDiagnostic("call_failed_reason", status: String(describing: failure), callID: current.serverCallID)
        if serverCallAccepted || state.isAcceptedLifecycle, let callSignaling = try? signaling(for: current) {
            recordRuntimeDiagnostic("terminal_mutation", status: "mutation=end reason=\(failure == .audioFailed ? "audio_recovery_exhausted" : "local_failure")", callID: current.serverCallID)
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
        explicitUserEndRequested = false; explicitUserEndRequestID = nil; explicitUserEndRequestedAt = nil; explicitUserEndServerCallID = nil
        callKitActivationEpoch &+= 1; activatedCallKitUUID = nil; audioStartedForCallKitUUID = nil
        hasEverActivatedCallKitAudio = false; awaitingCallKitReactivation = false; callKitContinuationAttempted = false; continuationCallKitUUID = nil; outgoingConnectedReported = false
        serverCallCreated = false; serverCallAccepted = false; suppressedSystemEndDuringAcceptance = false; acceptanceSystemEndProtectionDeadline = nil; systemEndReconciliationInProgress = false; sequence = 0; isMuted = false; elapsedSeconds = 0
        firstSentFrameReported = false; firstRemoteFrameReported = false; firstSendFailureReported = false
        transportActive = false; audioOperational = false; audioFlow = AudioFlowMilestones()
        audioProgress = AudioProgressCounters(); decryptFailureCount = 0
        audioRecoveryTask?.cancel(); audioRecoverySettleTask?.cancel(); audioRecoveryTask = nil; audioRecoverySettleTask = nil; audioRecoveryGeneration = 0
        audioRecoveryAttempts = 0; audioRecoveryWindowStartedAt = nil; audioRecoveryPending = false
        audioRecoveryEventSequence = 0; audioRecoveryStartedForEventSequence = 0; audioRecoveryCooldownUntil = nil
        audioRecoveryExpectedGraphGeneration = nil; audioRecoveryBaseline = AudioProgressCounters()
        lastRecordedAudioGraphGeneration = 0
        bufferedRecoveryPackets.removeAll(keepingCapacity: false)
        firstRemoteNonzeroReported = false; firstSentNonzeroReported = false; sendBackpressureDropReported = false
        return next
    }

    private func invalidateGeneration(expected: CallGeneration? = nil) {
        if let expected, generation != expected { return }
        cancelCallTasks(); sendContinuation?.finish(); sendContinuation = nil; sendStream = nil; sendTask?.cancel(); sendTask = nil
        activeSignaling?.eraseSecrets(); callAudioCryptor?.erase(); callAudioCryptor = nil
        generation = nil; activeSignaling = nil; activeCallKitUUID = nil; mediaEpoch = nil; mediaToken = nil; isOutgoingCall = false; callKitReported = false; incomingCallerName = nil; suppressedSystemEndDuringAcceptance = false; acceptanceSystemEndProtectionDeadline = nil; systemEndReconciliationInProgress = false
        explicitUserEndRequested = false; explicitUserEndRequestID = nil; explicitUserEndRequestedAt = nil; explicitUserEndServerCallID = nil
        hasEverActivatedCallKitAudio = false; awaitingCallKitReactivation = false; callKitContinuationAttempted = false; continuationCallKitUUID = nil; outgoingConnectedReported = false
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

    private func enterVerifiedAcceptedConnecting(
        _ response: CallSignalView,
        signaling: any CallSignaling,
        current: CallGeneration
    ) throws {
        guard isCurrent(current), response.callID == current.serverCallID,
              response.state == .accepted, let token = response.mediaToken, !token.isEmpty else {
            throw CallFailure.invalidServerState
        }
        if state.isAcceptedLifecycle, serverCallAccepted, mediaToken == token { return }
        try configureAcceptedEncryption(response, signaling: signaling)
        guard isCurrent(current) else { throw CancellationError() }
        mediaToken = token
        serverCallAccepted = true
        suppressedSystemEndDuringAcceptance = true
        acceptanceSystemEndProtectionDeadline = Date().addingTimeInterval(CallTimeouts.audioActivation + CallTimeouts.initialMedia)
        transition(.connecting(current.serverCallID))
        reportOutgoingConnectedIfNeeded(current)
        beginActivationWatchdog(current)
        startTerminalObserver(current)
    }

    private func cancelCallTasks() {
        for task in tasks { task.cancel() }; tasks.removeAll(keepingCapacity: true)
        mediaConnectTask?.cancel(); reconnectTask?.cancel(); durationTask?.cancel(); activationWatchdog?.cancel(); peerWatchdog?.cancel(); audioFlowWatchdog?.cancel(); terminalObserver?.cancel(); ringingPollTask?.cancel()
        audioRecoveryTask?.cancel(); audioRecoverySettleTask?.cancel(); callKitReactivationTask?.cancel()
        playout.stop()
        mediaConnectTask = nil; reconnectTask = nil; durationTask = nil; activationWatchdog = nil; peerWatchdog = nil; audioFlowWatchdog = nil; terminalObserver = nil; ringingPollTask = nil
        audioRecoveryTask = nil; audioRecoverySettleTask = nil; callKitReactivationTask = nil; audioRecoveryPending = false; audioRecoveryExpectedGraphGeneration = nil; audioRecoveryCooldownUntil = nil
        bufferedRecoveryPackets.removeAll(keepingCapacity: true)
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

    deinit {
        for task in tasks { task.cancel() }
        mediaConnectTask?.cancel(); reconnectTask?.cancel(); durationTask?.cancel()
        activationWatchdog?.cancel(); callKitReactivationTask?.cancel(); peerWatchdog?.cancel(); audioFlowWatchdog?.cancel(); terminalObserver?.cancel(); ringingPollTask?.cancel()
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
