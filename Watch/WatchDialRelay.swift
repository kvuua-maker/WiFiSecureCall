import Foundation

/// The watch side of the dial relay: the path that still works when
/// WatchConnectivity does not.
///
/// It is used only after the WatchConnectivity copy has had three seconds and has
/// not been acknowledged. Sending on both paths is deliberate: the transfer queue
/// is the one Apple guarantees, and this socket is the one that survives an iCloud
/// link that is down, so whichever arrives first dials and the request id makes
/// the other a no-op.
final class WatchDialRelay: @unchecked Sendable {
    static let shared = WatchDialRelay()

    enum Result: Sendable {
        case queued
        case delivered
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.watch.relay")
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var connecting = false
    private var attempt = 0
    private var endpoint: (url: URL, token: String)?
    /// Commands written before the socket was open, replayed once it is.
    private var outbox: [(requestID: UUID, number: String)] = []

    var onResult: (@Sendable (UUID, Result) -> Void)?

    private init() {}

    /// Queue a dial command. Returns immediately; the result arrives through onResult.
    ///
    /// Credentials are read on the main actor, because the account store is main
    /// actor isolated, and handed to the socket queue as plain values.
    @MainActor
    func send(requestID: UUID, number: String) {
        guard let url = Self.relayURL(), let token = Self.accessToken() else {
            onResult?(requestID, .failed("Sign in again to use the relay"))
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.endpoint = (url, token)
            self.outbox.append((requestID, number))
            if self.task != nil {
                self.drain()
            } else {
                self.connect()
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.connecting = false
        }
    }

    // MARK: - Connection

    private func connect() {
        guard !connecting, let endpoint else {
            flushFailure("Sign in again to use the relay")
            return
        }
        let (url, token) = endpoint
        connecting = true
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task)
        drain()
    }

    private func drain() {
        guard let task else { return }
        guard !outbox.isEmpty else { return }
        let pending = outbox
        outbox.removeAll(keepingCapacity: true)
        for command in pending {
            let payload: [String: Any] = [
                "type": "dial",
                "requestID": command.requestID.uuidString,
                "number": command.number,
                "createdAt": Date().timeIntervalSince1970
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else { continue }
            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                self?.queue.async {
                    self?.outbox.append(command)
                    self?.onResult?(command.requestID, .failed(error.localizedDescription))
                }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(frame):
                if case let .string(text) = frame, let message = Self.parse(text) {
                    self.queue.async {
                        self.onResult?(message.requestID, message.delivered ? .delivered : .queued)
                    }
                }
                self.receive(on: task)
            case let .failure(error):
                self.queue.async {
                    self.task = nil
                    self.connecting = false
                    self.session?.invalidateAndCancel()
                    self.session = nil
                    self.attempt += 1
                    // 1s, 2s, 4s, then every 8s: the watch is often asleep between
                    // attempts, and the queue on the server is what actually holds
                    // the command, so this only has to be eventual.
                    let delay = min(pow(2.0, Double(max(0, self.attempt - 1))), 8.0)
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        if !self.outbox.isEmpty { self.connect() }
                    }
                    self.onResult?(UUID(), .failed(error.localizedDescription))
                }
            }
        }
    }

    private func flushFailure(_ reason: String) {
        let pending = outbox
        outbox.removeAll(keepingCapacity: true)
        for command in pending {
            onResult?(command.requestID, .failed(reason))
        }
    }

    // MARK: - Message shape

    private struct Reply {
        let requestID: UUID
        let delivered: Bool
    }

    private static func parse(_ text: String) -> Reply? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["requestID"] as? String,
              let requestID = UUID(uuidString: rawID),
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "delivered": return Reply(requestID: requestID, delivered: true)
        case "queued": return Reply(requestID: requestID, delivered: false)
        default: return nil
        }
    }

    // MARK: - Endpoint and credentials

    /// The relay lives beside the API under the v1 prefix that nginx already
    /// proxies, so no new host or port has to be reachable from the watch.
    @MainActor
    static func relayURL(config: AppConfig = .load()) -> URL? {
        guard var components = URLComponents(url: config.apiBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "wss"
        var path = components.path
        if path.hasSuffix("/v1") {
            path = String(path.dropLast(3)) + "/relay"
        } else {
            path += "/relay"
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: "role", value: "watch")]
        return components.url
    }

    @MainActor
    static func accessToken() -> String? {
        let store = AccountSessionStore.shared
        guard let accountID = store.activeAccountID,
              let tokens = try? store.tokenStore.tokens(for: accountID) else { return nil }
        return tokens.accessToken
    }
}
