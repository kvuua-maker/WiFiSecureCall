#if os(watchOS)
import SwiftUI
import WatchConnectivity

@MainActor
final class WatchCarrierCallingDiagnosticProbe: ObservableObject {
    @Published private(set) var record = CarrierCallingDiagnosticRecord.baseline(platform: .watchOS)

    func refresh(network: CarrierCallingNetworkSnapshot) {
        let savedInternetCheck = record.firstPartyInternetCheck
        var next = CarrierCallingDiagnosticRecord.baseline(platform: .watchOS)
        next.firstPartyInternetCheck = savedInternetCheck
        next.network = network
        if WCSession.isSupported() {
            let session = WCSession.default
            next.watchAppInstalled = session.isCompanionAppInstalled
            next.watchConnectivityReachable = session.isReachable
            next.watchConnectivityState = Self.activationState(session.activationState)
        } else {
            next.watchAppInstalled = false
            next.watchConnectivityReachable = false
            next.watchConnectivityState = "unsupported"
        }
        record = next
    }

    func checkFirstPartyInternet() async {
        record.firstPartyInternetCheck = .checking
        record.firstPartyInternetCheck = await CarrierCallingFirstPartyInternetCheck.run()
    }

    private static func activationState(_ value: WCSessionActivationState) -> String {
        switch value {
        case .notActivated: return "notActivated"
        case .inactive: return "inactive"
        case .activated: return "activated"
        @unknown default: return "unknown"
        }
    }
}

struct WatchCarrierCallingDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var network = CarrierCallingNetworkProbe()
    @StateObject private var probe = WatchCarrierCallingDiagnosticProbe()
    @ObservedObject private var dialStore = SystemDialDiagnosticStore.shared
    @ObservedObject private var observations = CarrierCallingObservationStore.shared
    @State private var internetCheckTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("WATCH NETWORK") {
                line("NWPath monitor status", probe.record.network.status)
                line("NWPath interfaces", list(probe.record.network.interfaces))
                line("First-party Internet check", probe.record.firstPartyInternetCheck.rawValue)
                Button("Check first-party Internet") {
                    internetCheckTask?.cancel()
                    internetCheckTask = Task { await probe.checkFirstPartyInternet() }
                }
                line("Expensive", optionalYesNo(probe.record.network.isExpensive))
                line("Constrained", optionalYesNo(probe.record.network.isConstrained))
            }

            Section("WATCH COMPANION") {
                line("Companion app", optionalYesNo(probe.record.watchAppInstalled))
                line("WC state", probe.record.watchConnectivityState)
                line("WC reachable", optionalYesNo(probe.record.watchConnectivityReachable))
                stateLine("Companion telephony", probe.record.publicCompanionTelephonyState)
            }

            Section("SYSTEM CALLING") {
                line("Telephony manager", probe.record.telephonyConversationManager)
                line("Cellular services", PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue)
                line("Cellular plan status", probe.record.cellularPlanStatus)
                line("tel: handoff", probe.record.systemCellularCallCapability)
            }

            Section("BEFORE / AFTER") {
                Button("Capture BEFORE") {
                    refresh()
                    observations.captureBefore(currentObservation, for: .watchOS)
                }
                Button("Capture AFTER") {
                    refresh()
                    observations.captureAfter(currentObservation, for: .watchOS)
                }
                line("BEFORE", observations.beforeSnapshot(for: .watchOS)?.conciseDescription ?? "NOT_CAPTURED")
                line("AFTER", observations.afterSnapshot(for: .watchOS)?.conciseDescription ?? "NOT_CAPTURED")
                line("CHANGED", changedFieldsText)
            }

            Section("PUBLIC CALLING STATE") {
                stateLine("Wi-Fi Calling", probe.record.publicWiFiCallingState)
                stateLine("iCloud-device Calling", probe.record.publicICloudDeviceCallingState)
                stateLine("VoWiFi-iCloud entitlement", probe.record.publicVoWiFiICloudEntitlementState)
                stateLine("Thumper", probe.record.publicThumperState)
                stateLine("IMS", probe.record.publicIMSState)
            }

            Section("LAST tel: HANDOFF") {
                if let attempt = dialStore.attempts.first {
                    line("Result", safeClassification(attempt.classification))
                    line("Requested", yesNo(attempt.telHandoffRequestedAt != nil))
                    line("Watch resigned", yesNo(attempt.watchResignedActiveAt != nil))
                    line("Watch returned", yesNo(attempt.watchReturnedActiveAt != nil))
                } else {
                    line("Result", "NO_OBSERVATION")
                }
            }

            Section("CELLULAR ENTITLEMENT EVIDENCE") {
                line("Build44 offline verified", probe.record.build44OfflineCommCenterFineGrained)
                stateLine("Current running build", probe.record.currentBuildCommCenterFineGrained)
                line("Provisioning path", probe.record.publicProvisioningPathResult)
            }

            Button("Refresh") { refresh() }
            Button("Close") { dismiss() }
        }
        .navigationTitle("Carrier probe")
        .onAppear {
            network.start()
            refresh()
        }
        .onChange(of: network.snapshot) { value in probe.refresh(network: value) }
        .onDisappear {
            internetCheckTask?.cancel()
            network.stop()
        }
    }

    private var currentObservation: CarrierCallingObservationSnapshot {
        CarrierCallingObservationSnapshot(record: probe.record, systemDial: currentSystemDialObservation)
    }

    private var currentSystemDialObservation: CarrierCallingSystemDialObservation? {
        guard let attempt = dialStore.attempts.first else { return nil }
        return CarrierCallingSystemDialObservation(
            telHandoffRequested: attempt.telHandoffRequestedAt != nil,
            watchResignedActive: attempt.watchResignedActiveAt != nil,
            watchReturnedActive: attempt.watchReturnedActiveAt != nil,
            classification: safeClassification(attempt.classification)
        )
    }

    private var changedFieldsText: String {
        guard observations.beforeSnapshot(for: .watchOS) != nil,
              observations.afterSnapshot(for: .watchOS) != nil else { return "NOT_READY" }
        let fields = observations.changedFields(for: .watchOS)
        return fields.isEmpty ? "none" : fields.joined(separator: ", ")
    }

    private func safeClassification(_ value: String) -> String {
        SystemDialClassification.knownValues.contains(value) ? value : "UNKNOWN_SAFE_CLASSIFICATION"
    }

    private func refresh() { probe.refresh(network: network.snapshot) }
    private func list(_ values: [String]) -> String { values.isEmpty ? "none" : values.joined(separator: ", ") }
    private func yesNo(_ value: Bool) -> String { value ? "YES" : "NO" }
    private func optionalYesNo(_ value: Bool?) -> String { value.map(yesNo) ?? "UNKNOWN" }
    private func stateLine(_ title: String, _ state: PublicCarrierCallingState) -> some View { line(title, state.rawValue) }
    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }
}
#endif
