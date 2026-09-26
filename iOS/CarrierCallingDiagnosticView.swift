#if os(iOS)
import CoreTelephony
import LiveCommunicationKit
import SwiftUI
import WatchConnectivity

@MainActor
final class IOSCarrierCallingDiagnosticProbe: ObservableObject {
    @Published private(set) var record = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)

    private let networkInfo = CTTelephonyNetworkInfo()
    private let cellularData = CTCellularData()

    func refresh(network: CarrierCallingNetworkSnapshot) {
        var next = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        next.network = network

        if #available(iOS 26.0, *) {
            let services = TelephonyConversationManager.sharedInstance.cellularServices
            next.telephonyConversationManager = "AVAILABLE"
            next.cellularServices = services.map {
                PublicCellularServiceSnapshot(id: $0.id, label: Self.safeLabel($0.label))
            }
            next.systemCellularCallCapability = "REQUEST_API_AVAILABLE"
        }

        next.cellularDataAccess = Self.cellularDataText(cellularData.restrictedState)
        next.radioAccessTechnologies = Array(Set(
            (networkInfo.serviceCurrentRadioAccessTechnology ?? [:]).values.map(Self.radioTechnologyText)
        )).sorted()

        next.serviceProviderLabels = Array(Set(
                (networkInfo.serviceSubscriberCellularProviders ?? [:]).values.compactMap { carrier in
                    guard let name = carrier.carrierName, name != "--" else { return nil }
                    let country = carrier.isoCountryCode.flatMap { $0 == "--" ? nil : $0.uppercased() }
                    return Self.safeLabel(country.map { "\(name) (\($0))" } ?? name)
                }
            )).sorted()

        if WCSession.isSupported() {
            let session = WCSession.default
            next.watchPaired = session.isPaired
            next.watchAppInstalled = session.isWatchAppInstalled
            next.watchConnectivityReachable = session.isReachable
            next.watchConnectivityState = Self.activationState(session.activationState)
        } else {
            next.watchPaired = false
            next.watchAppInstalled = false
            next.watchConnectivityReachable = false
            next.watchConnectivityState = "unsupported"
        }
        record = next
    }

    private static func cellularDataText(_ value: CTCellularDataRestrictedState) -> String {
        switch value {
        case .notRestricted: return "NOT_RESTRICTED"
        case .restricted: return "RESTRICTED"
        case .restrictedStateUnknown: return "UNKNOWN"
        @unknown default: return "UNKNOWN"
        }
    }

    private static func radioTechnologyText(_ value: String) -> String {
        switch value {
        case CTRadioAccessTechnologyGPRS: return "GPRS"
        case CTRadioAccessTechnologyEdge: return "EDGE"
        case CTRadioAccessTechnologyWCDMA: return "WCDMA"
        case CTRadioAccessTechnologyHSDPA: return "HSDPA"
        case CTRadioAccessTechnologyHSUPA: return "HSUPA"
        case CTRadioAccessTechnologyCDMA1x: return "CDMA1x"
        case CTRadioAccessTechnologyCDMAEVDORev0: return "EVDO Rev0"
        case CTRadioAccessTechnologyCDMAEVDORevA: return "EVDO RevA"
        case CTRadioAccessTechnologyCDMAEVDORevB: return "EVDO RevB"
        case CTRadioAccessTechnologyeHRPD: return "eHRPD"
        case CTRadioAccessTechnologyLTE: return "LTE"
        case CTRadioAccessTechnologyNRNSA: return "5G NSA"
        case CTRadioAccessTechnologyNR: return "5G NR"
        default: return "OTHER_PUBLIC_VALUE"
        }
    }

    private static func activationState(_ value: WCSessionActivationState) -> String {
        switch value {
        case .notActivated: return "notActivated"
        case .inactive: return "inactive"
        case .activated: return "activated"
        @unknown default: return "unknown"
        }
    }

    private static func safeLabel(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_.()"))
        let filtered = value.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((result.isEmpty ? "Unnamed" : result).prefix(80))
    }
}

struct CarrierCallingDiagnosticView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var network = CarrierCallingNetworkProbe()
    @StateObject private var probe = IOSCarrierCallingDiagnosticProbe()

    var body: some View {
        NavigationView {
            List {
                networkSection
                cellularSection
                publicStateSection
                companionSection
                entitlementSection
            }
            .navigationTitle("Carrier probe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { refresh() } }
            }
        }
        .onAppear {
            network.start()
            refresh()
        }
        .onChange(of: network.snapshot) { value in probe.refresh(network: value) }
        .onDisappear { network.stop() }
    }

    private var networkSection: some View {
        Section("IPHONE NETWORK") {
            line("Status", probe.record.network.status)
            line("Interfaces", list(probe.record.network.interfaces))
            line("Expensive", yesNo(probe.record.network.isExpensive))
            line("Constrained", yesNo(probe.record.network.isConstrained))
        }
    }

    private var cellularSection: some View {
        Section("CELLULAR SERVICES") {
            line("Telephony manager", probe.record.telephonyConversationManager)
            line("Count", String(probe.record.cellularServices.count))
            ForEach(probe.record.cellularServices) { service in
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.label)
                    Text(service.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            line("Selected service", probe.record.selectedCellularService)
            line("Cellular plan status", probe.record.cellularPlanStatus)
            line("Cellular data", probe.record.cellularDataAccess)
            line("Providers", list(probe.record.serviceProviderLabels))
            line("Radio technology", list(probe.record.radioAccessTechnologies))
            line("System cellular call", probe.record.systemCellularCallCapability)
        }
    }

    private var publicStateSection: some View {
        Section("PUBLIC CALLING STATE") {
            stateLine("Wi-Fi Calling", probe.record.publicWiFiCallingState)
            stateLine("iCloud-device Calling", probe.record.publicICloudDeviceCallingState)
            stateLine("VoWiFi-iCloud entitlement", probe.record.publicVoWiFiICloudEntitlementState)
            stateLine("Thumper", probe.record.publicThumperState)
            stateLine("IMS", probe.record.publicIMSState)
            stateLine("Companion telephony", probe.record.publicCompanionTelephonyState)
        }
    }

    private var companionSection: some View {
        Section("WATCH COMPANION") {
            line("Paired", optionalYesNo(probe.record.watchPaired))
            line("Watch app installed", optionalYesNo(probe.record.watchAppInstalled))
            line("WC state", probe.record.watchConnectivityState)
            line("WC reachable", optionalYesNo(probe.record.watchConnectivityReachable))
        }
    }

    private var entitlementSection: some View {
        Section("SIGNED CELLULAR ENTITLEMENTS") {
            line("CommCenter fine-grained", probe.record.signedCellularEntitlements)
            line("Provisioning path", probe.record.publicProvisioningPathResult)
        }
    }

    private func refresh() { probe.refresh(network: network.snapshot) }
    private func list(_ values: [String]) -> String { values.isEmpty ? "none" : values.joined(separator: ", ") }
    private func yesNo(_ value: Bool) -> String { value ? "YES" : "NO" }
    private func optionalYesNo(_ value: Bool?) -> String { value.map(yesNo) ?? "UNKNOWN" }
    private func stateLine(_ title: String, _ state: PublicCarrierCallingState) -> some View { line(title, state.rawValue) }
    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
#endif
