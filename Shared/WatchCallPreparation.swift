import Foundation

/// What the watch knows about its own path to the network at one moment.
///
/// `unknown` is kept distinct from `unsatisfied` because watchOS reports a path it has not yet brought up
/// differently from one that is down, and only the first is worth waiting for.
enum WatchCallPathState: String, Equatable, Sendable {
    case unknown
    case satisfied
    case unsatisfied
}

/// Why a path has not been proven usable. Every case is a fact the app established, never a guess about
/// the carrier, which no watchOS API reports.
enum WatchCallPreparationBlocker: String, Equatable, Sendable {
    case pathNotObserved
    case pathUnsatisfied
    case pathStale
    case notValidated
    case validationStale
    case validationFailed
}

/// What a tap on the call key should do about the network before the number is handed to the system.
///
/// `handOff` is the only fast path: the watch has a fresh, validated path, so the carrier call is started
/// with the network already up. `warmUpThenHandOff` is the rest of the time, and it exists because Apple
/// documents that watchOS keeps the watch's Wi-Fi and cellular data switched off while the iPhone is not
/// nearby "until you open and use an app that requires a network connection", and that with the iPhone
/// away "outgoing calls might take longer to make". A dial that skips that is a dial made on a radio that
/// is still asleep.
///
/// A preparation never refuses to dial. The system phone app and the carrier may have a path this app
/// cannot see — a cellular plan on the watch, or a call relayed through the iPhone — so the hand-off always
/// happens; what preparation decides is only how much of the watch's own network is brought up first, and
/// what is recorded about it.
enum WatchCallPreparationDecision: Equatable, Sendable {
    case handOff
    case warmUpThenHandOff(budget: TimeInterval)

    var budget: TimeInterval {
        switch self {
        case .handOff: return 0
        case let .warmUpThenHandOff(budget): return budget
        }
    }
}

/// Whether the watch's own path is usable right now, as far as this app can establish.
enum WatchCallReadiness: Equatable, Sendable {
    case warm(validatedAt: Date)
    case warming
    case unverified(WatchCallPreparationBlocker)
}

/// What a call attempt may be told about the watch's network, and when it may be told that again.
///
/// A value type with no networking, no clock and no watch, so the rules about trusting a network that was
/// up before a sleep, or before a radio changed, are covered by unit tests instead of by one tap on one
/// device after one bad night.
struct WatchCallPreparation: Equatable, Sendable {
    /// How long an observed path stays believable. A watch that was on Wi-Fi an hour ago may be nowhere
    /// near it now, and `NWPathMonitor` will not have said so yet.
    ///
    /// Longer than the round trip's validity on purpose: a path is a standing condition while a round
    /// trip is a single moment, and it is the moment that has to be refreshed first.
    static let pathValidity: TimeInterval = 30
    /// How long a completed round trip to a server stays proof of a working path.
    static let validationValidity: TimeInterval = 20
    /// The most a tap will ever wait for the network. Bounded, because a call key that hangs is the same
    /// defect as one that never fires.
    static let warmUpBudget: TimeInterval = 2.5

    private(set) var pathState: WatchCallPathState = .unknown
    private(set) var pathObservedAt: Date?
    private(set) var validatedAt: Date?
    private(set) var lastBlocker: WatchCallPreparationBlocker?
    private(set) var warmUpCount = 0
    private(set) var attemptIsOpen = false

    /// Records what the path monitor saw, and when. A changed path drops the validation: a proof obtained
    /// over one radio says nothing about the next one, and reusing it is how a call is attempted on a path
    /// that has already gone away.
    mutating func observePath(_ state: WatchCallPathState, at timestamp: Date) {
        // A callback that arrives late describes a moment already overtaken, and must not roll the state back
        // or discard a proof made after it. This is the ordinary case here: the warm-up replaces the monitor's
        // observation with a stronger one, and the monitor's next callback can easily be the older of the two.
        if let observedAt = pathObservedAt, timestamp < observedAt { return }
        let changed = pathState != state
            || pathObservedAt.map { abs(timestamp.timeIntervalSince($0)) > Self.pathValidity } == true
        pathState = state
        pathObservedAt = timestamp
        if changed {
            validatedAt = nil
            lastBlocker = currentBlocker(now: timestamp)
        }
    }

    /// Records a completed round trip to the owner's own server, which is what proves the watch's own
    /// network is actually carrying traffic and not merely reporting that it is up.
    ///
    /// A round trip that succeeded is a stronger observation than the path monitor's, so it replaces the
    /// monitor's answer rather than being constrained by it: traffic either arrived or it did not.
    mutating func validated(at timestamp: Date) {
        pathState = .satisfied
        pathObservedAt = timestamp
        validatedAt = timestamp
        lastBlocker = nil
    }

    mutating func validationFailed() {
        validatedAt = nil
        lastBlocker = .validationFailed
    }

