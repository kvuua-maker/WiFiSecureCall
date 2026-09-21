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
            self.recordCallKitError(stage: stage, callID: id, error: error)
            self.fail(id, .callKitRejected)
        }
        callKit.onStartApproved = { [weak self] id in Task { @MainActor in await self?.createServerCall(id) } }
        callKit.onAnswerApproved = { [weak self] id in Task { @MainActor in await self?.acceptServerCall(id) } }
        callKit.onEndApproved = { [weak self] id in Task { @MainActor in await self?.finishFromSystem(id) } }
        callKit.onAudioActivated = { [weak self] in Task { @MainActor in self?.activateAudio() } }
        callKit.onAudioDeactivated = { [weak self] in Task { @MainActor in self?.audio.stop() } }
    }

    func startCall() async {
        guard case .idle = state else { return }
        let id = UUID()
        transition(.outgoingRinging(id))
        do { try await callKit?.startOutgoing(id: id) }
        catch {
            recordCallKitError(stage: "startOutgoing", callID: id, error: error)
            fail(id, .callKitRejected)
        }
    }

    func handleIncoming(callID: UUID, requestAnswer: Bool) async {
        guard case .idle = state else { return }
        let current: CallResponse
        do { current = try await api.call(callID) }
        catch { fail(callID, .serverUnavailable); return }
        guard current.state == .ringing else { fail(callID, current.state == .expired ? .callExpired : .invalidServerState); return }
        transition(.incomingRinging(callID))
        do { try await callKit?.reportIncoming(id: callID) }
        catch {
            recordCallKitError(stage: "reportIncoming", callID: callID, error: error)
            fail(callID, .callKitRejected)
            return
        }
        if requestAnswer {
            do { try await callKit?.requestAnswer(id: callID) }
            catch {
                recordCallKitError(stage: "requestAnswer", callID: callID, error: error)
                fail(callID, .callKitRejected)
            }
        }
    }

    func accept() async {
        guard case let .incomingRinging(id) = state else { return }
        do { try await callKit?.requestAnswer(id: id) }
        catch {
            recordCallKitError(stage: "requestAnswer", callID: id, error: error)
            fail(id, .callKitRejected)
        }
    }

    func reject() async {
        guard case let .incomingRinging(id) = state else { return }
        do { _ = try await api.mutate("reject", callID: id); transition(.ending(id)); callKit?.reportEnded(id: id); transition(.ended(id)) }
        catch { fail(id, .serverUnavailable) }
    }

    func cancel() async {
        guard case let .outgoingRinging(id) = state else { return }
        do { _ = try await api.mutate("cancel", callID: id) } catch { }
        await end(id)
    }

    func endCall() async {
        guard let id = state.callID else { return }
        do { try await callKit?.requestEnd(id: id) }
        catch {
            recordCallKitError(stage: "requestEnd", callID: id, error: error)
            await finishFromSystem(id)
        }
    }

    func reset() {
        guard state.isTerminal else { return }
        transition(.idle)
    }

    func toggleMute() { isMuted.toggle(); audio.setMuted(isMuted) }

    private func createServerCall(_ id: UUID) async {
        do {
            let response = try await api.create(callID: id, requestID: id)
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
        await media.close(); audio.stop(); callKit?.reportEnded(id: id)
        transition(.ended(id))
    }

    private func fail(_ id: UUID?, _ failure: CallFailure) {
        pollingTask?.cancel(); reconnectTask?.cancel(); watchdogTask?.cancel(); durationTask?.cancel()
        audio.stop(); Task { await media.close() }
        transition(.failed(id, failure))
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
    }

    private func startDurationTimer() {
        elapsedSeconds = 0; durationTask?.cancel()
        durationTask = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000); if !Task.isCancelled { self?.elapsedSeconds += 1 } }
        }
    }
}
