import CallKit
import Foundation
import SwiftUI
import UIKit
import WatchConnectivity

@MainActor
final class IOSSystemDialCoordinator: NSObject {
    static let shared = IOSSystemDialCoordinator()

    private let session: WCSession?
    private let store: SystemDialDiagnosticStore
    private let network: SystemDialNetworkMonitor
    private let callObserver = CXCallObserver()
    private var observation: Observation?
    private var observationTimeout: Task<Void, Never>?

    private struct Observation {
        let attemptID: UUID
        let startedAt: Date
        let preexistingCalls: Set<UUID>
        var relevantCallID: UUID?
        var backgroundTask: UIBackgroundTaskIdentifier
    }

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
        super.init()
        callObserver.setDelegate(self, queue: .main)
    }

    func activate() {
        _ = network.current
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    private func handlePrepare(_ message: [String: Any]) -> [String: Any] {
        let receivedAt = Date()
        guard let attemptString = message["attemptID"] as? String,
              let attemptID = UUID(uuidString: attemptString),
              let nonce = message["nonce"] as? String,
              UUID(uuidString: nonce) != nil else {
            return ["type": "prepareSystemDialReply", "status": "invalid"]
        }

        let currentNetwork = network.current
        let currentSession = session
        let snapshot = SystemDialIPhoneSnapshot(
            receivedAt: receivedAt,
            repliedAt: Date(),
            applicationState: Self.applicationState(UIApplication.shared.applicationState),
            wcActivationState: currentSession.map(Self.activationState) ?? "unsupported",
            isPaired: currentSession?.isPaired ?? false,
            isWatchAppInstalled: currentSession?.isWatchAppInstalled ?? false,
            networkStatus: currentNetwork.status,
            networkInterfaces: currentNetwork.interfaces
        )
        if store.attempt(id: attemptID) == nil {
            let watchNetwork = SystemDialNetworkSnapshot(
                status: message["watchNetworkStatus"] as? String ?? "unknown",
                interfaces: message["watchNetworkInterfaces"] as? [String] ?? []
            )
            var attempt = SystemDialAttempt.make(
                attemptID: attemptID,
                startedAt: receivedAt,
                numberDigitCount: message["numberDigitCount"] as? Int ?? 0,
                network: watchNetwork,
                wcSupported: true,
                wcActivationState: message["wcActivationState"] as? String ?? "unknown",
                wcReachableBeforePing: message["wcReachableBeforePing"] as? Bool ?? true,
                iPhoneNeedsUnlockAfterReboot: message["iPhoneNeedsUnlockAfterReboot"] as? Bool,
                classification: SystemDialClassification.iPhoneReady
            )
            attempt.iPhoneSnapshot = snapshot
            store.upsert(attempt)
        } else {
            store.update(id: attemptID) {
                $0.iPhoneSnapshot = snapshot
                $0.classification = SystemDialClassification.iPhoneReady
            }
        }
        store.record(id: attemptID, source: "iPhone", event: "prepare_received", status: "replying", at: receivedAt)
        startObservationIfNeeded(attemptID: attemptID, startedAt: receivedAt)

        let repliedAt = Date()
        store.update(id: attemptID) {
            $0.iPhoneSnapshot = .init(
                receivedAt: receivedAt,
                repliedAt: repliedAt,
                applicationState: snapshot.applicationState,
                wcActivationState: snapshot.wcActivationState,
                isPaired: snapshot.isPaired,
                isWatchAppInstalled: snapshot.isWatchAppInstalled,
                networkStatus: snapshot.networkStatus,
                networkInterfaces: snapshot.networkInterfaces
            )
        }
        return [
            "type": "prepareSystemDialReply",
            "attemptID": attemptID.uuidString,
            "nonce": nonce,
            "receivedAt": receivedAt.timeIntervalSince1970,
            "repliedAt": repliedAt.timeIntervalSince1970,
            "applicationState": snapshot.applicationState,
            "wcActivationState": snapshot.wcActivationState,
            "isPaired": snapshot.isPaired,
            "isWatchAppInstalled": snapshot.isWatchAppInstalled,
            "networkStatus": snapshot.networkStatus,
            "networkInterfaces": snapshot.networkInterfaces
        ]
    }

    private func handleResult(_ message: [String: Any]) -> [String: Any] {
        guard let attemptString = message["attemptID"] as? String,
              let attemptID = UUID(uuidString: attemptString),
              let nonce = message["nonce"] as? String else {
            return ["type": "systemDialResultReply", "status": "invalid"]
        }
        var reply: [String: Any] = [
            "type": "systemDialResultReply",
            "attemptID": attemptID.uuidString,
            "nonce": nonce
        ]
        if let attempt = store.attempt(id: attemptID), let data = try? Self.encoder.encode(attempt) {
            reply["attemptJSON"] = data
        }
        return reply
    }

    private func startObservationIfNeeded(attemptID: UUID, startedAt: Date) {
        if observation?.attemptID == attemptID { return }
        finishObservation(classifyMissingEvidence: true)
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SystemDialDiagnostics") { [weak self] in
            Task { @MainActor in self?.finishObservation(classifyMissingEvidence: true) }
        }
        observation = Observation(
            attemptID: attemptID,
            startedAt: startedAt,
            preexistingCalls: Set(callObserver.calls.map(\.uuid)),
            relevantCallID: nil,
            backgroundTask: backgroundTask
        )
        observationTimeout?.cancel()
        observationTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finishObservation(classifyMissingEvidence: true) }
        }
    }

    private func observe(_ call: CXCall) {
        guard var current = observation, Date().timeIntervalSince(current.startedAt) <= 30 else { return }
        if current.relevantCallID == nil {
            guard call.isOutgoing, !current.preexistingCalls.contains(call.uuid) else { return }
            current.relevantCallID = call.uuid
            observation = current
            let now = Date()
            store.update(id: current.attemptID) {
                if $0.iPhoneObservedOutgoingCallAt == nil { $0.iPhoneObservedOutgoingCallAt = now }
                $0.classification = SystemDialClassification.systemCallObserved
            }
            store.record(id: current.attemptID, source: "iPhone", event: "system_call_observed_outgoing", status: "observed", at: now)
        }
        guard current.relevantCallID == call.uuid else { return }
        if call.hasConnected, store.attempt(id: current.attemptID)?.iPhoneObservedConnectedCallAt == nil {
            let now = Date()
            store.update(id: current.attemptID) {
                $0.iPhoneObservedConnectedCallAt = now
                $0.classification = SystemDialClassification.systemCallConnected
            }
            store.record(id: current.attemptID, source: "iPhone", event: "system_call_observed_connected", status: "observed", at: now)
        }
        if call.hasEnded, store.attempt(id: current.attemptID)?.iPhoneObservedEndedCallAt == nil {
            let now = Date()
            store.update(id: current.attemptID) {
                $0.iPhoneObservedEndedCallAt = now
                $0.finishedAt = now
                $0.classification = SystemDialClassification.systemCallEnded
            }
            store.record(id: current.attemptID, source: "iPhone", event: "system_call_observed_ended", status: "observed", at: now)
            finishObservation(classifyMissingEvidence: false)
        }
    }

    private func finishObservation(classifyMissingEvidence: Bool) {
        observationTimeout?.cancel()
        observationTimeout = nil
        guard let current = observation else { return }
        observation = nil
        if classifyMissingEvidence {
            store.update(id: current.attemptID) {
                $0.finishedAt = Date()
                $0.classification = SystemDialClassification.afterHandoff(
                    outgoing: $0.iPhoneObservedOutgoingCallAt,
                    connected: $0.iPhoneObservedConnectedCallAt,
                    ended: $0.iPhoneObservedEndedCallAt,
                    resultReceived: true
                )
            }
            store.record(id: current.attemptID, source: "iPhone", event: "observation_window_finished", status: "bounded")
        }
        if current.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(current.backgroundTask)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func activationState(_ session: WCSession) -> String {
        switch session.activationState {
        case .notActivated: return "notActivated"
        case .inactive: return "inactive"
        case .activated: return "activated"
        @unknown default: return "unknown"
        }
    }

    private static func applicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

extension IOSSystemDialCoordinator: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            switch message["type"] as? String {
            case "prepareSystemDial": replyHandler(self.handlePrepare(message))
            case "systemDialResult": replyHandler(self.handleResult(message))
            default: replyHandler(["type": "unsupported"])
            }
        }
    }
}

