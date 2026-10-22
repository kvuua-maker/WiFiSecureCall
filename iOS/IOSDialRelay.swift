import Foundation
import UIKit

/// The iPhone side of the dial relay.
///
/// It stays connected whenever the app is alive, and the server hands it every
/// command that was queued while it was not. A command is acted on the moment it
/// arrives: no confirmation sheet, no number resolution, just the system dialler.
final class IOSDialRelay: NSObject, @unchecked Sendable {
    static let shared = IOSDialRelay()

    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.iphone.relay")
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var attempt = 0
    private var endpoint: (url: URL, token: String)?
    private var stopped = true
    private let handledKey = "ios.dial.relay.handled"
    private let handledLock = NSLock()
    private var handled: [String: Date] = [:]

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: handledKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            handled = decoded
        }
    }

    // MARK: - Lifecycle

    @MainActor
    func start() {
        guard let url = Self.relayURL(), let token = Self.accessToken() else { return }
        queue.async { [weak self] in
            guard let self, self.stopped else { return }
            self.stopped = false
            self.endpoint = (url, token)
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    /// The app was backgrounded: keep the socket for a short while so a command
    /// that is being dialled still gets its acknowledgement out.
    func applicationDidEnterBackground() {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "dial-relay")
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.stop()
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    // MARK: - Connection

    private func connect() {
        guard !stopped, let endpoint else { return }
        let (url, token) = endpoint
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(frame):
                if case let .string(text) = frame {
                    self.handle(text)
                }
                self.receive(on: task)
            case .failure:
                self.queue.async {
                    self.task = nil
                    self.session?.invalidateAndCancel()
                    self.session = nil
                    self.attempt += 1
                    let delay = min(pow(2.0, Double(min(self.attempt, 4))), 15.0)
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        if !self.stopped { self.connect() }
                    }
                }
            }
        }
    }

    // MARK: - Commands

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        guard type == "dial",
              let rawID = object["requestID"] as? String,
              let number = object["number"] as? String, !number.isEmpty else { return }
        guard markHandled(rawID) else {
            // Already dialled from the WatchConnectivity copy: acknowledge so the
            // server drops it, but do not dial again.
            acknowledge(rawID)
            return
        }
        DispatchQueue.main.async {
            Self.dial(number)
        }
        acknowledge(rawID)
    }

    private func acknowledge(_ requestID: String) {
        queue.async { [weak self] in
            guard let self, let task = self.task else { return }
            let payload: [String: Any] = ["type": "delivered", "requestID": requestID]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else { return }
            task.send(.string(text)) { _ in }
        }
    }

    /// Returns false when this request id has already been dialled.
    private func markHandled(_ requestID: String) -> Bool {
        handledLock.lock()
        defer { handledLock.unlock() }
        if handled[requestID] != nil { return false }
        handled[requestID] = Date()
        let cutoff = Date().addingTimeInterval(-3600)
        handled = handled.filter { $0.value > cutoff }
        if let data = try? JSONEncoder().encode(handled) {
            UserDefaults.standard.set(data, forKey: handledKey)
        }
        return true
    }

    // MARK: - Dialling

    /// Hands the number to the system dialler immediately.
    ///
    /// No confirmation and no resolution step: the command came from the paired
    /// watch, which is the confirmation. `tel:` is the only route from this app to
    /// a mobile network, and the call UI is the system's, not ours.
    static func dial(_ number: String) {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, let url = URL(string: "tel:\(digits)") else { return }
        UIApplication.shared.open(url, options: [:]) { _ in }
    }

    // MARK: - Endpoint and credentials

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
        components.queryItems = [URLQueryItem(name: "role", value: "iphone")]
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
