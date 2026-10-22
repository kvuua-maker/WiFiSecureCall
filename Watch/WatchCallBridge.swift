import Foundation
import WatchConnectivity

/// A dial request that survived the watch going to sleep.
///
/// The whole point of the outbox is that a request is never held only in memory.
/// The watch is suspended within seconds of the screen going dark, so a request
/// that was not delivered has to be written down before the app is frozen, and it
/// has to be delivered when the session comes back rather than being dropped.
struct WatchCallOutbox {
    struct Entry: Codable, Equatable {
        var message: WatchBridgeMessage
        var createdAt: Date
        var attempts: Int
        /// Set once the message has been handed to the system for background
        /// delivery, so a flush does not queue it twice.
        var transferred: Bool
    }

    /// A request older than this is not worth delivering: the user has put the
    /// watch down and would not expect last hour's number to start ringing.
    static let maximumAge: TimeInterval = 300

    private let key = "watch.call.outbox.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    func enqueue(_ message: WatchBridgeMessage, now: Date = Date()) {
        var entries = all().filter { $0.message.requestID != message.requestID }
        entries.append(Entry(message: message, createdAt: now, attempts: 0, transferred: false))
        write(entries)
    }

    func markTransferred(_ requestID: UUID, now: Date = Date()) {
        var entries = all()
        guard let index = entries.firstIndex(where: { $0.message.requestID == requestID }) else { return }
        entries[index].transferred = true
        entries[index].attempts += 1
        write(entries)
    }

    func recordAttempt(_ requestID: UUID) {
        var entries = all()
        guard let index = entries.firstIndex(where: { $0.message.requestID == requestID }) else { return }
        entries[index].attempts += 1
        write(entries)
    }

    func remove(_ requestID: UUID) {
        write(all().filter { $0.message.requestID != requestID })
    }

    func removeExpired(now: Date = Date()) -> [UUID] {
        let entries = all()
        let expired = entries.filter { now.timeIntervalSince($0.createdAt) > Self.maximumAge }
        if !expired.isEmpty {
            let expiredIDs = Set(expired.map(\.message.requestID))
            write(entries.filter { !expiredIDs.contains($0.message.requestID) })
        }
        return expired.map(\.message.requestID)
    }

    private func write(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

/// The watch half of the pair: hands a number to the iPhone and reports back.
///
/// This is the whole reason the watch does not place its own call any more. A
/// watch app cannot hold a socket open while the wrist is down, so a dial request
/// has to be a small message that the iPhone acts on, and it has to be recoverable
/// when the session is not reachable at the moment the button is pressed.
@MainActor
final class WatchCallBridge: NSObject, ObservableObject {
    static let shared = WatchCallBridge()

    enum Delivery: Equatable {
        case sent
        case queued
        case unavailable(String)
    }

    @Published private(set) var isActivated = false
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var status = ""
    @Published private(set) var lastDeliveredRequest: UUID?
    @Published private(set) var incoming: WatchBridgeMessage?
    @Published private(set) var lastIncomingState: WatchBridgeCallState?
    /// When the call became active, so the screen can show a real duration.
    @Published private(set) var callStartedAt: Date?
    @Published private(set) var isMutedOnPhone = false
    /// Who the current call is with, for the call screen.
    @Published private(set) var remoteDisplayName = ""

    private var session: WCSession?
    private let outbox = WatchCallOutbox()
    private var heartbeat: Task<Void, Never>?

    var isSupported: Bool { WCSession.isSupported() }
    var pendingRequestCount: Int { outbox.all().count }

    // MARK: - Lifecycle

    func activate() {
        wireRelay()
        guard WCSession.isSupported() else {
            status = "This watch cannot reach an iPhone"
            return
        }
        if session == nil {
            let session = WCSession.default
            session.delegate = self
            self.session = session
        }
        guard let session, session.activationState != .activated else {
            isActivated = session?.activationState == .activated
            isPhoneReachable = session?.isReachable ?? false
            return
        }
        session.activate()
    }

    private func wireRelay() {
        WatchDialRelay.shared.onResult = { [weak self] requestID, result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .delivered, .queued:
                    self.outbox.remove(requestID)
                    self.status = "iPhone will dial \(self.remoteDisplayName)"
                case let .failed(reason):
                    self.status = "Cannot reach the iPhone: \(reason)"
                }
            }
        }
    }

    /// Called when the app comes to the foreground, which is the one moment the
    /// system is guaranteed to give us: any request queued while we were suspended
    /// is flushed here.
    func applicationDidBecomeActive() {
        activate()
        startHeartbeat()
        let expired = outbox.removeExpired()
        if let newest = expired.last {
            outbox.remove(newest)
            if status.isEmpty { status = "That call request expired" }
        }
        flush()
    }

    func applicationWillResignActive() {
        stopHeartbeat()
    }

    // MARK: - Dialling

    /// Queues a call and delivers it now if the iPhone is reachable.
    @discardableResult
    func requestCall(number: String) -> Delivery {
        guard isSupported else { return .unavailable("WatchConnectivity is unavailable") }
        activate()

        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return .unavailable("Enter at least 3 digits") }

        remoteDisplayName = trimmed
        let message = WatchBridgeMessage(kind: .requestCall, number: trimmed)
        // Written down before anything is attempted: if the app is suspended
        // between here and the send, the request still exists.
        outbox.enqueue(message)
        status = "Sending to iPhone…"

        // The transfer queue is the primary path, not the fallback. It is the one
        // delivery Apple guarantees and it survives both ends sleeping, which
        // sendMessage does not. sendMessage is sent as well when the phone happens
        // to be awake, purely to make the common case feel instant.
        if let session, session.activationState == .activated {
            session.transferUserInfo(message.dictionary)
            outbox.markTransferred(message.requestID)
            if session.isReachable {
                deliver(message, over: session)
            }
        }
        scheduleRelayFallback(for: message)
        return .sent
    }

    /// Sends a control command for the call the iPhone is hosting.
    ///
    /// The call itself runs on the phone, so the watch cannot change it directly;
    /// this is the message that does, and it is best effort by design — a control
    /// that cannot be delivered must not look like a failed call.
    func toggleMuteOnPhone() {
        let next = !isMutedOnPhone
        isMutedOnPhone = next
        sendControl(.mute(next))
    }

    func endCallOnPhone() {
        sendControl(.end)
        callStartedAt = nil
    }

    func sendControl(_ control: WatchCallControl) {
        guard isSupported else { return }
        activate()
        guard let session, session.activationState == .activated else {
            status = "iPhone is not reachable"
            return
        }
        let payload = control.message.dictionary
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in })
        } else {
            session.transferUserInfo(payload)
        }
    }

    /// If WatchConnectivity has not confirmed the command in three seconds, the
    /// relay takes over. Both copies carry the same request id, so whichever
    /// arrives first dials and the other is ignored.
    private func scheduleRelayFallback(for message: WatchBridgeMessage) {
        let requestID = message.requestID
        guard let number = message.number else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.outbox.all().contains(where: { $0.message.requestID == requestID }) else { return }
                self.status = "Reaching the iPhone another way…"
                WatchDialRelay.shared.send(requestID: requestID, number: number)
            }
        }
    }

    func cancelPendingRequests() {
        for entry in outbox.all() {
            outbox.remove(entry.message.requestID)
        }
        status = "Cancelled"
    }

    /// Retries everything still pending. Safe to call often: the outbox dedupes by
    /// request identifier, so a retry cannot place the same call twice.
    func flush() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        let pending = outbox.all().filter { !$0.transferred }
        guard !pending.isEmpty else { return }
        for entry in pending {
            outbox.recordAttempt(entry.message.requestID)
            session.sendMessage(entry.message.dictionary, replyHandler: { [weak self] reply in
                guard let message = WatchBridgeMessage.parse(reply) else { return }
                Task { @MainActor in self?.handle(message) }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in self?.outbox.recordAttempt(entry.message.requestID) }
            })
        }
    }

    // MARK: - Incoming

    func clearIncoming() {
        incoming = nil
    }

    /// Puts the call screen back to idle without touching the call itself.
    func resetCallDisplay() {
        lastIncomingState = nil
        callStartedAt = nil
        isMutedOnPhone = false
        remoteDisplayName = ""
        status = ""
    }

    // MARK: - Delivery

    private func deliver(_ message: WatchBridgeMessage, over session: WCSession) {
        session.sendMessage(message.dictionary, replyHandler: { [weak self] reply in
            guard let reply = WatchBridgeMessage.parse(reply) else { return }
            Task { @MainActor in self?.handle(reply) }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The send failed even though the session said it was reachable,
                // which is exactly the race that used to lose a dial request.
                self.outbox.recordAttempt(message.requestID)
                self.session?.transferUserInfo(message.dictionary)
                self.outbox.markTransferred(message.requestID)
                self.status = "Will call when the iPhone is free"
            }
        })
    }

    private func handle(_ message: WatchBridgeMessage) {
        switch message.kind {
        case .callState:
            outbox.remove(message.requestID)
            lastDeliveredRequest = message.requestID
            if let raw = message.state, let state = WatchBridgeCallState(rawValue: raw) {
                lastIncomingState = state
                status = Self.describe(state, detail: message.detail)
                if state == .active {
                    if callStartedAt == nil { callStartedAt = Date() }
                    startHeartbeat()
                }
                if state == .ended || state == .failed {
                    callStartedAt = nil
                    isMutedOnPhone = false
                }
                if state == .ended || state == .failed || state == .handedToSystem { stopHeartbeat() }
            }
        case .incomingCall:
            incoming = message
            remoteDisplayName = message.caller ?? "iPhone"
            status = "Incoming call on iPhone"
        case .ping:
            session?.transferUserInfo(WatchBridgeMessage(kind: .pong, requestID: message.requestID).dictionary)
        case .pong:
            break
        case .requestCall, .cancelCall, .callControl:
            break
        }
    }

    private static func describe(_ state: WatchBridgeCallState, detail: String?) -> String {
        switch state {
        case .resolving: return "Resolving number…"
        case .dialing: return "Calling from iPhone…"
        case .ringing: return "Ringing…"
        case .active: return "Call in progress on iPhone"
        case .ended: return "Call ended"
        case .failed: return detail ?? "Call failed"
        case .handedToSystem: return "Dialled on iPhone"
        }
    }

    // MARK: - Heartbeat

    /// While a call is up, both apps are running because of the audio session, so
    /// a light ping keeps the session warm and surfaces a dropped link on screen
    /// instead of at the next call attempt.
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard let session = self.session, session.isReachable else { return }
                    session.sendMessage(WatchBridgeMessage(kind: .ping).dictionary, replyHandler: nil, errorHandler: nil)
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }
}

// MARK: - WCSessionDelegate

extension WatchCallBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isActivated = activationState == .activated
            self.isPhoneReachable = session.isReachable
            if let error {
                self.status = "iPhone link: \(error.localizedDescription)"
            } else if activationState == .activated {
                self.flush()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            if session.isReachable {
                self.flush()
            } else if self.outbox.all().contains(where: { !$0.transferred }) {
                self.status = "Will call when the iPhone is free"
            }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        Task { @MainActor in
            guard error != nil, let message = WatchBridgeMessage.parse(userInfoTransfer.userInfo) else { return }
            self.outbox.markTransferred(message.requestID)
            self.status = "Will call when the iPhone is free"
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let parsed = WatchBridgeMessage.parse(message) else { return }
        Task { @MainActor in self.handle(parsed) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let parsed = WatchBridgeMessage.parse(message) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            self.handle(parsed)
            replyHandler(WatchBridgeMessage(kind: .pong, requestID: parsed.requestID).dictionary)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let parsed = WatchBridgeMessage.parse(userInfo) else { return }
        Task { @MainActor in self.handle(parsed) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let parsed = WatchBridgeMessage.parse(applicationContext) else { return }
        Task { @MainActor in self.handle(parsed) }
    }
}
