import Foundation

final class WebSocketMediaTransport: NSObject, MediaTransport, @unchecked Sendable {
    var onPacket: (@Sendable (AudioPacket) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?
    private let baseURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CallTimeouts.initialMedia
        self.session = URLSession(configuration: configuration)
    }

    func connect(callID: UUID, role: DeviceRole, token: String) async throws {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "callID", value: callID.uuidString.lowercased()), URLQueryItem(name: "role", value: role.rawValue)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = CallTimeouts.initialMedia
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        lock.lock(); task = socket; lock.unlock()
        socket.resume()
        try await socket.sendPing()
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
    }

    func send(_ packet: AudioPacket) async throws {
        lock.lock(); let socket = task; lock.unlock()
        guard let socket else { throw CallFailure.mediaConnectionFailed }
        try await socket.send(.data(packet.encode()))
    }

    func close() async {
        receiveTask?.cancel(); receiveTask = nil
        lock.lock(); let socket = task; task = nil; lock.unlock()
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                if case let .data(data) = message, let packet = AudioPacket.decode(data) { onPacket?(packet) }
            }
        } catch {
            if !Task.isCancelled { onDisconnect?() }
        }
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
