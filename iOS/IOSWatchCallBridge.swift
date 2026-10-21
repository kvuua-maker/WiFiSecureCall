import Combine
import Foundation
import UIKit
import WatchConnectivity

/// The iPhone half of the pair: turns a number from the watch into a call.
///
/// The watch cannot place a call while its screen is off, and a WCSession that was
/// left alone after the watch went to sleep stops delivering. This object is what
/// makes the hand-off survive that: it activates the session at launch, reactivates
/// it after the system deactivates it, accepts requests through all three delivery
/// paths, and reports every state change back.
@MainActor
final class IOSWatchCallBridge: NSObject, ObservableObject {
    static let shared = IOSWatchCallBridge()

    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastRequestID: UUID?
    @Published private(set) var lastError: String?

    private var session: WCSession?
    private var handled: [UUID: Date] = [:]
    private var stateSubscription: AnyCancellable?
    private var activeRequestID: UUID?
    /// Requests are remembered for this long so a message that arrives twice,
    /// once by `sendMessage` and once by `transferUserInfo`, dials once.
    private let dedupeWindow: TimeInterval = 300

    // MARK: - Lifecycle

    func activate() {
        guard WCSession.isSupported() else { return }
        if session == nil {
            let session = WCSession.default
            session.delegate = self
            self.session = session
        }
        guard let session else { return }
        if session.activationState != .activated {
            session.activate()
        }
        observeCallState()
    }

    private func observeCallState() {
        guard stateSubscription == nil else { return }
        stateSubscription = NotificationRuntime.shared.callSession.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.callStateChanged(state)
            }
    }

    private func callStateChanged(_ state: CallState) {
        // The keep-alive follows the call itself, not a particular request: an
        // incoming call that was answered from the iPhone must hold the session
        // open exactly like one this bridge started.
        switch state {
        case .active, .reconnecting:
            IOSCallKeepAlive.shared.callDidStart()
        case .idle, .ended, .failed:
            IOSCallKeepAlive.shared.callDidEnd()
        case .outgoingRinging, .incomingRinging, .connecting, .ending:
            break
        }

        guard let requestID = activeRequestID else { return }
        guard let mapped = Self.bridgeState(for: state) else { return }
        send(WatchBridgeMessage(kind: .callState, requestID: requestID, state: mapped.rawValue, detail: detail(for: state), callID: state.callID))
        if mapped == .ended || mapped == .failed {
            activeRequestID = nil
        }
    }

    private func detail(for state: CallState) -> String? {
        if case let .failed(_, failure) = state { return Self.message(for: failure) }
        return nil
    }

    private static func bridgeState(for state: CallState) -> WatchBridgeCallState? {
        switch state {
        case .idle: return nil
        case .outgoingRinging: return .dialing
        case .incomingRinging: return .ringing
        case .connecting: return .ringing
        case .active, .reconnecting: return .active
        case .ending, .ended: return .ended
        case .failed: return .failed
        }
    }

    private static func message(for failure: CallFailure) -> String {
        switch failure {
        case .targetUnavailable: return "That number is not on Wi-Fi calling"
        case .targetAmbiguous: return "That number is ambiguous"
        case .accountSessionInvalid: return "Link an account first"
        case .permissionDenied: return "Microphone access is off"
        case .serverUnavailable: return "Server unavailable"
        default: return failure.rawValue
        }
    }

    // MARK: - Sending to the watch

    /// Delivers a message to the watch by the most durable route available.
    ///
    /// `sendMessage` only works while the watch app is awake. The application
    /// context is kept as the latest known state and is delivered when the watch
    /// next runs, which is what lets a wrist that is asleep still show the call
    /// that arrived while it was down.
    func send(_ message: WatchBridgeMessage) {
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(message.dictionary)
        if session.isReachable {
            session.sendMessage(message.dictionary, replyHandler: nil, errorHandler: { [weak self] _ in
                Task { @MainActor in self?.lastError = "Watch is not reachable" }
            })
        } else {
            session.transferUserInfo(message.dictionary)
        }
    }

    /// Tells the watch that a call is ringing, after a VoIP push woke this app.
    func notifyIncoming(callID: UUID, caller: String?) {
        send(WatchBridgeMessage(kind: .incomingCall, callID: callID, caller: caller))
    }

    // MARK: - Receiving from the watch

    private func receive(_ message: WatchBridgeMessage) {
        guard message.kind == .requestCall else { return }
        pruneHandled()
        guard handled[message.requestID] == nil else { return }
        handled[message.requestID] = Date()
        lastRequestID = message.requestID
        activeRequestID = message.requestID

        guard let number = message.number, number.count >= 3 else {
            send(WatchBridgeMessage(kind: .callState, requestID: message.requestID, state: WatchBridgeCallState.failed.rawValue, detail: "Invalid number"))
            return
        }
        send(WatchBridgeMessage(kind: .callState, requestID: message.requestID, state: WatchBridgeCallState.resolving.rawValue))

        Task { await self.place(requestID: message.requestID, number: number) }
    }

    private func place(requestID: UUID, number: String) async {
        guard let accountID = AccountSessionStore.shared.callableAccounts.first?.accountID else {
            send(WatchBridgeMessage(kind: .callState, requestID: requestID, state: WatchBridgeCallState.failed.rawValue, detail: "Link an account first"))
            activeRequestID = nil
            return
        }
        do {
            let recipient = try await NotificationRuntime.shared.resolveRecipient(number, accountID: accountID)
            send(WatchBridgeMessage(kind: .callState, requestID: requestID, state: WatchBridgeCallState.dialing.rawValue))
            await NotificationRuntime.shared.startUserCall(targetUserID: recipient.userID, accountID: accountID)
        } catch {
            // The number is not a Wi-Fi user. Handing it to the system dialer is
            // the only way this app can reach the phone network, and the call is
            // still preceded by the CallKit confirmation the system shows.
            guard let digits = Self.dialableDigits(number),
                  let url = URL(string: "tel:\(digits)"),
                  UIApplication.shared.canOpenURL(url) else {
                send(WatchBridgeMessage(kind: .callState, requestID: requestID, state: WatchBridgeCallState.failed.rawValue, detail: "Number not on Wi-Fi calling"))
                activeRequestID = nil
                return
            }
            // open(_:) is the async variant in the current SDK; awaiting it keeps
            // the failure report accurate instead of racing the transition.
            await UIApplication.shared.open(url)
            send(WatchBridgeMessage(kind: .callState, requestID: requestID, state: WatchBridgeCallState.handedToSystem.rawValue, detail: "Opened the iPhone dialler"))
            activeRequestID = nil
        }
    }

    private static func dialableDigits(_ number: String) -> String? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : digits
    }

    private func pruneHandled(now: Date = Date()) {
        handled = handled.filter { now.timeIntervalSince($0.value) < dedupeWindow }
    }
}

