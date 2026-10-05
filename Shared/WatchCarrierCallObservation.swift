import Foundation

/// One report the system gave this app about a call, copied out of CallKit so the rules below can be
/// tested without a watch, a carrier or a clock.
///
/// `CXCallObserver` is the only public evidence a watchOS app can get about the carrier call its own
/// `tel:` hand-off created: watchOS hands the number to the system Phone app, the carrier places the
/// call, and nothing is reported back to the app that handed the number over.
struct WatchCarrierCallSnapshot: Codable, Equatable, Sendable {
    let callID: UUID
    let isOutgoing: Bool
    let hasConnected: Bool
    let hasEnded: Bool
    let onHold: Bool

    init(callID: UUID, isOutgoing: Bool, hasConnected: Bool, hasEnded: Bool, onHold: Bool = false) {
        self.callID = callID
        self.isOutgoing = isOutgoing
        self.hasConnected = hasConnected
        self.hasEnded = hasEnded
        self.onHold = onHold
    }
}

/// What the app can actually say about the call after handing a number to the system.
///
/// `connected` and `endedAfterConnecting` exist only for a call the system reported as connected.
/// Everything else is stated as what it is: a hand-off waiting for the owner, a call that was seen
/// starting, a call that ended before answering, or an absence of reports.
enum WatchCarrierCallVerdict: String, Codable, Hashable, Sendable {
    case notRequested
    case awaitingOwnerConfirmation
    case observedOutgoing
    case connected
    case endedAfterConnecting
    case endedBeforeConnecting
    case notObserved

    /// True only where the system reported a connected call, which is the duplex-audio evidence this
    /// screen exists to produce. No other verdict may be read as proof that anybody heard anybody.
    var isConnectedEvidence: Bool { self == .connected || self == .endedAfterConnecting }

    /// Absence of reports is not a report of absence of a call, so it is a warning and never a failure.
    var severity: WatchCarrierCallReportSeverity {
        switch self {
        case .notRequested, .awaitingOwnerConfirmation, .observedOutgoing, .connected, .endedAfterConnecting:
            return .neutral
        case .endedBeforeConnecting:
            return .warning
        case .notObserved:
            return .warning
        }
    }

    var displayText: String {
        switch self {
        case .notRequested:
            return "Очікую натискання трубки"
        case .awaitingOwnerConfirmation:
            return "Номер передано Телефону. Натисніть «Виклик» на екрані — до цього дзвінок ще не йде."
        case .observedOutgoing:
            return "Система бачить вихідний дзвінок. З’єднання ще не підтверджено."
        case .connected:
            return "Дзвінок з’єднано. Звук із мікрофона Watch і в динамік Watch."
        case .endedAfterConnecting:
            return "Дзвінок з’єднано і завершено. Розмова була."
        case .endedBeforeConnecting:
            return "Дзвінок завершився до з’єднання: абонент не відповів або оператор відхилив."
        case .notObserved:
            return "Програма повернулася без звістки про дзвінок: під час нього вона призупинена в Телефоні. Якщо ви скасували «Виклик», так і має бути; якщо ні — перевірте умови нижче."
        }
    }
}

enum WatchCarrierCallReportSeverity: String, Codable, Hashable, Sendable {
    case neutral
    case warning
}

/// What the app knows about one hand-off of one number to the system Phone app.
///
/// A value type with no networking, no clock and no CallKit, so every rule about what may be claimed
/// after a hand-off is covered by unit tests on every platform rather than by one tap on one device.
struct WatchCarrierCallReport: Codable, Equatable, Sendable {
    private(set) var verdict: WatchCarrierCallVerdict = .notRequested
    private(set) var handoffRequestedAt: Date?
    private(set) var observedCallID: UUID?
    private(set) var observedOutgoingAt: Date?
    private(set) var observedConnectedAt: Date?
    private(set) var observedEndedAt: Date?
    private(set) var returnedToAppAt: Date?
    private(set) var ignoredOwnProviderCallCount = 0
    private(set) var ignoredForeignCallCount = 0

    /// Starts a new hand-off and forgets the previous one, so a verdict can never describe a number the
    /// owner is no longer calling.
    mutating func requestHandoff(at timestamp: Date = Date()) {
        verdict = .awaitingOwnerConfirmation
        handoffRequestedAt = timestamp
        observedCallID = nil
        observedOutgoingAt = nil
        observedConnectedAt = nil
        observedEndedAt = nil
        returnedToAppAt = nil
        ignoredOwnProviderCallCount = 0
        ignoredForeignCallCount = 0
    }

    /// Forgets a hand-off because the number changed. A verdict describes one number, and keeping it on
    /// screen while a different number is being typed is how a report ends up attached to the wrong call.
    mutating func discard() {
        self = WatchCarrierCallReport()
    }

    /// Records one system report about one call.
    ///
    /// Reports that belong to this app's own app-to-app calls, and reports about a second call, are
    /// counted and dropped: the number on this screen is a carrier number, so a CallKit call this app
    /// reported itself is never evidence that a carrier call happened.
    mutating func apply(
        _ snapshot: WatchCarrierCallSnapshot,
        isOwnProviderCall: Bool,
        at timestamp: Date = Date()
    ) {
        guard handoffRequestedAt != nil else { return }
        if isOwnProviderCall {
            ignoredOwnProviderCallCount += 1
            return
        }
        if let observedCallID, observedCallID != snapshot.callID {
            ignoredForeignCallCount += 1
            return
        }
        if observedCallID == nil { observedCallID = snapshot.callID }
        if snapshot.isOutgoing, observedOutgoingAt == nil { observedOutgoingAt = timestamp }
        if snapshot.hasConnected, observedConnectedAt == nil { observedConnectedAt = timestamp }
        if snapshot.hasEnded, observedEndedAt == nil { observedEndedAt = timestamp }
        recomputeVerdict()
    }

    /// Stamps the moment the owner came back to this app, which is when watchOS has been suspended in
    /// the system Phone app and cannot have delivered anything in between.
    mutating func noteReturnedToApp(at timestamp: Date = Date()) {
        guard handoffRequestedAt != nil, returnedToAppAt == nil else { return }
        returnedToAppAt = timestamp
        recomputeVerdict()
    }

    /// Talk time, and only when both ends of it were reported: connected and ended.
    var talkDuration: TimeInterval? {
        guard let connected = observedConnectedAt, let ended = observedEndedAt else { return nil }
        return max(0, ended.timeIntervalSince(connected))
    }

    var isHandedOff: Bool { handoffRequestedAt != nil }

    private mutating func recomputeVerdict() {
        if observedEndedAt != nil {
            verdict = observedConnectedAt == nil ? .endedBeforeConnecting : .endedAfterConnecting
        } else if observedConnectedAt != nil {
            verdict = .connected
        } else if observedOutgoingAt != nil {
            verdict = .observedOutgoing
        } else if returnedToAppAt != nil {
            verdict = .notObserved
        } else if handoffRequestedAt != nil {
            verdict = .awaitingOwnerConfirmation
        } else {
            verdict = .notRequested
        }
    }
}
