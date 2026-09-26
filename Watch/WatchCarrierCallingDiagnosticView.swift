#if os(watchOS)
import SwiftUI
import WatchConnectivity

@MainActor
final class WatchCarrierCallingDiagnosticProbe: ObservableObject {
    @Published private(set) var record = CarrierCallingDiagnosticRecord.baseline(platform: .watchOS)

    func refresh(network: CarrierCallingNetworkSnapshot) {
        var next = CarrierCallingDiagnosticRecord.baseline(platform: .watchOS)
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

    var body: some View {
        List {
            Section("WATCH NETWORK") {
                line("Status", probe.record.network.status)
                line("Interfaces", list(probe.record.network.interfaces))
                line("Expensive", yesNo(probe.record.network.isExpensive))
                line("Constrained", yesNo(probe.record.network.isConstrained))
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

            Section("PUBLIC CALLING STATE") {
                stateLine("Wi-Fi Calling", probe.record.publicWiFiCallingState)
                stateLine("iCloud-device Calling", probe.record.publicICloudDeviceCallingState)
                stateLine("VoWiFi-iCloud entitlement", probe.record.publicVoWiFiICloudEntitlementState)
                stateLine("Thumper", probe.record.publicThumperState)
                stateLine("IMS", probe.record.publicIMSState)
            }

            Section("LAST tel: HANDOFF") {
                if let attempt = dialStore.attempts.first {
                    line("Result", attempt.classification)
                    line("Requested", yesNo(attempt.telHandoffRequestedAt != nil))
                    line("Watch resigned", yesNo(attempt.watchResignedActiveAt != nil))
                    line("Watch returned", yesNo(attempt.watchReturnedActiveAt != nil))
                } else {
                    line("Result", "NO_OBSERVATION")
                }
            }

            Section("SIGNED CELLULAR ENTITLEMENTS") {
                line("CommCenter fine-grained", probe.record.signedCellularEntitlements)
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
        .onDisappear { network.stop() }
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
