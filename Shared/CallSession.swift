import Foundation

@MainActor
protocol CallKitHandling: AnyObject {
    var onPrepareAudio: (() throws -> Void)? { get set }
    var onActionFailed: ((UUID, String, Error) -> Void)? { get set }
    var onStartApproved: ((UUID) -> Void)? { get set }
    var onAnswerApproved: ((UUID) -> Void)? { get set }
    var onEndApproved: ((UUID) -> Void)? { get set }
    var onAudioActivated: ((UUID) -> Void)? { get set }
    var onAudioDeactivated: ((UUID?) -> Void)? { get set }
    var onProviderReset: ((UUID?) -> Void)? { get set }
    func startOutgoing(id: UUID) async throws
    func reportIncoming(id: UUID) async throws
    func requestAnswer(id: UUID) async throws
    func requestEnd(id: UUID) async throws
    func reportOutgoingStartedConnecting(id: UUID)
    func reportOutgoingConnected(id: UUID)
    func reportEnded(id: UUID)
}

@MainActor
final class CallSession: ObservableObject {
    @Published private(set) var state: CallState = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var elapsedSeconds = 0

    private let api: APIClient
    private let config: AppConfig
    private let audio: AudioEngineHandling
    private let media: MediaTransport
    private let diagnostics = Diagnostics.shared
    private var callKit: CallKitHandling?
    private var pollingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var mediaConnectTask: Task<Void, Never>?
    private var mediaToken: String?
    private var sequence: UInt64 = 0
    private var jitter = JitterBuffer()
    private var activatedCallKitUUID: UUID?
    private var audioStartedForCallKitUUID: UUID?
    private var isOutgoingCall = false
    private var firstSentFrameReported = false
    private var firstRemoteFrameReported = false
    private var endMutationSent = false
    private(set) var activeCallKitUUID: UUID?

    init(config: AppConfig, api: APIClient? = nil, audio: AudioEngineHandling = AudioEngine(), media: MediaTransport? = nil) {
        self.config = config
        self.api = api ?? APIClient(config: config)
        self.audio = audio
        self.media = media ?? WebSocketMediaTransport(baseURL: config.mediaURL)
        self.media.onPacket = { [weak self] packet in Task { @MainActor in self?.receive(packet) } }
        self.media.onDisconnect = { [weak self] callID in Task { @MainActor in self?.mediaDisconnected(callID: callID) } }
        self.media.onDiagnostic = { [weak self] event in Task { @MainActor in self?.recordRuntimeDiagnostic(event.event, status: event.status, callID: event.callID, domain: event.errorDomain, code: event.errorCode) } }
        self.audio.onFrame = { [weak self] frame in Task { @MainActor in self?.sendAudio(frame) } }
        self.audio.onDiagnostic = { [weak self] event in Task { @MainActor in
            guard let self else { return }
            self.recordRuntimeDiagnostic(event.event, status: event.status, callID: self.state.callID, domain: event.errorDomain, code: event.errorCode)
        } }
    }

    func attach(callKit: CallKitHandling) {
        self.callKit = callKit
        callKit.onPrepareAudio = { [weak self] in try self?.audio.configureSession() }
        callKit.onActionFailed = { [weak self] id, stage, error in
            guard let self, let serverID = self.serverCallID(for: id) else { return }
            self.recordCallKitError(stage: stage, callID: serverID, error: error)
            self.fail(serverID, .callKitRejected)
        }
        callKit.onStartApproved = { [weak self] id in Task { @MainActor in
            guard let self, let serverID = self.serverCallID(for: id) else { return }
            self.callKit?.reportOutgoingStartedConnecting(id: id)
            await self.createServerCall(serverID)
        } }
        callKit.onAnswerApproved = { [weak self] id in Task { @MainActor in
            guard let self, let serverID = self.serverCallID(for: id) else { return }
            guard await self.audio.ensureRecordPermission() else { self.fail(serverID, .permissionDenied); return }
            await self.acceptServerCall(serverID)
        } }
        callKit.onEndApproved = { [weak self] id in Task { @MainActor in
            guard let self, let serverID = self.serverCallID(for: id) else { return }
            await self.finishFromSystem(serverID)
        } }
        callKit.onAudioActivated = { [weak self] id in Task { @MainActor in self?.didActivate(callKitUUID: id) } }
        callKit.onAudioDeactivated = { [weak self] id in Task { @MainActor in self?.didDeactivate(callKitUUID: id) } }
        callKit.onProviderReset = { [weak self] id in Task { @MainActor in self?.providerReset(callKitUUID: id) } }
    }

