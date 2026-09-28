import Foundation

final class WebSocketMediaTransport: NSObject, MediaTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onPacket: (@Sendable (AudioPacket, UUID) -> Void)?
    var onDisconnect: (@Sendable (MediaDisconnect) -> Void)?
    var onPeerReady: (@Sendable (UUID, UUID) -> Void)?
    var onDiagnostic: (@Sendable (MediaTransportDiagnostic) -> Void)?

    private let baseURL: URL
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CallTimeouts.initialMedia
        configuration.timeoutIntervalForResource = 0
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var activeCallID: UUID?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var intentionalClose: Set<UUID> = []
    private var taskEpoch: [ObjectIdentifier: UUID] = [:]
    private var epochCallID: [UUID: UUID] = [:]
    private var closeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(baseURL: URL) { self.baseURL = baseURL; super.init() }

    func connect(callID: UUID, peer: MediaPeerIdentity, token: String) async throws -> UUID {
        emit("media_connect_started", "started", callID: callID)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw CallFailure.mediaConnectionFailed }
        components.queryItems = [
            URLQueryItem(name: "callID", value: callID.uuidString.lowercased()),
            URLQueryItem(name: peer.queryName, value: peer.queryValue),
            URLQueryItem(name: "protocolVersion", value: String(peer.protocolVersion))
        ]
        guard let url = components.url, url.scheme == "wss" else { throw CallFailure.mediaConnectionFailed }
        var request = URLRequest(url: url)
        request.timeoutInterval = CallTimeouts.initialMedia
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = AudioPacket.maximumEncodedSize
        let epoch = UUID()

        let previous = replaceCurrent(with: socket, callID: callID, connectionID: epoch)
        previous.1?.cancel(); previous.0?.cancel(with: .goingAway, reason: nil)
        socket.resume()
        do {
            try await waitForOpen(socket: socket, connectionID: epoch)
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            clearIfCurrent(epoch)
            let value = error as NSError
            emit("media_connect_failed", "failed", callID: callID, error: value)
            throw error
        }
        guard isCurrent(epoch, socket: socket) else { throw CancellationError() }
        emit("media_connect_succeeded", "success", callID: callID)
        let receiver = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(socket, callID: callID, connectionID: epoch)
        }
        let heartbeat = Task { [weak self] in
            guard let self else { return }
            await self.heartbeatLoop(socket, callID: callID, connectionID: epoch)
        }
        lock.withLock { if connectionID == epoch { receiveTask = receiver; heartbeatTask = heartbeat } }
        return epoch
    }

    func send(_ packet: AudioPacket, connectionID expected: UUID) async throws {
        let socket = lock.withLock { self.connectionID == expected && self.activeCallID == packet.callID ? task : nil }
        guard let socket else { throw CallFailure.mediaConnectionFailed }
        try await socket.send(.data(packet.encode()))
        guard isCurrent(expected, socket: socket) else { throw CancellationError() }
    }

    func close(connectionID expected: UUID?) async {
        let values: (URLSessionWebSocketTask?, Task<Void, Never>?, Task<Void, Never>?, UUID?) = lock.withLock {
            guard expected == nil || connectionID == expected else { return (nil, nil, nil, nil) }
            let values = (task, receiveTask, heartbeatTask, connectionID)
            if let id = connectionID { intentionalClose.insert(id) }
            task = nil; receiveTask = nil; heartbeatTask = nil; connectionID = nil; activeCallID = nil
            return values
        }
        values.1?.cancel(); values.2?.cancel()
        guard let socket = values.0, let id = values.3 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let tracked = lock.withLock { () -> Bool in
                guard taskEpoch[ObjectIdentifier(socket)] == id else { return false }
                closeWaiters[id] = continuation
                return true
            }
            guard tracked else { continuation.resume(); return }
            socket.cancel(with: .normalClosure, reason: nil)
            Task { [weak self, weak socket] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let socket else { return }
                self.completeCloseTimeout(id: id, socket: socket)
            }
        }
    }

    private func waitForOpen(socket: URLSessionWebSocketTask, connectionID: UUID) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CancellationError() }
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.lock.withLock {
                            guard self.connectionID == connectionID, self.task === socket else { continuation.resume(throwing: CancellationError()); return }
                            self.openContinuation = continuation
                        }
                    }
                } onCancel: { self.cancelOpen(connectionID) }
            }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(CallTimeouts.initialMedia * 1_000_000_000)); throw CallFailure.mediaConnectionFailed }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask, callID: UUID, connectionID: UUID) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard isCurrent(connectionID, socket: socket) else { return }
                guard case let .data(data) = message, let packet = AudioPacket.decode(data), packet.callID == callID else { continue }
                if packet.type == .ping { onPeerReady?(callID, connectionID) }
                else if packet.type == .audio { onPacket?(packet, connectionID) }
                else if packet.type == .end { onDisconnect?(.init(callID: callID, connectionID: connectionID, closeCode: nil, reason: .remoteClosed)) }
            }
        } catch {
            guard !Task.isCancelled, isCurrent(connectionID, socket: socket) else { return }
            let value = error as NSError
            emit("media_disconnected", "closeCode=\(socket.closeCode.rawValue) reason=\(sanitized(socket.closeReason))", callID: callID, error: value)
            clearIfCurrent(connectionID)
            onDisconnect?(.init(callID: callID, connectionID: connectionID, closeCode: socket.closeCode.rawValue, reason: classify(socket.closeCode)))
        }
    }

    private func heartbeatLoop(_ socket: URLSessionWebSocketTask, callID: UUID, connectionID: UUID) async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 25_000_000_000); try await socket.sendPing() }
            catch {
                guard isCurrent(connectionID, socket: socket) else { return }
                clearIfCurrent(connectionID)
                onDisconnect?(.init(callID: callID, connectionID: connectionID, closeCode: socket.closeCode.rawValue, reason: .transientNetwork)); return
            }
            guard isCurrent(connectionID, socket: socket) else { return }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in guard task === webSocketTask else { return nil }; let value = openContinuation; openContinuation = nil; return value }
        continuation?.resume(returning: ())
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let values = lock.withLock { () -> (UUID?, UUID?, Bool, CheckedContinuation<Void, Never>?) in
            let key = ObjectIdentifier(webSocketTask)
            let epoch = taskEpoch.removeValue(forKey: key)
            let callID = epoch.flatMap { epochCallID.removeValue(forKey: $0) }
            let intentional = epoch.map { intentionalClose.remove($0) != nil } ?? false
            let waiter = epoch.flatMap { closeWaiters.removeValue(forKey: $0) }
            if task === webSocketTask { task = nil; receiveTask = nil; heartbeatTask = nil; connectionID = nil; activeCallID = nil }
            return (epoch, callID, intentional, waiter)
        }
        values.3?.resume()
        if let epoch = values.0, let callID = values.1, !values.2 { onDisconnect?(.init(callID: callID, connectionID: epoch, closeCode: closeCode.rawValue, reason: classify(closeCode))) }
    }

    private func replaceCurrent(with socket: URLSessionWebSocketTask, callID: UUID, connectionID: UUID) -> (URLSessionWebSocketTask?, Task<Void, Never>?) {
        lock.withLock {
            let previous = (task, receiveTask)
            if let old = self.connectionID { intentionalClose.insert(old) }
            openContinuation?.resume(throwing: CancellationError()); openContinuation = nil
            task = socket; activeCallID = callID; self.connectionID = connectionID
            taskEpoch[ObjectIdentifier(socket)] = connectionID; epochCallID[connectionID] = callID
            receiveTask = nil; heartbeatTask?.cancel(); heartbeatTask = nil
            return previous
        }
    }
    private func cancelOpen(_ expected: UUID) { let value = lock.withLock { () -> CheckedContinuation<Void, Error>? in guard connectionID == expected else { return nil }; let result = openContinuation; openContinuation = nil; return result }; value?.resume(throwing: CancellationError()) }
    private func clearIfCurrent(_ expected: UUID) { lock.withLock { guard connectionID == expected else { return }; task = nil; receiveTask = nil; heartbeatTask?.cancel(); heartbeatTask = nil; connectionID = nil; activeCallID = nil } }
    private func completeCloseTimeout(id: UUID, socket: URLSessionWebSocketTask) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard taskEpoch[ObjectIdentifier(socket)] == id else { return closeWaiters.removeValue(forKey: id) }
            taskEpoch.removeValue(forKey: ObjectIdentifier(socket)); epochCallID.removeValue(forKey: id); intentionalClose.remove(id)
            return closeWaiters.removeValue(forKey: id)
        }
        waiter?.resume()
    }
    private func isCurrent(_ expected: UUID, socket: URLSessionWebSocketTask) -> Bool { lock.withLock { connectionID == expected && task === socket } }
    private func classify(_ code: URLSessionWebSocketTask.CloseCode) -> MediaDisconnectReason { switch code { case .policyViolation: return .authFailed; case .protocolError, .invalid: return .protocolViolation; case .goingAway: return .serverRestart; case .normalClosure: return .remoteClosed; default: return .transientNetwork } }
    private func sanitized(_ data: Data?) -> String { guard let data, var value = String(data: data, encoding: .utf8) else { return "none" }; value = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "); return String(value.prefix(80)) }
    private func emit(_ event: String, _ status: String, callID: UUID, error: NSError? = nil) { onDiagnostic?(.init(event: event, status: status, callID: callID, errorDomain: error?.domain, errorCode: error?.code)) }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
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
