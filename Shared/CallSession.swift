import Foundation

@MainActor
protocol CallKitHandling: AnyObject {
    var onPrepareAudio: (() throws -> Void)? { get set }
    var onActionFailed: ((UUID, String, Error) -> Void)? { get set }
    var onStartApproved: ((UUID) -> Void)? { get set }
    var onAnswerApproved: ((UUID) -> Void)? { get set }
    var onEndApproved: ((UUID) -> Void)? { get set }
    var onAudioActivated: (() -> Void)? { get set }
    var onAudioDeactivated: (() -> Void)? { get set }
    func startOutgoing(id: UUID) async throws
    func reportIncoming(id: UUID) async throws
    func requestAnswer(id: UUID) async throws
    func requestEnd(id: UUID) async throws
    func reportEnded(id: UUID)
}

@MainActor
final class CallSession: ObservableObject {
    @Published private(set) var state: CallState = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var elapsedSeconds = 0

    private let api: APIClient
    private let config: AppConfig
    private let audio: AudioEngine
    private let media: MediaTransport
    private let diagnostics = Diagnostics.shared
    private var callKit: CallKitHandling?
    private var pollingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var mediaToken: String?
    private var sequence: UInt64 = 0
    private var jitter = JitterBuffer()
    private var audioActivated = false
    private(set) var activeCallKitUUID: UUID?

    init(config: AppConfig, api: APIClient? = nil, audio: AudioEngine = AudioEngine(), media: MediaTransport? = nil) {
        self.config = config
        self.api = api ?? APIClient(config: config)
        self.audio = audio
        self.media = media ?? WebSocketMediaTransport(baseURL: config.mediaURL)
        self.media.onPacket = { [weak self] packet in Task { @MainActor in self?.receive(packet) } }
        self.media.onDisconnect = { [weak self] in Task { @MainActor in self?.mediaDisconnected() } }
        self.audio.onFrame = { [weak self] frame in Task { @MainActor in self?.sendAudio(frame) } }
    }

    func attach(callKit: CallKitHandling) {
        self.callKit = callKit
        callKit.onPrepareAudio = { [weak self] in
            guard let self else { return }
            try self.audio.configureSession()
        }
        callKit.onActionFailed = { [weak self] id, stage, error in
            guard let self else { return }
            guard let serverCallID = self.serverCallID(for: id) else { return }
            self.recordCallKitError(stage: stage, callID: serverCallID, error: error)
            self.fail(serverCallID, .callKitRejected)
        }
        callKit.onStartApproved = { [weak self] id in
            Task { @MainActor in
                guard let serverCallID = self?.serverCallID(for: id) else { return }
                await self?.createServerCall(serverCallID)
            }
        }
        callKit.onAnswerApproved = { [weak self] id in
            Task { @MainActor in
                guard let serverCallID = self?.serverCallID(for: id) else { return }
                await self?.acceptServerCall(serverCallID)
            }
        }
        callKit.onEndApproved = { [weak self] id in
            Task { @MainActor in
                guard let serverCallID = self?.serverCallID(for: id) else { return }
                await self?.finishFromSystem(serverCallID)
            }
        }
        callKit.onAudioActivated = { [weak self] in Task { @MainActor in self?.activateAudio() } }
        callKit.onAudioDeactivated = { [weak self] in Task { @MainActor in self?.audio.stop() } }
    }

    func startCall() async {
        guard case .idle = state else { return }
        let serverCallID = UUID()
        let localCallKitUUID = distinctLocalCallKitUUID(from: serverCallID)
        activeCallKitUUID = localCallKitUUID
        transition(.outgoingRinging(serverCallID))
        do { try await callKit?.startOutgoing(id: localCallKitUUID) }
        catch {
            recordCallKitError(stage: "startOutgoing", callID: serverCallID, error: error)
            fail(serverCallID, .callKitRejected)
        }
    }

