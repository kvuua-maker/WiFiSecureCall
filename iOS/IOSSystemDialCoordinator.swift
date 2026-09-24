import CallKit
import Foundation
import Intents
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
    private let defaultCallAdmission = SystemDialDefaultCallAdmissionGate()
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

    @discardableResult
    func handleDefaultCallingActivity(_ userActivity: NSUserActivity) -> Bool {
        guard let handle = Self.startCallHandle(from: userActivity) else { return false }
        let fingerprint = handle.hashValue
        guard defaultCallAdmission.admit(fingerprint: fingerprint) else { return true }

        let requestAt = Date()
        let attemptID = activeDiagnosticAttemptID(at: requestAt)
        if let attemptID {
            store.updateAndRecord(
                id: attemptID,
                source: "iPhone",
                event: "default_call_request_received",
                status: "received",
                detail: "digitCount=\(handle.filter(\.isNumber).count)",
                at: requestAt
            ) {
                $0.iPhoneDefaultCallingRequestAt = requestAt
            }
        }

        guard let url = SystemDialTelephonyURL.make(handle: handle) else {
            if let attemptID {
                store.record(id: attemptID, source: "iPhone", event: "telephony_fallback", status: "invalid_handle")
            }
            return false
        }

        let fallbackAt = Date()
        if let attemptID {
            store.updateAndRecord(id: attemptID, source: "iPhone", event: "telephony_fallback_requested", status: "requested", at: fallbackAt) {
                $0.iPhoneTelephonyFallbackRequestedAt = fallbackAt
            }
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] accepted in
            Task { @MainActor in
                guard let self, let attemptID else { return }
                let completedAt = Date()
                self.store.updateAndRecord(
                    id: attemptID,
                    source: "iPhone",
                    event: "telephony_fallback_open_completed",
                    status: accepted ? "accepted" : "rejected",
                    at: completedAt
                ) {
                    $0.iPhoneTelephonyFallbackOpenCompletedAt = completedAt
                    $0.iPhoneTelephonyFallbackOpenAccepted = accepted
                }
            }
        }
        return true
    }

    private func activeDiagnosticAttemptID(at now: Date) -> UUID? {
        if let observation, now.timeIntervalSince(observation.startedAt) <= 30 {
            return observation.attemptID
        }
        return store.attempts.first {
            $0.finishedAt == nil && now.timeIntervalSince($0.startedAt) <= 30
        }?.attemptID
    }

    private static func startCallHandle(from userActivity: NSUserActivity) -> String? {
        guard let intent = userActivity.interaction?.intent as? INStartCallIntent else { return nil }
        return intent.contacts?
            .compactMap { $0.personHandle?.value }
            .first { !$0.isEmpty }
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
            attempt.events.append(.init(timestamp: receivedAt, source: "iPhone", event: "prepare_received", status: "replying", attemptID: attemptID))
            store.upsert(attempt)
        } else {
            store.updateAndRecord(id: attemptID, source: "iPhone", event: "prepare_received", status: "replying", at: receivedAt) {
                $0.iPhoneSnapshot = snapshot
                $0.classification = SystemDialClassification.iPhoneReady
            }
        }
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

    private func handleHandoff(_ message: [String: Any]) {
        guard let handoff = SystemDialHandoffMessage.parse(message),
              store.attempt(id: handoff.attemptID) != nil else { return }
        store.updateAndRecord(
            id: handoff.attemptID,
            source: "iPhone",
            event: "tel_handoff_received",
            status: "observed",
            at: handoff.handoffAt
        ) {
            if $0.telHandoffRequestedAt == nil { $0.telHandoffRequestedAt = handoff.handoffAt }
        }
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
            store.updateAndRecord(id: current.attemptID, source: "iPhone", event: "system_call_observed_outgoing", status: "observed", at: now) {
                if $0.iPhoneObservedOutgoingCallAt == nil { $0.iPhoneObservedOutgoingCallAt = now }
                $0.classification = SystemDialClassification.systemCallObserved
            }
        }
        guard current.relevantCallID == call.uuid else { return }
        if call.hasConnected, store.attempt(id: current.attemptID)?.iPhoneObservedConnectedCallAt == nil {
            let now = Date()
            store.updateAndRecord(id: current.attemptID, source: "iPhone", event: "system_call_observed_connected", status: "observed", at: now) {
                $0.iPhoneObservedConnectedCallAt = now
                $0.classification = SystemDialClassification.systemCallConnected
            }
        }
        if call.hasEnded, store.attempt(id: current.attemptID)?.iPhoneObservedEndedCallAt == nil {
            let now = Date()
            store.updateAndRecord(id: current.attemptID, source: "iPhone", event: "system_call_observed_ended", status: "observed", at: now) {
                $0.iPhoneObservedEndedCallAt = now
                $0.finishedAt = now
                $0.classification = SystemDialClassification.afterHandoff(
                    outgoing: $0.iPhoneObservedOutgoingCallAt,
                    connected: $0.iPhoneObservedConnectedCallAt,
                    ended: now,
                    resultReceived: true
                )
            }
            finishObservation(classifyMissingEvidence: false)
        }
    }

    private func finishObservation(classifyMissingEvidence: Bool) {
        observationTimeout?.cancel()
        observationTimeout = nil
        guard let current = observation else { return }
        observation = nil
        if classifyMissingEvidence {
            store.updateAndRecord(id: current.attemptID, source: "iPhone", event: "observation_window_finished", status: "bounded") {
                $0.finishedAt = Date()
                $0.classification = SystemDialClassification.afterHandoff(
                    outgoing: $0.iPhoneObservedOutgoingCallAt,
                    connected: $0.iPhoneObservedConnectedCallAt,
                    ended: $0.iPhoneObservedEndedCallAt,
                    resultReceived: true
                )
            }
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

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if message["type"] as? String == "systemDialHandoff" {
                self.handleHandoff(message)
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
                let summary = SystemDialUserSummary.make(from: attempt)
                DisclosureGroup {
                    detail(attempt, summary: summary)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: summary.severity))
                            .foregroundStyle(color(for: summary.severity))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.title).font(.subheadline.bold())
                            Text("\(attempt.startedAt.formatted()) · \(summary.code) · \(attempt.attemptID.uuidString.prefix(8))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Dial diagnostics")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    @ViewBuilder private func detail(_ attempt: SystemDialAttempt, summary: SystemDialUserSummary) -> some View {
        diagnosticSection("Результат") {
            Text(summary.title)
            if let detail = summary.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Text(attempt.classification).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }

        diagnosticSection("Watch") {
            diagnosticLine("Мережа", networkText(status: attempt.watchNetworkStatus, interfaces: attempt.watchNetworkInterfaces))
            diagnosticLine("WC активовано", yesNo(attempt.wcActivationState == "activated"))
            diagnosticLine("iPhone доступний", yesNo(attempt.wcReachableBeforePing))
            diagnosticLine("Потрібне розблокування", optionalYesNo(attempt.iPhoneNeedsUnlockAfterReboot))
        }

        if let snapshot = attempt.iPhoneSnapshot {
            diagnosticSection("iPhone") {
                diagnosticLine("Стан програми", snapshot.applicationState)
                diagnosticLine("Мережа", networkText(status: snapshot.networkStatus, interfaces: snapshot.networkInterfaces))
                diagnosticLine("Спарено", yesNo(snapshot.isPaired))
                diagnosticLine("Watch app встановлено", yesNo(snapshot.isWatchAppInstalled))
                if let ping = attempt.pingResults.last {
                    diagnosticLine("Ping RTT", "\(Int(ping.rttMilliseconds.rounded())) ms")
                }
            }
        } else {
            diagnosticSection("iPhone") {
                Text("Немає snapshot").font(.caption).foregroundStyle(.secondary)
            }
        }

        diagnosticSection("Системний дзвінок") {
            diagnosticLine("Передано в Телефон", yesNo(attempt.telHandoffRequestedAt != nil))
            diagnosticLine("Default request", yesNo(attempt.iPhoneDefaultCallingRequestAt != nil))
            diagnosticLine("Telephony fallback", yesNo(attempt.iPhoneTelephonyFallbackRequestedAt != nil))
            diagnosticLine("Fallback прийнято", optionalYesNo(attempt.iPhoneTelephonyFallbackOpenAccepted))
            diagnosticLine("Вихідний помічено", yesNo(attempt.iPhoneObservedOutgoingCallAt != nil))
            diagnosticLine("З’єднано", yesNo(attempt.iPhoneObservedConnectedCallAt != nil))
            diagnosticLine("Завершено", yesNo(attempt.iPhoneObservedEndedCallAt != nil))
            durationLine("Default → fallback", from: attempt.iPhoneDefaultCallingRequestAt, to: attempt.iPhoneTelephonyFallbackRequestedAt)
            durationLine("Fallback → outgoing", from: attempt.iPhoneTelephonyFallbackRequestedAt, to: attempt.iPhoneObservedOutgoingCallAt)
            durationLine("Outgoing → connected", from: attempt.iPhoneObservedOutgoingCallAt, to: attempt.iPhoneObservedConnectedCallAt)
            durationLine("Outgoing → ended", from: attempt.iPhoneObservedOutgoingCallAt, to: attempt.iPhoneObservedEndedCallAt)
        }

        DisclosureGroup("Технічний журнал") {
            ForEach(attempt.events) { event in
                Text("\(event.timestamp.formatted(date: .omitted, time: .standard)) · \(event.source) · \(event.event) · \(event.status)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func diagnosticSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            content()
        }
    }

    private func diagnosticLine(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }.font(.caption)
    }

    @ViewBuilder private func durationLine(_ label: String, from start: Date?, to end: Date?) -> some View {
        if let start, let end {
            diagnosticLine(label, "\(Int((end.timeIntervalSince(start) * 1_000).rounded())) ms")
        }
    }

    private func networkText(status: String, interfaces: [String]) -> String {
        if status == "unsatisfied" || status == "requiresConnection" { return "Недоступна" }
        if interfaces.contains("wifi") { return "Wi-Fi" }
        if interfaces.contains("cellular") { return "Cellular" }
        if interfaces.contains("wiredEthernet") { return "Ethernet" }
        if interfaces.contains("other") { return "Інша" }
        return "Невідомо"
    }

    private func yesNo(_ value: Bool) -> String { value ? "Так" : "Ні" }
    private func optionalYesNo(_ value: Bool?) -> String { value.map(yesNo) ?? "Невідомо" }

    private func icon(for severity: SystemDialUserSummary.Severity) -> String {
        switch severity {
        case .neutral: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: SystemDialUserSummary.Severity) -> Color {
        switch severity {
        case .neutral: return .blue
        case .success: return .green
        case .warning: return .yellow
        case .failure: return .red
        }
    }
}