    func startCall() async {
        guard case .idle = state else { return }
        guard await audio.ensureRecordPermission() else { transition(.failed(nil, .permissionDenied)); return }
        prepareNewCall(isOutgoing: true)
        let serverID = UUID(), localID = distinctLocalCallKitUUID(from: serverID)
        activeCallKitUUID = localID
        transition(.outgoingRinging(serverID))
        do { try await callKit?.startOutgoing(id: localID) }
        catch { recordCallKitError(stage: "startOutgoing", callID: serverID, error: error); fail(serverID, .callKitRejected) }
    }

    func handleIncoming(callID: UUID, requestAnswer: Bool) async {
        if state.callID == callID {
            if requestAnswer, case .incomingRinging = state, let local = activeCallKitUUID { await requestAnswerForCurrent(id: callID, local: local) }
            return
        }
        guard case .idle = state else { return }
        let current: CallResponse
        do { current = try await api.call(callID) }
        catch { fail(callID, .serverUnavailable); return }
        guard current.state == .ringing else { fail(callID, current.state == .expired ? .callExpired : .invalidServerState); return }
        await reportIncoming(callID: callID, requestAnswer: requestAnswer)
    }

    func handleIncomingVoIP(callID: UUID) async {
        if state.callID == callID { return }
        guard case .idle = state else { return }
        guard await reportIncoming(callID: callID, requestAnswer: false) else { return }
        Task { [weak self] in await self?.validateIncomingCall(callID) }
    }

    @discardableResult
    private func reportIncoming(callID: UUID, requestAnswer: Bool) async -> Bool {
        prepareNewCall(isOutgoing: false)
        let local = distinctLocalCallKitUUID(from: callID)
        activeCallKitUUID = local
        transition(.incomingRinging(callID))
        do { try await callKit?.reportIncoming(id: local) }
        catch { recordCallKitError(stage: "reportIncoming", callID: callID, error: error); fail(callID, .callKitRejected); return false }
        if requestAnswer { await requestAnswerForCurrent(id: callID, local: local) }
        return !state.isTerminal
    }

    private func requestAnswerForCurrent(id: UUID, local: UUID) async {
        guard await audio.ensureRecordPermission() else { fail(id, .permissionDenied); return }
        do { try await callKit?.requestAnswer(id: local) }
        catch { recordCallKitError(stage: "requestAnswer", callID: id, error: error); fail(id, .callKitRejected) }
    }

    private func validateIncomingCall(_ callID: UUID) async {
        do {
            let current = try await api.call(callID)
            guard state.callID == callID else { return }
            switch current.state {
            case .ringing, .accepted: return
            case .expired: fail(callID, .callExpired)
            default: fail(callID, .invalidServerState)
            }
        } catch { if state.callID == callID { fail(callID, .serverUnavailable) } }
    }

    func accept() async {
        guard case let .incomingRinging(id) = state, let local = activeCallKitUUID else { return }
        await requestAnswerForCurrent(id: id, local: local)
    }

    func reject() async {
        guard case let .incomingRinging(id) = state else { return }
        do { _ = try await api.mutate("reject", callID: id); transition(.ending(id)); reportCallKitEnded(); transition(.ended(id)); clearCallIdentity() }
        catch { fail(id, .serverUnavailable) }
    }

    func cancel() async {
        guard case let .outgoingRinging(id) = state else { return }
        do { _ = try await api.mutate("cancel", callID: id) } catch { }
        await end(id)
    }

    func endCall() async {
        guard let id = state.callID else { return }
        guard let local = activeCallKitUUID else { await finishFromSystem(id); return }
        do { try await callKit?.requestEnd(id: local) }
        catch { recordCallKitError(stage: "requestEnd", callID: id, error: error); await finishFromSystem(id) }
    }

    func reset() { guard state.isTerminal else { return }; clearCallIdentity(); transition(.idle) }
    func toggleMute() { isMuted.toggle(); audio.setMuted(isMuted) }

    private func createServerCall(_ id: UUID) async {
        guard state.callID == id else { return }
        do {
            let response = try await api.create(callID: id, requestID: UUID())
            guard response.state == .ringing else { fail(id, .invalidServerState); return }
            pollingTask = Task { [weak self] in await self?.poll(id) }
        } catch { fail(id, .serverUnavailable) }
    }

