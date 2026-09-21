import Foundation

final class WebSocketMediaTransport: NSObject, MediaTransport, @unchecked Sendable {
    var onPacket: (@Sendable (AudioPacket) -> Void)?
    var onDisconnect: (@Sendable (UUID) -> Void)?
    var onDiagnostic: (@Sendable (MediaTransportDiagnostic) -> Void)?
    private let baseURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var generation: UUID?
    private var activeCallID: UUID?

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CallTimeouts.initialMedia
        self.session = URLSession(configuration: configuration)
    }

    func connect(callID: UUID, role: DeviceRole, token: String) async throws {
        emit("media_connect_started", "started", callID: callID)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "callID", value: callID.uuidString.lowercased()), URLQueryItem(name: "role", value: role.rawValue)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = CallTimeouts.initialMedia
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        let newGeneration = UUID()
        lock.lock()
        let previous = task
        let previousReceive = receiveTask
        generation = newGeneration
        activeCallID = callID
        task = socket
        receiveTask = nil
        lock.unlock()
        previousReceive?.cancel()
        previous?.cancel(with: .normalClosure, reason: nil)
        socket.resume()
        do {
            try await socket.sendPing()
            emit("media_connect_succeeded", "success", callID: callID)
        } catch {
            let value = error as NSError
            emit("media_connect_failed", "failed", callID: callID, error: value)
            socket.cancel(with: .goingAway, reason: nil)
            lock.lock()
            if generation == newGeneration { task = nil; generation = nil; activeCallID = nil }
            lock.unlock()
            throw error
        }
        let receiver = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(socket, callID: callID, generation: newGeneration)
        }
        lock.lock()
        if generation == newGeneration { receiveTask = receiver }
        lock.unlock()
    }

    func send(_ packet: AudioPacket) async throws {
        lock.lock(); let socket = task; lock.unlock()
        guard let socket else { throw CallFailure.mediaConnectionFailed }
        try await socket.send(.data(packet.encode()))
    }

    func close() async {
        lock.lock()
        let socket = task, receiver = receiveTask
        task = nil; receiveTask = nil; generation = nil; activeCallID = nil
        lock.unlock()
        receiver?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask, callID: UUID, generation expected: UUID) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard isCurrent(expected, socket: socket) else { return }
                if case let .data(data) = message, let packet = AudioPacket.decode(data), packet.callID == callID { onPacket?(packet) }
            }
        } catch {
            guard !Task.isCancelled, isCurrent(expected, socket: socket) else { return }
            let value = error as NSError
            let closeCode = socket.closeCode.rawValue
            let reason = sanitized(socket.closeReason)
            emit("media_disconnected", "closeCode=\(closeCode) reason=\(reason)", callID: callID, error: value)
            lock.lock()
            if generation == expected { task = nil; receiveTask = nil; generation = nil; activeCallID = nil }
            lock.unlock()
            onDisconnect?(callID)
        }
    }

    private func isCurrent(_ expected: UUID, socket: URLSessionWebSocketTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == expected && task === socket
    }

    private func sanitized(_ data: Data?) -> String {
        guard let data, var value = String(data: data, encoding: .utf8) else { return "none" }
        value = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(value.prefix(80))
    }

    private func emit(_ event: String, _ status: String, callID: UUID, error: NSError? = nil) {
        onDiagnostic?(.init(event: event, status: status, callID: callID, errorDomain: error?.domain, errorCode: error?.code))
    }
}

private extension URLSessionWebSocketTask {
    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
