import Foundation
import WatchConnectivity
import WatchKit

@MainActor
final class WatchSystemDialCoordinator: NSObject, ObservableObject {
    static let shared = WatchSystemDialCoordinator()

    @Published private(set) var isPreparing = false
    @Published private(set) var latestAttempt: SystemDialAttempt?

    private let session: WCSession?
    private let store: SystemDialDiagnosticStore
    private let network: SystemDialNetworkMonitor
    private let admission = SystemDialAttemptAdmission()
    private var activeAttemptID: UUID?
    private var resultRequestedForAttempt: UUID?

    override convenience init() {
        self.init(
            session: WCSession.isSupported() ? .default : nil,
            store: .shared,
            network: .shared
        )
    }

    init(session: WCSession?, store: SystemDialDiagnosticStore, network: SystemDialNetworkMonitor) {
        self.session = session
        self.store = store
        self.network = network
        latestAttempt = store.attempts.first
        super.init()
    }

    func activate() {
        _ = network.current
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func prepareAndDial(number: String, url: URL) async {
        guard WatchSystemDialerNumber.isValid(number), url.scheme == "tel", admission.begin() else { return }
        isPreparing = true
        defer {
            isPreparing = false
            admission.end()
        }

        let attemptID = UUID()
        activeAttemptID = attemptID
        resultRequestedForAttempt = nil
        let snapshot = network.current
        let supported = WCSession.isSupported()
        let currentSession = session
        let activationState = currentSession.map(Self.activationState) ?? "unsupported"
        let reachable = currentSession?.isReachable ?? false
        let needsUnlock = currentSession?.iOSDeviceNeedsUnlockAfterRebootForReachability
        var attempt = SystemDialAttempt.make(
            attemptID: attemptID,
            numberDigitCount: number.filter(\.isNumber).count,
            network: snapshot,
            wcSupported: supported,
            wcActivationState: activationState,
            wcReachableBeforePing: reachable,
            iPhoneNeedsUnlockAfterReboot: needsUnlock
        )
        attempt.events.append(.init(source: "watch", event: "prepare_started", status: SystemDialClassification.preparing, attemptID: attemptID))
        store.upsert(attempt)
        publish(attemptID)

        if let currentSession, currentSession.activationState != .activated {
            currentSession.activate()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        var receivedReply = false
        if let currentSession, currentSession.activationState == .activated, currentSession.isReachable {
            for index in 1...2 {
                let result = await ping(session: currentSession, attemptID: attemptID, index: index, network: snapshot)
                store.updateAndRecord(
                    id: attemptID,
                    source: "watch",
                    event: "prepare_ping",
                    status: result.result.status,
                    detail: "index=\(index) rttMs=\(Int(result.result.rttMilliseconds))"
                ) { value in
                    value.pingResults.append(result.result)
                    if let iPhoneSnapshot = result.snapshot { value.iPhoneSnapshot = iPhoneSnapshot }
                }
                publish(attemptID)
                if result.snapshot != nil {
                    receivedReply = true
                    break
                }
            }
        }

        let state = currentSession.map(Self.activationState) ?? "unsupported"
        let preflightClassification = SystemDialClassification.preflight(
            networkStatus: snapshot.status,
            wcSupported: supported,
            activationState: state,
            reachable: currentSession?.isReachable ?? false,
            needsUnlock: needsUnlock,
            replied: receivedReply
        )
        store.updateAndRecord(id: attemptID, source: "watch", event: "preflight_finished", status: preflightClassification) {
            $0.wcActivationState = state
            $0.classification = preflightClassification
        }
        publish(attemptID)

        guard SystemDialPreflightPolicy.shouldRequestTelHandoff(numberIsValid: true, preflightSucceeded: receivedReply) else { return }
        let handoffAt = Date()
        store.updateAndRecord(id: attemptID, source: "watch", event: "tel_handoff_requested", status: "requested", at: handoffAt) {
            $0.telHandoffRequestedAt = handoffAt
            $0.classification = SystemDialClassification.telHandoffRequested
        }
        publish(attemptID)
        if let currentSession, currentSession.activationState == .activated, currentSession.isReachable {
            currentSession.sendMessage([
                "type": "systemDialHandoff",
                "attemptID": attemptID.uuidString,
                "handoffAt": handoffAt.timeIntervalSince1970
            ], replyHandler: nil, errorHandler: nil)
        }
        WKApplication.shared().openSystemURL(url)
    }

    func applicationWillResignActive() {
        guard let attemptID = activeAttemptID,
              let attempt = store.attempt(id: attemptID),
              attempt.telHandoffRequestedAt != nil else { return }
        var recorded = false
        store.update(id: attemptID) { recorded = SystemDialLifecycleRecorder.recordFirstResign(in: &$0) }
        guard recorded else { return }
        publish(attemptID)
    }

    func applicationDidBecomeActive() {
        guard let attemptID = activeAttemptID,
              resultRequestedForAttempt != attemptID,
              let attempt = store.attempt(id: attemptID),
              attempt.telHandoffRequestedAt != nil else { return }
        var recorded = false
        store.update(id: attemptID) { recorded = SystemDialLifecycleRecorder.recordFirstReturn(in: &$0) }
        guard recorded else { return }
        resultRequestedForAttempt = attemptID
        publish(attemptID)
        Task { await fetchResult(attemptID: attemptID) }
    }

    private func ping(session: WCSession, attemptID: UUID, index: Int, network: SystemDialNetworkSnapshot) async -> (result: SystemDialPingResult, snapshot: SystemDialIPhoneSnapshot?) {
        let nonce = UUID()
        let sentAt = Date()
        let started = DispatchTime.now().uptimeNanoseconds
        let message: [String: Any] = [
            "type": "prepareSystemDial",
            "attemptID": attemptID.uuidString,
            "nonce": nonce.uuidString,
            "sentAt": sentAt.timeIntervalSince1970,
            "watchNetworkStatus": network.status,
            "watchNetworkInterfaces": network.interfaces,
            "numberDigitCount": store.attempt(id: attemptID)?.numberDigitCount ?? 0,
            "wcActivationState": Self.activationState(session),
            "wcReachableBeforePing": session.isReachable,
            "iPhoneNeedsUnlockAfterReboot": session.iOSDeviceNeedsUnlockAfterRebootForReachability
        ]
        let response: Result<[String: Any], Error> = await withCheckedContinuation { continuation in
            let gate = SystemDialOneShotCompletion<[String: Any]> { continuation.resume(returning: $0) }
            session.sendMessage(message, replyHandler: { reply in
                guard SystemDialMessageValidator.matches(reply, attemptID: attemptID, nonce: nonce) else {
                    _ = gate.complete(.failure(SystemDialCoordinatorError.staleReply))
                    return
                }
                _ = gate.complete(.success(reply))
            }, errorHandler: { error in
                _ = gate.complete(.failure(error))
            })
            Task {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                _ = gate.complete(.failure(SystemDialCoordinatorError.timeout))
            }
        }
        let finishedAt = Date()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        switch response {
        case let .success(reply):
            let snapshot = Self.iPhoneSnapshot(from: reply)
            return (
                .init(index: index, nonce: nonce, sentAt: sentAt, finishedAt: finishedAt, rttMilliseconds: elapsed, status: snapshot == nil ? "invalid_reply" : "reply", detail: nil),
                snapshot
            )
        case let .failure(error):
            let value = error as NSError
            return (
                .init(index: index, nonce: nonce, sentAt: sentAt, finishedAt: finishedAt, rttMilliseconds: elapsed, status: error is SystemDialCoordinatorError ? String(describing: error) : "error", detail: "\(value.domain):\(value.code)"),
                nil
            )
        }
    }

    private func fetchResult(attemptID: UUID) async {
        guard let session, session.activationState == .activated, session.isReachable else {
            store.updateAndRecord(id: attemptID, source: "watch", event: "result_fetch", status: "unreachable") {
                $0.finishedAt = Date()
                $0.classification = SystemDialClassification.unknownAfterTelHandoff
            }
            publish(attemptID)
            await store.flush()
            return
        }
        let nonce = UUID()
        let message: [String: Any] = [
            "type": "systemDialResult",
            "attemptID": attemptID.uuidString,
            "nonce": nonce.uuidString
        ]
        let response: Result<[String: Any], Error> = await withCheckedContinuation { continuation in
            let gate = SystemDialOneShotCompletion<[String: Any]> { continuation.resume(returning: $0) }
            session.sendMessage(message, replyHandler: { reply in
                guard SystemDialMessageValidator.matches(reply, attemptID: attemptID, nonce: nonce) else {
                    _ = gate.complete(.failure(SystemDialCoordinatorError.staleReply))
                    return
                }
                _ = gate.complete(.success(reply))
            }, errorHandler: { _ = gate.complete(.failure($0)) })
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                _ = gate.complete(.failure(SystemDialCoordinatorError.timeout))
            }
        }
        guard case let .success(reply) = response,
              let data = reply["attemptJSON"] as? Data,
              let remote = try? Self.decoder.decode(SystemDialAttempt.self, from: data) else {
            store.updateAndRecord(id: attemptID, source: "watch", event: "result_fetch", status: "failed") {
                $0.finishedAt = Date()
                $0.classification = SystemDialClassification.unknownAfterTelHandoff
            }
            publish(attemptID)
            await store.flush()
            return
        }
        store.updateAndRecord(id: attemptID, source: "watch", event: "result_fetch", status: "reply") {
            $0.iPhoneSnapshot = remote.iPhoneSnapshot ?? $0.iPhoneSnapshot
            $0.iPhoneObservedOutgoingCallAt = remote.iPhoneObservedOutgoingCallAt
            $0.iPhoneObservedConnectedCallAt = remote.iPhoneObservedConnectedCallAt
            $0.iPhoneObservedEndedCallAt = remote.iPhoneObservedEndedCallAt
            $0.iPhoneDefaultCallingRequestAt = remote.iPhoneDefaultCallingRequestAt
            $0.iPhoneTelephonyFallbackRequestedAt = remote.iPhoneTelephonyFallbackRequestedAt
            $0.iPhoneTelephonyFallbackOpenCompletedAt = remote.iPhoneTelephonyFallbackOpenCompletedAt
            $0.iPhoneTelephonyFallbackOpenAccepted = remote.iPhoneTelephonyFallbackOpenAccepted
            $0.finishedAt = Date()
            $0.classification = SystemDialClassification.afterHandoff(
                outgoing: remote.iPhoneObservedOutgoingCallAt,
                connected: remote.iPhoneObservedConnectedCallAt,
                ended: remote.iPhoneObservedEndedCallAt,
                resultReceived: true
            )
            for event in remote.events where event.source == "iPhone" { $0.events.append(event) }
        }
        publish(attemptID)
        await store.flush()
    }

    private func applyPushedResult(_ message: [String: Any]) -> Bool {
        guard let attemptString = message["attemptID"] as? String,
              let attemptID = UUID(uuidString: attemptString),
              let data = message["attemptJSON"] as? Data,
              let remote = try? Self.decoder.decode(SystemDialAttempt.self, from: data),
              activeAttemptID == attemptID else { return false }
        store.update(id: attemptID) {
            $0.iPhoneObservedOutgoingCallAt = remote.iPhoneObservedOutgoingCallAt
            $0.iPhoneObservedConnectedCallAt = remote.iPhoneObservedConnectedCallAt
            $0.iPhoneObservedEndedCallAt = remote.iPhoneObservedEndedCallAt
            $0.iPhoneDefaultCallingRequestAt = remote.iPhoneDefaultCallingRequestAt
            $0.iPhoneTelephonyFallbackRequestedAt = remote.iPhoneTelephonyFallbackRequestedAt
            $0.iPhoneTelephonyFallbackOpenCompletedAt = remote.iPhoneTelephonyFallbackOpenCompletedAt
            $0.iPhoneTelephonyFallbackOpenAccepted = remote.iPhoneTelephonyFallbackOpenAccepted
            $0.classification = SystemDialClassification.afterHandoff(
                outgoing: remote.iPhoneObservedOutgoingCallAt,
                connected: remote.iPhoneObservedConnectedCallAt,
                ended: remote.iPhoneObservedEndedCallAt,
                resultReceived: true
            )
        }
        publish(attemptID)
        Task { await store.flush() }
        return true
    }

    private func publish(_ attemptID: UUID) {
        guard let next = store.attempt(id: attemptID) else { return }
        if let current = latestAttempt,
           current.attemptID == next.attemptID,
           SystemDialUserSummary.make(from: current) == SystemDialUserSummary.make(from: next) {
            return
        }
        latestAttempt = next
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func activationState(_ session: WCSession) -> String {
        switch session.activationState {
        case .notActivated: return "notActivated"
        case .inactive: return "inactive"
        case .activated: return "activated"
        @unknown default: return "unknown"
        }
    }

    private static func iPhoneSnapshot(from reply: [String: Any]) -> SystemDialIPhoneSnapshot? {
        guard reply["type"] as? String == "prepareSystemDialReply",
              let receivedAt = reply["receivedAt"] as? TimeInterval,
              let repliedAt = reply["repliedAt"] as? TimeInterval,
              let applicationState = reply["applicationState"] as? String,
              let activation = reply["wcActivationState"] as? String,
              let isPaired = reply["isPaired"] as? Bool,
              let installed = reply["isWatchAppInstalled"] as? Bool,
              let networkStatus = reply["networkStatus"] as? String,
              let interfaces = reply["networkInterfaces"] as? [String] else { return nil }
        return .init(
            receivedAt: Date(timeIntervalSince1970: receivedAt),
            repliedAt: Date(timeIntervalSince1970: repliedAt),
            applicationState: applicationState,
            wcActivationState: activation,
            isPaired: isPaired,
            isWatchAppInstalled: installed,
            networkStatus: networkStatus,
            networkInterfaces: interfaces
        )
    }
}

extension WatchSystemDialCoordinator: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            guard let attemptID = self.activeAttemptID else { return }
            self.store.record(id: attemptID, source: "watch", event: "wc_activation", status: error == nil ? Self.activationState(session) : "error")
            self.publish(attemptID)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            let applied = message["type"] as? String == "systemDialResultPush" && self.applyPushedResult(message)
            replyHandler(["type": "systemDialResultPushReply", "accepted": applied])
        }
    }
}

private enum SystemDialCoordinatorError: Error, CustomStringConvertible {
    case timeout
    case staleReply

    var description: String {
        switch self { case .timeout: return "timeout"; case .staleReply: return "stale_reply" }
    }
}