    private func poll(_ id: UUID) async {
        let deadline = Date().addingTimeInterval(CallTimeouts.ring)
        while !Task.isCancelled, Date() < deadline, state.callID == id {
            do {
                let response = try await api.call(id)
                switch response.state {
                case .accepted: mediaToken = response.mediaToken; transition(.connecting(id)); beginActivationWatchdog(id); return
                case .rejected: fail(id, .callRejected); return
                case .cancelled: fail(id, .callCancelled); return
                case .expired: fail(id, .callExpired); return
                case .ended: transition(.ending(id)); await end(id); return
                case .ringing: break
                }
            } catch { }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !Task.isCancelled, state.callID == id { fail(id, .callExpired) }
    }

    private func acceptServerCall(_ id: UUID) async {
        guard state.callID == id else { return }
        do {
            let response = try await api.mutate("accept", callID: id)
            guard response.state == .accepted, let token = response.mediaToken else { fail(id, response.state == .expired ? .callExpired : .invalidServerState); return }
            mediaToken = token; transition(.connecting(id)); beginActivationWatchdog(id)
        } catch { fail(id, .serverUnavailable) }
    }

    private func didActivate(callKitUUID: UUID) {
        guard activeCallKitUUID == callKitUUID, state.callID != nil else { return }
        activatedCallKitUUID = callKitUUID
        recordRuntimeDiagnostic("callkit_did_activate", status: "success", callID: state.callID)
        activateAudioIfReady(callKitUUID: callKitUUID)
    }

    private func didDeactivate(callKitUUID: UUID?) {
        guard callKitUUID == nil || activatedCallKitUUID == callKitUUID else { return }
        activatedCallKitUUID = nil; audioStartedForCallKitUUID = nil; audio.stop()
        recordRuntimeDiagnostic("callkit_did_deactivate", status: "success", callID: state.callID)
    }

    private func activateAudioIfReady(callKitUUID: UUID) {
        guard activeCallKitUUID == callKitUUID, activatedCallKitUUID == callKitUUID, audioStartedForCallKitUUID != callKitUUID,
              case let .connecting(id) = state, let token = mediaToken else { return }
        watchdogTask?.cancel(); audioStartedForCallKitUUID = callKitUUID; mediaConnectTask?.cancel()
        mediaConnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.audio.start()
                guard self.activeCallKitUUID == callKitUUID, self.state.callID == id else { self.audio.stop(); return }
                try await self.media.connect(callID: id, role: self.config.role, token: token)
                guard self.activeCallKitUUID == callKitUUID, self.state.callID == id else { await self.media.close(); self.audio.stop(); return }
                self.transition(.active(id)); self.startDurationTimer()
                if self.isOutgoingCall { self.callKit?.reportOutgoingConnected(id: callKitUUID) }
            } catch {
                guard self.state.callID == id else { return }
                self.fail(id, (error as? CallFailure) == .audioFailed ? .audioFailed : .mediaConnectionFailed)
            }
        }
    }

    private func beginActivationWatchdog(_ id: UUID) {
        guard let local = activeCallKitUUID else { fail(id, .callKitRejected); return }
        if activatedCallKitUUID == local { activateAudioIfReady(callKitUUID: local); return }
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CallTimeouts.audioActivation * 1_000_000_000))
            guard let self, !Task.isCancelled, self.state.callID == id, self.audioStartedForCallKitUUID == nil else { return }
            self.fail(id, .audioActivationTimeout)
        }
    }

    private func sendAudio(_ payload: Data) {
        guard case let .active(id) = state else { return }
        sequence &+= 1
        let packet = AudioPacket(type: .audio, callID: id, sequence: sequence, timestampMicroseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000), payload: payload)
        Task { [weak self] in
            do {
                try await self?.media.send(packet)
                await MainActor.run {
                    guard let self, self.state.callID == id, !self.firstSentFrameReported else { return }
                    self.firstSentFrameReported = true; self.recordRuntimeDiagnostic("first_network_audio_frame_sent", status: "bytes=\(payload.count)", callID: id)
                }
            } catch { }
        }
    }

    private func receive(_ packet: AudioPacket) {
        guard packet.callID == state.callID else { return }
        if !firstRemoteFrameReported { firstRemoteFrameReported = true; recordRuntimeDiagnostic("first_remote_audio_frame_received", status: "bytes=\(packet.payload.count)", callID: packet.callID) }
        jitter.insert(packet); if let ready = jitter.pop() { audio.play(ready.payload) }
    }

    private func mediaDisconnected(callID: UUID) {
        guard state.callID == callID, case .active = state, let token = mediaToken else { return }
        transition(.reconnecting(callID)); recordRuntimeDiagnostic("reconnect_started", status: "started", callID: callID)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let started = Date(); var delay: TimeInterval = 0.25
            while !Task.isCancelled, Date().timeIntervalSince(started) < CallTimeouts.reconnectTotal, self.state.callID == callID {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                do { try await self.media.connect(callID: callID, role: self.config.role, token: token); guard self.state.callID == callID else { return }; self.transition(.active(callID)); self.recordRuntimeDiagnostic("reconnect_succeeded", status: "success", callID: callID); return }
                catch { delay = min(delay * 2, 2) }
            }
            guard self.state.callID == callID else { return }
            self.recordRuntimeDiagnostic("reconnect_failed", status: "failed", callID: callID); self.fail(callID, .networkLost)
        }
    }

    private func finishFromSystem(_ id: UUID) async { guard state.callID == id else { return }; await sendEndOnce(id); await end(id) }
    private func end(_ id: UUID) async { cancelWork(); if !state.isTerminal { transition(.ending(id)) }; await media.close(); audio.stop(); reportCallKitEnded(); transition(.ended(id)); clearCallIdentity() }
    private func fail(_ id: UUID?, _ failure: CallFailure) { cancelWork(); audio.stop(); Task { await media.close() }; reportCallKitEnded(); transition(.failed(id, failure)); clearCallIdentity() }

    private func providerReset(callKitUUID: UUID?) {
        guard callKitUUID == nil || callKitUUID == activeCallKitUUID else { return }
        let id = state.callID
        if let id, !state.isTerminal, !endMutationSent {
            endMutationSent = true
            Task { [api] in do { _ = try await api.mutate("end", callID: id) } catch { } }
        }
        cancelWork(); audio.stop(); Task { await media.close() }
        if !state.isTerminal && state != .idle { transition(.failed(id, .callKitRejected)) }
        clearCallIdentity()
    }

    private func cancelWork() {
        pollingTask?.cancel(); reconnectTask?.cancel(); watchdogTask?.cancel(); durationTask?.cancel(); mediaConnectTask?.cancel()
        pollingTask = nil; reconnectTask = nil; watchdogTask = nil; durationTask = nil; mediaConnectTask = nil
    }

    private func prepareNewCall(isOutgoing: Bool) {
        cancelWork(); audio.stop(); activatedCallKitUUID = nil; audioStartedForCallKitUUID = nil
        mediaToken = nil; sequence = 0; jitter = JitterBuffer(); isMuted = false; elapsedSeconds = 0
        firstSentFrameReported = false; firstRemoteFrameReported = false; endMutationSent = false; self.isOutgoingCall = isOutgoing
    }

    private func transition(_ next: CallState) { guard CallStateTransition.isLegal(from: state, to: next) else { return }; diagnostics.record(role: config.role, callID: next.callID, category: "state", value: String(describing: next)); state = next }
    private func recordCallKitError(stage: String, callID: UUID, error: Error) { let value = error as NSError; diagnostics.record(role: config.role, callID: callID, category: "callKitError", value: "stage=\(stage) domain=\(value.domain) code=\(value.code)"); Task { await api.reportCallKitError(stage: stage, callID: callID, error: error) } }
    private func recordRuntimeDiagnostic(_ event: String, status: String, callID: UUID?, domain: String? = nil, code: Int? = nil) { diagnostics.record(role: config.role, callID: callID, category: event, value: status); Task { await api.reportRuntimeDiagnostic(event: event, status: status, callID: callID, errorDomain: domain, errorCode: code) } }
    private func serverCallID(for local: UUID) -> UUID? { activeCallKitUUID == local ? state.callID : nil }
    private func distinctLocalCallKitUUID(from server: UUID) -> UUID { var value = UUID(); while value == server { value = UUID() }; return value }
    private func reportCallKitEnded() { if let local = activeCallKitUUID { callKit?.reportEnded(id: local) } }
    private func clearCallIdentity() { activeCallKitUUID = nil; activatedCallKitUUID = nil; audioStartedForCallKitUUID = nil; mediaToken = nil; isOutgoingCall = false }
    private func sendEndOnce(_ id: UUID) async { guard !endMutationSent else { return }; endMutationSent = true; do { _ = try await api.mutate("end", callID: id) } catch { } }
    private func startDurationTimer() { elapsedSeconds = 0; durationTask?.cancel(); durationTask = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); if !Task.isCancelled { self?.elapsedSeconds += 1 } } } }
}