    /// Drops everything learned before the app was suspended or woken.
    ///
    /// watchOS is free to tear the watch's radios down while an app is not running, so a path or a round
    /// trip from before a sleep proves nothing about now. This is also what releases a dial claim that a
    /// suspension could otherwise have stranded, which is what made a second attempt silently impossible.
    mutating func invalidateForWake(at timestamp: Date = Date()) {
        discardPathObservation()
        attemptIsOpen = false
    }

    /// Drops the path and everything proven over it, without touching the dial claim.
    ///
    /// Called as the app leaves the foreground: the radios may start going away at that moment, so nothing
    /// may act on a path that was true while this app was visible. The claim survives because a dial that was
    /// just handed over is still in the system phone app, and releasing it here would allow a second hand-off
    /// on top of the first.
    mutating func discardPathObservation() {
        pathState = .unknown
        pathObservedAt = nil
        validatedAt = nil
        lastBlocker = .pathNotObserved
    }

    /// One dial at a time. The claim is released by `closeAttempt()` once the hand-off is made, and by the
    /// next wake in case a suspension stranded it, so no sequence of taps can leave the key unable to act.
    /// Leaving the foreground deliberately does not release it: the number is already in the phone app.
    mutating func openAttempt() -> Bool {
        guard !attemptIsOpen else { return false }
        attemptIsOpen = true
        return true
    }

    mutating func closeAttempt() { attemptIsOpen = false }

    mutating func noteWarmUpStarted() { warmUpCount += 1 }

    func decision(now: Date = Date()) -> WatchCallPreparationDecision {
        guard pathState == .satisfied, isFresh(pathObservedAt, now: now, validity: Self.pathValidity),
              let validatedAt, isFresh(validatedAt, now: now, validity: Self.validationValidity)
        else { return .warmUpThenHandOff(budget: Self.warmUpBudget) }
        return .handOff
    }

    func readiness(now: Date = Date()) -> WatchCallReadiness {
        switch decision(now: now) {
        case .handOff: return .warm(validatedAt: validatedAt ?? now)
        case .warmUpThenHandOff: return .unverified(lastBlocker ?? currentBlocker(now: now))
        }
    }

    /// What to tell the owner about a dial that was handed to the system without a proven path, and nothing
    /// more: the app's own evidence about its network, and never a claim about the carrier.
    func handOffEvidence() -> WatchCallHandoffEvidence {
        guard let validatedAt else { return .withoutProvenPath(lastBlocker ?? .notValidated) }
        return .withProvenPath(validatedAt: validatedAt)
    }

    private func isFresh(_ timestamp: Date?, now: Date, validity: TimeInterval) -> Bool {
        guard let timestamp else { return false }
        let age = now.timeIntervalSince(timestamp)
        return age >= 0 && age <= validity
    }

    /// The most fundamental unmet fact, so that a stale path is never reported as a stale round trip: the
    /// proof is not the problem if the observation it was made on is itself gone.
    private func currentBlocker(now: Date) -> WatchCallPreparationBlocker {
        switch pathState {
        case .unknown: return .pathNotObserved
        case .unsatisfied: return .pathUnsatisfied
        case .satisfied:
            guard isFresh(pathObservedAt, now: now, validity: Self.pathValidity) else { return .pathStale }
            guard let validatedAt else { return .notValidated }
            return isFresh(validatedAt, now: now, validity: Self.validationValidity) ? .notValidated : .validationStale
        }
    }
}

/// Whether the number was handed over on a path the watch had proven, so that a later failure can be
/// attributed to the carrier's service rather than to this app never trying.
enum WatchCallHandoffEvidence: Equatable, Sendable {
    case withProvenPath(validatedAt: Date)
    case withoutProvenPath(WatchCallPreparationBlocker)
}

extension WatchCallPreparationBlocker {
    /// One line, about the watch's own network, and nothing about the carrier. Shown only when a dial was
    /// handed over without a proven path, because that is the only case where it changes what the failure
    /// means.
    var displayText: String {
        switch self {
        case .pathNotObserved: return "Мережа Watch ще не визначена."
        case .pathUnsatisfied: return "Мережа Watch недоступна."
        case .pathStale: return "Відомості про мережу застаріли."
        case .notValidated: return "Мережа Watch не перевірена запитом."
        case .validationStale: return "Перевірка мережі застаріла."
        case .validationFailed: return "Запит до сервера не пройшов."
        }
    }
}

extension WatchCallHandoffEvidence {
    /// What may be said about the path a hand-off used. `nil` when there is nothing worth saying, which is
    /// the case where the watch's own network was proven before the number left.
    var caution: String? {
        switch self {
        case .withProvenPath: return nil
        case let .withoutProvenPath(blocker): return "Мережа Watch не підтверджена: \(blocker.displayText)"
        }
    }
}
