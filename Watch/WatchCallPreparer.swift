import Foundation

#if os(watchOS)
import Network
import WatchConnectivity

/// Brings the watch's own network up before a number is handed to the system, and re-does it after a sleep
/// or a change of network.
///
/// Apple documents the behaviour this exists for: while the iPhone is not nearby the watch keeps "Wi-Fi and
/// cellular data ... turned off ... until you open and use an app that requires a network connection", and
/// "outgoing calls might take longer to make". A call key that opens the system phone app in the middle of
/// that is asking the carrier to place a call over a radio the system has not finished bringing up.
///
/// So the warm-up is a real request to the owner's own server — `GET /v1/health`, which the app already has
/// a client for and the server already answers without authentication — and nothing else. There is no way to
/// make the watch register for Wi-Fi calling, and this does not pretend to: it only establishes that the
/// watch's own network is carrying traffic before the number leaves the app.
@MainActor
final class WatchCallPreparer: ObservableObject {
    static let shared = WatchCallPreparer()

    @Published private(set) var preparation = WatchCallPreparation()
    @Published private(set) var isWarmingUp = false

    private let monitor: SystemDialNetworkMonitor
    private let networkProbe: WatchNetworkProbe
    private var companion: WCSession?
    private var warmUpTask: Task<Void, Never>?
    private var warmUpGeneration = 0
    private var hasStarted = false

    init(
        monitor: SystemDialNetworkMonitor = .shared,
        networkProbe: WatchNetworkProbe = WatchNetworkProbe()
    ) {
        self.monitor = monitor
        self.networkProbe = networkProbe
    }

    /// Called once at launch. Activating the companion session and making one real request is what brings
    /// the watch's network up while the app is frontmost, so the first tap does not pay for it.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        activateCompanion()
        observePath()
        Task { await warmUp() }
    }

    /// Called when the owner comes back to the app, from the system phone app, from a sleep or from a tap
    /// on the watch face. Nothing learned before this point is reused: the radios may have been torn down,
    /// and a dial claim left open by the suspension is released so the next tap can act.
    func applicationDidBecomeActive() {
        preparation.invalidateForWake()
        activateCompanion()
        observePath()
        Task { await warmUp() }
    }

    /// Called as the app leaves the foreground, which is when the radios may start going away and is also
    /// what a hand-off to the system phone app causes. The path is dropped now rather than on the next return,
    /// so nothing can act on what was true while this app was visible; the warm-up in flight is left to finish,
    /// because its result is about the network and not about visibility.
    func applicationWillResignActive() {
        preparation.discardPathObservation()
    }

    /// The tap path. Returns once the watch's network has been asked for, or once the budget is spent.
    ///
    /// Never returns without the caller being able to continue, and never waits longer than
    /// `WatchCallPreparation.warmUpBudget`: a second tap while a warm-up is running joins that warm-up
    /// instead of starting a second one.
    func prepareForHandOff() async -> WatchCallHandoffEvidence {
        await warmUp()
        observePath()
        return preparation.handOffEvidence()
    }

    /// Claims the one dial this attempt may make. Released by `finishAttempt` once the hand-off is made, and
    /// by the next wake in case a suspension stranded it, so no tap sequence can leave the key unable to act.
    func beginAttempt() -> Bool { preparation.openAttempt() }
    func finishAttempt() { preparation.closeAttempt() }

    private func warmUp() async {
        // A warm-up already running is joined rather than doubled: its result is written into the same state
        // and there is no second network to bring up.
        if let warmUpTask {
            await warmUpTask.value
            return
        }
        warmUpGeneration += 1
        let generation = warmUpGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runWarmUp()
        }
        warmUpTask = task
        await task.value
        if warmUpGeneration == generation { warmUpTask = nil }
    }

    private func runWarmUp() async {
        isWarmingUp = true
        preparation.noteWarmUpStarted()
        defer { isWarmingUp = false }
        observePath()
        // Asked for whether or not the path monitor says the watch is up. On watchOS a path that is still
        // coming up is exactly the case this request is meant to finish, so an `unsatisfied` reading is a
        // reason to ask rather than a reason to give up.
        //
        // The endpoint is the one the rest of the app already talks to, so the probe cannot succeed against a
        // different server than the one this build is configured for.
        let outcome = await networkProbe.probe(
            baseURL: NotificationRuntime.shared.api.config.apiBaseURL,
            budget: WatchCallPreparation.warmUpBudget
        )
        switch outcome {
        case .succeeded: preparation.validated(at: Date())
        case .failed: preparation.validationFailed()
        }
        observePath()
    }

    private func observePath() {
        let observed = monitor.observed
        preparation.observePath(Self.pathState(from: observed.snapshot), at: observed.updatedAt ?? Date())
    }

    private func activateCompanion() {
        guard WCSession.isSupported() else { return }
        let session = companion ?? WCSession.default
        companion = session
        // Activation is also how the watch asks to be reachable for the iPhone-relayed route. It is
        // idempotent and cheap, and it is done on every return to the foreground for that reason.
        session.activate()
    }

    private static func pathState(from snapshot: SystemDialNetworkSnapshot) -> WatchCallPathState {
        guard snapshot.status != "unknown" else { return .unknown }
        return snapshot.status == "satisfied" && !snapshot.interfaces.isEmpty ? .satisfied : .unsatisfied
    }
}

/// One bounded request to the owner's own server, used as the proof that the watch's own network works.
struct WatchNetworkProbe: Sendable {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(String)
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = WatchCallPreparation.warmUpBudget
            configuration.timeoutIntervalForResource = WatchCallPreparation.warmUpBudget
            // A path that cannot carry this request has to fail inside the budget, not wait for one.
            configuration.waitsForConnectivity = false
            configuration.allowsCellularAccess = true
            configuration.allowsExpensiveNetworkAccess = true
            configuration.allowsConstrainedNetworkAccess = true
            self.session = URLSession(configuration: configuration)
        }
    }

    /// `GET /v1/health`, the endpoint the server already answers for exactly this purpose. A 2xx is proof
    /// of a working path; anything else is reported as what it is, without being retried behind the owner's
    /// back.
    func probe(baseURL: URL, budget: TimeInterval) async -> Outcome {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.25, min(budget, WatchCallPreparation.warmUpBudget))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("no_response") }
            return 200..<300 ~= http.statusCode ? .succeeded : .failed("status_\(http.statusCode)")
        } catch {
            return .failed(String(describing: type(of: error)))
        }
    }
}
#endif
