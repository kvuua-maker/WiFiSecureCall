import Foundation

/// What a SIP transport reports back to the client.
enum SIPTransportState: Sendable, Equatable {
    case connecting
    case connected
    case disconnected
    case failed(String)
}

protocol SIPTransportDelegate: AnyObject, Sendable {
    func sipTransport(_ transport: SIPTransport, didReceive message: SIPMessage)
    func sipTransport(_ transport: SIPTransport, didChange state: SIPTransportState)
}

/// A transport carries whole SIP messages and nothing else.
///
/// The protocol exists so the signalling layer never learns whether it is talking
/// over a secure WebSocket, TLS or plain UDP, and so tests can drive the client
/// without a network.
protocol SIPTransport: AnyObject, Sendable {
    var delegate: SIPTransportDelegate? { get set }
    func start()
    func stop()
    func send(_ message: SIPMessage)
}

/// SIP over a secure WebSocket (RFC 7118).
///
/// WSS is the transport a watch should use: port 443 passes every hotel and
/// carrier network, the connection is encrypted, and an open WebSocket survives
/// the network transitions a watch sees when it moves between Wi-Fi and LTE far
/// better than a UDP registration.
final class WebSocketSIPTransport: NSObject, SIPTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var delegate: SIPTransportDelegate?

    private let url: URL
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.sip.transport", qos: .userInitiated)
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var attempt = 0
    private var keepalive: DispatchSourceTimer?
    private var sendQueue: SIPMessageQueue!

    init(url: URL) {
        self.url = url
        super.init()
        sendQueue = SIPMessageQueue { [weak self] data in
            self?.task?.send(.data(data)) { error in
                if let error {
                    self?.report(.failed(error.localizedDescription))
                }
            }
        }
    }

    deinit {
        keepalive?.setEventHandler {}
        keepalive?.cancel()
        session?.invalidateAndCancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.task == nil else { return }
            self.report(.connecting)
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.webSocketTask(with: self.url)
            self.task = task
            task.resume()
            self.receive(on: task)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.keepalive?.setEventHandler {}
            self.keepalive?.cancel()
            self.keepalive = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
        }
    }

    func send(_ message: SIPMessage) {
        sendQueue.enqueue(message)
    }

    // MARK: - Receive loop

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(frame):
                let data: Data
                switch frame {
                case let .data(value): data = value
                case let .string(value): data = Data(value.utf8)
                @unknown default: return
                }
                if let message = SIPMessage.parse(data) {
                    self.delegate?.sipTransport(self, didReceive: message)
                }
                self.receive(on: task)
            case let .failure(error):
                self.queue.async {
                    guard !self.stopped else { return }
                    self.task = nil
                    self.report(.failed(error.localizedDescription))
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        attempt += 1
        // 0.5s, 1s, 2s, 4s, then every 8s. A watch that walks out of Wi-Fi range
        // and back must find its registration again without the user noticing.
        let delay = min(pow(2.0, Double(attempt - 1)) * 0.5, 8.0)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.task == nil else { return }
            self.start()
        }
    }

    private func startKeepalive() {
        keepalive?.setEventHandler {}
        keepalive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            self?.task?.sendPing { error in
                if let error {
                    self?.report(.failed(error.localizedDescription))
                }
            }
        }
        keepalive = timer
        timer.resume()
    }

    private func report(_ state: SIPTransportState) {
        delegate?.sipTransport(self, didChange: state)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.attempt = 0
            self.report(.connected)
            self.startKeepalive()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.task = nil
            self.report(.disconnected)
            self.scheduleReconnect()
        }
    }
}