extension IOSSystemDialCoordinator: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in self.observe(call) }
    }
}

struct SystemDialDiagnosticsView: View {
    @ObservedObject private var store = SystemDialDiagnosticStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List(store.attempts) { attempt in
                DisclosureGroup {
                    detail(attempt)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attempt.classification).font(.caption.bold())
                        Text("\(attempt.startedAt.formatted()) · \(attempt.attemptID.uuidString.prefix(8))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Dial diagnostics")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    @ViewBuilder private func detail(_ attempt: SystemDialAttempt) -> some View {
        Text("Watch: \(attempt.watchNetworkStatus) [\(attempt.watchNetworkInterfaces.joined(separator: ", "))]")
        Text("WC: \(attempt.wcActivationState), reachable: \(attempt.wcReachableBeforePing ? "yes" : "no")")
        if let snapshot = attempt.iPhoneSnapshot {
            Text("iPhone: \(snapshot.applicationState), \(snapshot.networkStatus) [\(snapshot.networkInterfaces.joined(separator: ", "))]")
        }
        Text("Outgoing: \(attempt.iPhoneObservedOutgoingCallAt == nil ? "not observed" : "observed")")
        Text("Connected: \(attempt.iPhoneObservedConnectedCallAt == nil ? "not observed" : "observed")")
        Text("Ended: \(attempt.iPhoneObservedEndedCallAt == nil ? "not observed" : "observed")")
        ForEach(attempt.events) { event in
            Text("\(event.timestamp.formatted(date: .omitted, time: .standard)) \(event.source) · \(event.event) · \(event.status)")
                .font(.caption2)
        }
    }
}