// MARK: - WCSessionDelegate

extension IOSWatchCallBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isReachable = session.isReachable
            if activationState == .activated {
                self.observeCallState()
            } else if let error {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// The system deactivates the session when the watch switches or the link is
    /// rebuilt. Not reactivating here is why a bridge that worked once stops
    /// working until the iPhone app is relaunched.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = false
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = false
            session.activate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.isWatchAppInstalled = session.isWatchAppInstalled
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let parsed = WatchBridgeMessage.parse(message) else { return }
        Task { @MainActor in self.receive(parsed) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let parsed = WatchBridgeMessage.parse(message) else {
            replyHandler([:])
            return
        }
        // Answer before doing the work: the reply keeps the watch's send from
        // being reported as failed while the number is still being resolved.
        replyHandler(WatchBridgeMessage(
            kind: .callState,
            requestID: parsed.requestID,
            state: WatchBridgeCallState.resolving.rawValue
        ).dictionary)
        Task { @MainActor in self.receive(parsed) }
    }

    /// Queued delivery. This is the path a request takes when the watch sent it
    /// while this app was not running, including when the app was launched in the
    /// background to receive it.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let parsed = WatchBridgeMessage.parse(userInfo) else { return }
        Task { @MainActor in self.receive(parsed) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let parsed = WatchBridgeMessage.parse(applicationContext) else { return }
        Task { @MainActor in self.receive(parsed) }
    }
}


extension IncomingNotificationEnvelope {
    /// The server call identifier, whatever shape the push took.
    var callID: UUID {
        switch self {
        case let .legacy(callID): return callID
        case let .account(callID, _): return callID
        case let .user(callID, _, _): return callID
        }
    }

    /// A name to show on the watch, when the push carried one.
    var callerName: String? {
        if case let .user(_, _, caller) = self { return caller.callKitName }
        return nil
    }
}
