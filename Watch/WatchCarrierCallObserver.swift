import Foundation

#if os(watchOS)
import CallKit
import WatchConnectivity

/// The calls this app created itself through its own `CXProvider`, so they can never be mistaken for the
/// carrier call the dialpad asked the system to place.
final class WatchOwnProviderCallLedger: @unchecked Sendable {
    static let shared = WatchOwnProviderCallLedger()

    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func register(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        _ = ids.insert(id)
    }

    func forget(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        _ = ids.remove(id)
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}

/// The only public evidence a watchOS app can get about the carrier call its own `tel:` hand-off created.
///
/// `WKApplication.openSystemURL(_:)` gives the number to the system Phone app and returns nothing. Apple
/// documents that the user then chooses whether to continue, so the call belongs to the system and to
/// the carrier, not to this app. `CXCallObserver` is documented as something "any app" can use to be
/// notified of call activity on the system, and CallKit is available from watchOS 9, which is this app's
/// floor. That makes it the only route by which the watch itself can report that the carrier call
/// connected — instead of a message that a number was handed over.
///
/// While the system Phone app is frontmost this app is suspended and no report can arrive. That limit is
/// why an absence of reports is recorded as `notObserved` and never as a failed call.
@MainActor
final class WatchCarrierCallObserver: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = WatchCarrierCallObserver()

    @Published private(set) var report = WatchCarrierCallReport()
    @Published private(set) var isPairedWithIPhone: Bool?

    private let observer = CXCallObserver()
    private var isListening = false
    private var session: WCSession?

    private override init() { super.init() }

    /// Starts listening once for the whole app. The report itself stays empty until a hand-off, so calls
    /// that have nothing to do with this screen cannot fill it.
    func start() {
        session = WCSession.isSupported() ? .default : nil
        guard !isListening else { return }
        observer.setDelegate(self, queue: .main)
        isListening = true
        // WCSession.isPaired is iOS-only; watchOS has no equivalent pairing query.
        isPairedWithIPhone = nil
    }

    /// Records the moment a number was handed to the system, before the hand-off itself, so a report that
    /// arrives within the same turn is still about this hand-off.
    func requestHandoff(at timestamp: Date = Date()) {
        report.requestHandoff(at: timestamp)
    }

    /// Drops the previous attempt when the number being typed is a different one.
    func discardAttempt() {
        report.discard()
    }

    /// Called when the owner comes back from the system Phone app. Whatever happened during the call has
    /// already happened; this is the first moment the app can look for it.
    func applicationDidBecomeActive() {
        ingestCurrentCalls()
        report.noteReturnedToApp()
        // Do not substitute reachability or app installation for pairing evidence.
        isPairedWithIPhone = nil
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in self?.ingest(call) }
    }

    private func ingestCurrentCalls() {
        for call in observer.calls { ingest(call) }
    }

    private func ingest(_ call: CXCall) {
        apply(WatchCarrierCallSnapshot(
            callID: call.uuid,
            isOutgoing: call.isOutgoing,
            hasConnected: call.hasConnected,
            hasEnded: call.hasEnded,
            onHold: call.isOnHold
        ))
    }

    private func apply(_ snapshot: WatchCarrierCallSnapshot) {
        report.apply(snapshot, isOwnProviderCall: isOwnProviderCall(snapshot.callID))
    }

    /// A report about a call this app created itself, or any report while an app-to-app call of ours is
    /// running, belongs to our own CallKit call and says nothing about a carrier number.
    private func isOwnProviderCall(_ callID: UUID) -> Bool {
        if WatchOwnProviderCallLedger.shared.contains(callID) { return true }
        return NotificationRuntime.shared.callSession.state != .idle
    }
}
#endif
