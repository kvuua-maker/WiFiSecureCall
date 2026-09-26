#if os(iOS)
import CoreTelephony
import LiveCommunicationKit
import SwiftUI
import WatchConnectivity

#if compiler(>=6.4)
@available(iOS 27.0, *)
@MainActor
private struct IOSSystemCellularPlanStatusClient: CarrierCellularPlanStatusChecking {
    func authorizationStatus(for phoneNumber: String) async -> CarrierCellularPlanAuthorizationResult {
        do {
            switch try await CTCellularPlanStatus.authorizationStatus(forPhoneNumber: phoneNumber) {
            case .notAuthorized: return .notAuthorized
            case .authorized: return .authorized
            case .restricted: return .restricted
            case .notSupported: return .notSupported
            @unknown default: return .unknown
            }
        } catch {
            return .errorSafe
        }
    }

    func requestAuthorization(for phoneNumber: String) async -> CarrierCellularPlanAuthorizationResult {
        do {
            switch try await CTCellularPlanStatus.requestAuthorization(forPhoneNumber: phoneNumber) {
            case .notAuthorized: return .notAuthorized
            case .authorized: return .authorized
            case .restricted: return .restricted
            case .notSupported: return .notSupported
            @unknown default: return .unknown
            }
        } catch {
            return .errorSafe
        }
    }

    func statusHint(for phoneNumber: String) async -> CarrierCellularPlanAvailabilityResult {
        do {
            let (availability, confidence) = try await CTCellularPlanStatus.hint(forPhoneNumber: phoneNumber)
            switch (availability, confidence) {
            case (.available, .low): return .availableLowConfidence
            case (.available, .high): return .availableHighConfidence
            case (.unavailable, .low): return .unavailableLowConfidence
            case (.unavailable, .high): return .unavailableHighConfidence
            @unknown default: return .unknown
            }
        } catch {
            return .errorSafe
        }
    }
}
#endif

@MainActor
final class IOSCarrierCallingDiagnosticProbe: ObservableObject {
    @Published private(set) var record = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)

    private let networkInfo = CTTelephonyNetworkInfo()
    private let cellularData = CTCellularData()

    func refresh(network: CarrierCallingNetworkSnapshot) {
        let savedPlanAuthorization = record.cellularPlanAuthorization
        let savedPlanStatus = record.cellularPlanStatus
        var next = CarrierCallingDiagnosticRecord.baseline(platform: .iOS)
        next.network = network
        next.cellularPlanAuthorization = savedPlanAuthorization
        next.cellularPlanStatus = savedPlanStatus

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

    func checkCellularPlanStatus(
        e164: String,
        client override: (any CarrierCellularPlanStatusChecking)? = nil
    ) async {
        guard CarrierCallingE164.isPlausible(e164) else {
            record.cellularPlanAuthorization = "INVALID_E164"
            record.cellularPlanStatus = "NOT_CHECKED"
            return
        }

        guard let client = override ?? systemCellularPlanStatusClient() else {
            record.cellularPlanAuthorization = PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue
            record.cellularPlanStatus = PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue
            return
        }

        record.cellularPlanAuthorization = "CHECKING"
        record.cellularPlanStatus = "NOT_CHECKED"
        let result = await CarrierCellularPlanCheckWorkflow.check(
            phoneNumber: e164,
            client: client,
            authorizationRequired: { [weak self] in
                self?.record.cellularPlanAuthorization = "AUTHORIZATION_REQUIRED"
            }
        )
        record.cellularPlanAuthorization = result.authorization
        record.cellularPlanStatus = result.availability
    }

    private func systemCellularPlanStatusClient() -> (any CarrierCellularPlanStatusChecking)? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return IOSSystemCellularPlanStatusClient() }
        #endif
        return nil
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
    @ObservedObject private var observations = CarrierCallingObservationStore.shared
    @State private var e164Input = ""
    @State private var planCheckInProgress = false

    var body: some View {
        NavigationView {
            List {
                networkSection
                cellularSection
                planStatusSection
                observationSection
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
        .onDisappear {
            e164Input.removeAll(keepingCapacity: false)
            network.stop()
        }
    }

    private var networkSection: some View {
        Section("IPHONE NETWORK") {
            line("Status", probe.record.network.status)
            line("Interfaces", list(probe.record.network.interfaces))
            line("Expensive", optionalYesNo(probe.record.network.isExpensive))
            line("Constrained", optionalYesNo(probe.record.network.isConstrained))
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
            line("Cellular data", probe.record.cellularDataAccess)
            line("Providers", list(probe.record.serviceProviderLabels))
            line("Radio technology", list(probe.record.radioAccessTechnologies))
            line("System cellular call", probe.record.systemCellularCallCapability)
        }
    }

    private var planStatusSection: some View {
        Section("CELLULAR PLAN STATUS") {
            TextField("E.164 (+country code and number)", text: $e164Input)
                .keyboardType(.phonePad)
                .autocorrectionDisabled()
            Button("Check cellular plan status") {
                let transientNumber = e164Input
                planCheckInProgress = true
                Task {
                    await probe.checkCellularPlanStatus(e164: transientNumber)
                    planCheckInProgress = false
                }
            }
            .disabled(planCheckInProgress)
            line("Authorization", probe.record.cellularPlanAuthorization)
            line("Availability hint", probe.record.cellularPlanStatus)
        }
    }

    private var observationSection: some View {
        Section("BEFORE / AFTER") {
            Button("Capture BEFORE") {
                refresh()
                observations.captureBefore(CarrierCallingObservationSnapshot(record: probe.record), for: .iOS)
            }
            Button("Capture AFTER") {
                refresh()
                observations.captureAfter(CarrierCallingObservationSnapshot(record: probe.record), for: .iOS)
            }
            line("BEFORE", observations.beforeSnapshot(for: .iOS)?.conciseDescription ?? "NOT_CAPTURED")
            line("AFTER", observations.afterSnapshot(for: .iOS)?.conciseDescription ?? "NOT_CAPTURED")
            line("CHANGED FIELDS", changedFieldsText)
        }
    }

    private var changedFieldsText: String {
        guard observations.beforeSnapshot(for: .iOS) != nil,
              observations.afterSnapshot(for: .iOS) != nil else { return "NOT_READY" }
        let fields = observations.changedFields(for: .iOS)
        return fields.isEmpty ? "none" : fields.joined(separator: ", ")
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
        Section("CELLULAR ENTITLEMENT EVIDENCE") {
            line("Build44 offline verified", probe.record.build44OfflineCommCenterFineGrained)
            stateLine("Current running build", probe.record.currentBuildCommCenterFineGrained)
            line("Provisioning path", probe.record.publicProvisioningPathResult)
        }
    }

    private func refresh() { probe.refresh(network: network.snapshot) }
    private func list(_ values: [String]) -> String { values.isEmpty ? "none" : values.joined(separator: ", ") }
    private func optionalYesNo(_ value: Bool?) -> String { value.map { $0 ? "YES" : "NO" } ?? "UNKNOWN" }
    private func stateLine(_ title: String, _ state: PublicCarrierCallingState) -> some View { line(title, state.rawValue) }
    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
#endif