    func handleIncoming(callID: UUID, requestAnswer: Bool) async {
        if state.callID == callID {
            if requestAnswer, case .incomingRinging = state, let localCallKitUUID = activeCallKitUUID {
                do { try await callKit?.requestAnswer(id: localCallKitUUID) }
                catch {
                    recordCallKitError(stage: "requestAnswer", callID: callID, error: error)
                    fail(callID, .callKitRejected)
                }
            }
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
        let reported = await reportIncoming(callID: callID, requestAnswer: false)
        guard reported else { return }
        Task { [weak self] in await self?.validateIncomingCall(callID) }
    }

    @discardableResult
    private func reportIncoming(callID: UUID, requestAnswer: Bool) async -> Bool {
        let localCallKitUUID = distinctLocalCallKitUUID(from: callID)
        activeCallKitUUID = localCallKitUUID
        transition(.incomingRinging(callID))
        do { try await callKit?.reportIncoming(id: localCallKitUUID) }
        catch {
            recordCallKitError(stage: "reportIncoming", callID: callID, error: error)
            fail(callID, .callKitRejected)
            return false
        }
        if requestAnswer {
            do { try await callKit?.requestAnswer(id: localCallKitUUID) }
            catch {
                recordCallKitError(stage: "requestAnswer", callID: callID, error: error)
                fail(callID, .callKitRejected)
                return false
            }
        }
        return true
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
        } catch {
            guard state.callID == callID else { return }
            fail(callID, .serverUnavailable)
        }
    }

    func accept() async {
        guard case let .incomingRinging(id) = state else { return }
        guard let localCallKitUUID = activeCallKitUUID else { fail(id, .callKitRejected); return }
        do { try await callKit?.requestAnswer(id: localCallKitUUID) }
        catch {
            recordCallKitError(stage: "requestAnswer", callID: id, error: error)
            fail(id, .callKitRejected)
        }
    }

    func reject() async {
        guard case let .incomingRinging(id) = state else { return }
        do {
            _ = try await api.mutate("reject", callID: id)
            transition(.ending(id))
            reportCallKitEnded()
            transition(.ended(id))
            clearCallIdentity()
        }
        catch { fail(id, .serverUnavailable) }
    }

    func cancel() async {
        guard case let .outgoingRinging(id) = state else { return }
        do { _ = try await api.mutate("cancel", callID: id) } catch { }
        await end(id)
    }

    func endCall() async {
        guard let id = state.callID else { return }
        guard let localCallKitUUID = activeCallKitUUID else { await finishFromSystem(id); return }
        do { try await callKit?.requestEnd(id: localCallKitUUID) }
        catch {
            recordCallKitError(stage: "requestEnd", callID: id, error: error)
            await finishFromSystem(id)
        }
    }

    func reset() {
        guard state.isTerminal else { return }
        clearCallIdentity()
        transition(.idle)
    }

    func toggleMute() { isMuted.toggle(); audio.setMuted(isMuted) }

    private func createServerCall(_ id: UUID) async {
        do {
            let response = try await api.create(callID: id, requestID: UUID())
            guard response.state == .ringing else { fail(id, .invalidServerState); return }
            pollingTask = Task { [weak self] in await self?.poll(id) }
        } catch { fail(id, .serverUnavailable) }
    }

    private func poll(_ id: UUID) async {
        let deadline = Date().addingTimeInterval(CallTimeouts.ring)
        while !Task.isCancelled, Date() < deadline {
            do {
                let response = try await api.call(id)
                switch response.state {
                case .accepted:
                    mediaToken = response.mediaToken
                    transition(.connecting(id)); beginActivationWatchdog(id); return
                case .rejected: fail(id, .callRejected); return
                case .cancelled: fail(id, .callCancelled); return
                case .expired: fail(id, .callExpired); return
                case .ended: transition(.ending(id)); await end(id); return
                case .ringing: break
                }
            } catch { }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !Task.isCancelled { fail(id, .callExpired) }
    }

    private func acceptServerCall(_ id: UUID) async {
        do {
            let response = try await api.mutate("accept", callID: id)
            guard response.state == .accepted, let token = response.mediaToken else { fail(id, response.state == .expired ? .callExpired : .invalidServerState); return }
            mediaToken = token
            transition(.connecting(id))
            beginActivationWatchdog(id)
        } catch { fail(id, .serverUnavailable) }
    }

    private func activateAudio() {
        audioActivated = true
        watchdogTask?.cancel()
        guard case let .connecting(id) = state, let token = mediaToken else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.audio.start()
                try await self.media.connect(callID: id, role: self.config.role, token: token)
                self.transition(.active(id)); self.startDurationTimer()
            } catch { self.fail(id, .mediaConnectionFailed) }
        }
    }

    private func beginActivationWatchdog(_ id: UUID) {
        if audioActivated { activateAudio(); return }
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CallTimeouts.audioActivation * 1_000_000_000))
            guard let self, !Task.isCancelled, case .connecting = self.state else { return }
            self.fail(id, .audioActivationTimeout)
        }
    }

    private func sendAudio(_ payload: Data) {
        guard case let .active(id) = state else { return }
        sequence &+= 1
        let timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        let packet = AudioPacket(type: .audio, callID: id, sequence: sequence, timestampMicroseconds: timestamp, payload: payload)
        Task { [weak self] in try? await self?.media.send(packet) }
    }

    private func receive(_ packet: AudioPacket) {
        guard packet.callID == state.callID else { return }
        jitter.insert(packet)
        if let ready = jitter.pop() { audio.play(ready.payload) }
    }

    private func mediaDisconnected() {
        guard case let .active(id) = state, let token = mediaToken else { return }
        transition(.reconnecting(id))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let started = Date(); var delay: TimeInterval = 0.25
            while !Task.isCancelled, Date().timeIntervalSince(started) < CallTimeouts.reconnectTotal {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                do { try await self.media.connect(callID: id, role: self.config.role, token: token); self.transition(.active(id)); return }
                catch { delay = min(delay * 2, 2) }
            }
            self.fail(id, .networkLost)
        }
    }

    private func finishFromSystem(_ id: UUID) async {
        do { _ = try await api.mutate("end", callID: id) } catch { }
        await end(id)
    }

    private func end(_ id: UUID) async {
        pollingTask?.cancel(); reconnectTask?.cancel(); watchdogTask?.cancel(); durationTask?.cancel()
        if !state.isTerminal { transition(.ending(id)) }
        await media.close(); audio.stop(); reportCallKitEnded()
        transition(.ended(id))
        clearCallIdentity()
    }

    private func fail(_ id: UUID?, _ failure: CallFailure) {
        pollingTask?.cancel(); reconnectTask?.cancel(); watchdogTask?.cancel(); durationTask?.cancel()
        audio.stop(); Task { await media.close() }; reportCallKitEnded()
        transition(.failed(id, failure))
        clearCallIdentity()
    }

    private func transition(_ next: CallState) {
        guard CallStateTransition.isLegal(from: state, to: next) else { return }
        diagnostics.record(role: config.role, callID: next.callID, category: "state", value: String(describing: next))
        state = next
    }

    private func recordCallKitError(stage: String, callID: UUID, error: Error) {
        let value = error as NSError
        diagnostics.record(
            role: config.role,
            callID: callID,
            category: "callKitError",
            value: "stage=\(stage) domain=\(value.domain) code=\(value.code)"
        )
        Task { await api.reportCallKitError(stage: stage, error: error) }
    }

    private func serverCallID(for localCallKitUUID: UUID) -> UUID? {
        guard activeCallKitUUID == localCallKitUUID else { return nil }
        return state.callID
    }

    private func distinctLocalCallKitUUID(from serverCallID: UUID) -> UUID {
        var value = UUID()
        while value == serverCallID { value = UUID() }
        return value
    }

    private func reportCallKitEnded() {
        guard let localCallKitUUID = activeCallKitUUID else { return }
        callKit?.reportEnded(id: localCallKitUUID)
    }

    private func clearCallIdentity() {
        activeCallKitUUID = nil
    }

    private func startDurationTimer() {
        elapsedSeconds = 0; durationTask?.cancel()
        durationTask = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); if !Task.isCancelled { self?.elapsedSeconds += 1 } }
        }
    }
}
