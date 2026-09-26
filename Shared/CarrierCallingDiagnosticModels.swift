import Combine
import Foundation
import Network

enum PublicCarrierCallingState: String, Codable, CaseIterable, Equatable, Sendable {
    case yes = "YES"
    case no = "NO"
    case unknownPublicAPINotExposed = "UNKNOWN_PUBLIC_API_NOT_EXPOSED"
}

enum CarrierCallingPlatform: String, Codable, Equatable, Hashable, Sendable {
    case iOS
    case watchOS
}

enum CarrierCellularPlanAuthorizationResult: Equatable, Sendable {
    case notAuthorized
    case authorized
    case restricted
    case notSupported
    case errorSafe
    case unknown
}

enum CarrierCellularPlanAvailabilityResult: Equatable, Sendable {
    case availableLowConfidence
    case availableHighConfidence
    case unavailableLowConfidence
    case unavailableHighConfidence
    case errorSafe
    case unknown
}

@MainActor
protocol CarrierCellularPlanStatusChecking {
    func authorizationStatus(for phoneNumber: String) async -> CarrierCellularPlanAuthorizationResult
    func requestAuthorization(for phoneNumber: String) async -> CarrierCellularPlanAuthorizationResult
    func statusHint(for phoneNumber: String) async -> CarrierCellularPlanAvailabilityResult
}

enum CarrierCallingE164 {
    static func isPlausible(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.first == "+" else { return false }
        let digits = value.dropFirst()
        guard (8...15).contains(digits.count), digits.first != "0" else { return false }
        return digits.allSatisfy { character in
            guard let ascii = character.asciiValue else { return false }
            return (48...57).contains(ascii)
        }
    }
}

struct CarrierCellularPlanCheckResult: Equatable, Sendable {
    let authorization: String
    let availability: String
}

enum CarrierCellularPlanCheckWorkflow {
    @MainActor
    static func check(
        phoneNumber: String,
        client: any CarrierCellularPlanStatusChecking,
        authorizationRequired: (() -> Void)? = nil
    ) async -> CarrierCellularPlanCheckResult {
        guard CarrierCallingE164.isPlausible(phoneNumber) else {
            return .init(authorization: "INVALID_E164", availability: "NOT_CHECKED")
        }

        let current = await client.authorizationStatus(for: phoneNumber)
        if current == .notAuthorized {
            authorizationRequired?()
            let requested = await client.requestAuthorization(for: phoneNumber)
            return await result(for: requested, phoneNumber: phoneNumber, client: client, requested: true)
        }
        return await result(for: current, phoneNumber: phoneNumber, client: client, requested: false)
    }

    @MainActor
    private static func result(
        for authorization: CarrierCellularPlanAuthorizationResult,
        phoneNumber: String,
        client: any CarrierCellularPlanStatusChecking,
        requested: Bool
    ) async -> CarrierCellularPlanCheckResult {
        switch authorization {
        case .authorized:
            return .init(
                authorization: "AUTHORIZED",
                availability: availabilityText(await client.statusHint(for: phoneNumber))
            )
        case .notAuthorized:
            return .init(
                authorization: requested ? "AUTHORIZATION_DENIED" : "AUTHORIZATION_REQUIRED",
                availability: "NOT_CHECKED"
            )
        case .restricted:
            return .init(authorization: "AUTHORIZATION_RESTRICTED", availability: "NOT_CHECKED")
        case .notSupported:
            return .init(authorization: "AUTHORIZATION_NOT_SUPPORTED", availability: "NOT_CHECKED")
        case .errorSafe:
            return .init(authorization: "ERROR_SAFE", availability: "ERROR_SAFE")
        case .unknown:
            return .init(
                authorization: PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue,
                availability: PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue
            )
        }
    }

    private static func availabilityText(_ value: CarrierCellularPlanAvailabilityResult) -> String {
        switch value {
        case .availableLowConfidence: return "AVAILABLE / CONFIDENCE_LOW"
        case .availableHighConfidence: return "AVAILABLE / CONFIDENCE_HIGH"
        case .unavailableLowConfidence: return "UNAVAILABLE / CONFIDENCE_LOW"
        case .unavailableHighConfidence: return "UNAVAILABLE / CONFIDENCE_HIGH"
        case .errorSafe: return "ERROR_SAFE"
        case .unknown: return PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue
        }
    }
}

struct CarrierCallingNetworkSnapshot: Codable, Equatable, Sendable {
    let status: String
    let interfaces: [String]
    let isExpensive: Bool?
    let isConstrained: Bool?

    static let unknown = CarrierCallingNetworkSnapshot(
        status: "unknown",
        interfaces: [],
        isExpensive: nil,
        isConstrained: nil
    )
}

struct PublicCellularServiceSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let label: String
}

struct CarrierCallingSystemDialObservation: Codable, Equatable, Sendable {
    let telHandoffRequested: Bool
    let watchResignedActive: Bool
    let watchReturnedActive: Bool
    let classification: String
}

struct CarrierCallingObservationSnapshot: Codable, Equatable, Sendable {
    let network: CarrierCallingNetworkSnapshot
    let cellularServices: [PublicCellularServiceSnapshot]
    let cellularPlanAuthorization: String
    let cellularPlanStatus: String
    let cellularDataAccess: String
    let serviceProviderLabels: [String]
    let radioAccessTechnologies: [String]
    let telephonyConversationManager: String
    let systemCellularCallCapability: String
    let watchPaired: Bool?
    let watchAppInstalled: Bool?
    let watchConnectivityReachable: Bool?
    let watchConnectivityState: String
    let systemDial: CarrierCallingSystemDialObservation?

    init(record: CarrierCallingDiagnosticRecord, systemDial: CarrierCallingSystemDialObservation? = nil) {
        network = record.network
        cellularServices = record.cellularServices.sorted { $0.id.uuidString < $1.id.uuidString }
        cellularPlanAuthorization = record.cellularPlanAuthorization
        cellularPlanStatus = record.cellularPlanStatus
        cellularDataAccess = record.cellularDataAccess
        serviceProviderLabels = record.serviceProviderLabels.sorted()
        radioAccessTechnologies = record.radioAccessTechnologies.sorted()
        telephonyConversationManager = record.telephonyConversationManager
        systemCellularCallCapability = record.systemCellularCallCapability
        watchPaired = record.watchPaired
        watchAppInstalled = record.watchAppInstalled
        watchConnectivityReachable = record.watchConnectivityReachable
        watchConnectivityState = record.watchConnectivityState
        self.systemDial = systemDial
    }

    func changedFields(comparedTo before: CarrierCallingObservationSnapshot) -> [String] {
        var fields: [String] = []
        if network.status != before.network.status { fields.append("network.status") }
        if network.interfaces != before.network.interfaces { fields.append("network.interfaces") }
        if network.isExpensive != before.network.isExpensive { fields.append("network.expensive") }
        if network.isConstrained != before.network.isConstrained { fields.append("network.constrained") }
        if cellularServices != before.cellularServices { fields.append("cellularServices") }
        if cellularPlanAuthorization != before.cellularPlanAuthorization { fields.append("cellularPlan.authorization") }
        if cellularPlanStatus != before.cellularPlanStatus { fields.append("cellularPlan.status") }
        if cellularDataAccess != before.cellularDataAccess { fields.append("cellularData") }
        if serviceProviderLabels != before.serviceProviderLabels { fields.append("providers") }
        if radioAccessTechnologies != before.radioAccessTechnologies { fields.append("radioTechnology") }
        if telephonyConversationManager != before.telephonyConversationManager { fields.append("telephonyManager") }
        if systemCellularCallCapability != before.systemCellularCallCapability { fields.append("systemCellularCall") }
        if watchPaired != before.watchPaired { fields.append("watch.paired") }
        if watchAppInstalled != before.watchAppInstalled { fields.append("watch.appInstalled") }
        if watchConnectivityReachable != before.watchConnectivityReachable { fields.append("watch.reachable") }
        if watchConnectivityState != before.watchConnectivityState { fields.append("watch.activation") }
        if systemDial != before.systemDial { fields.append("watch.telHandoff") }
        return fields
    }

    var conciseDescription: String {
        let services = cellularServices.map { "\($0.label)[\($0.id.uuidString)]" }.joined(separator: ",")
        return [
            "network=\(network.status)/\(network.interfaces.joined(separator: ","))",
            "services=\(cellularServices.count):\(services)",
            "planAuth=\(cellularPlanAuthorization)",
            "planStatus=\(cellularPlanStatus)",
            "cellularData=\(cellularDataAccess)",
            "radio=\(radioAccessTechnologies.joined(separator: ","))",
            "providers=\(serviceProviderLabels.joined(separator: ","))",
            "telephony=\(telephonyConversationManager)",
            "systemCall=\(systemCellularCallCapability)",
            "wc=\(watchConnectivityState)/\(Self.optionalBool(watchConnectivityReachable))",
            "companion=\(Self.optionalBool(watchPaired))/\(Self.optionalBool(watchAppInstalled))",
            systemDial.map {
                "handoff=\(Self.bool($0.telHandoffRequested))/\(Self.bool($0.watchResignedActive))/\(Self.bool($0.watchReturnedActive))/\($0.classification)"
            } ?? "handoff=none",
        ].joined(separator: "\n")
    }

    private static func bool(_ value: Bool) -> String { value ? "YES" : "NO" }
    private static func optionalBool(_ value: Bool?) -> String { value.map(bool) ?? "UNKNOWN" }
}

@MainActor
final class CarrierCallingObservationStore: ObservableObject {
    static let shared = CarrierCallingObservationStore()

    @Published private var before: [CarrierCallingPlatform: CarrierCallingObservationSnapshot] = [:]
    @Published private var after: [CarrierCallingPlatform: CarrierCallingObservationSnapshot] = [:]

    func captureBefore(_ snapshot: CarrierCallingObservationSnapshot, for platform: CarrierCallingPlatform) {
        before[platform] = snapshot
        after.removeValue(forKey: platform)
    }

    func captureAfter(_ snapshot: CarrierCallingObservationSnapshot, for platform: CarrierCallingPlatform) {
        after[platform] = snapshot
    }

    func beforeSnapshot(for platform: CarrierCallingPlatform) -> CarrierCallingObservationSnapshot? { before[platform] }
    func afterSnapshot(for platform: CarrierCallingPlatform) -> CarrierCallingObservationSnapshot? { after[platform] }

    func changedFields(for platform: CarrierCallingPlatform) -> [String] {
        guard let before = before[platform], let after = after[platform] else { return [] }
        return after.changedFields(comparedTo: before)
    }
}

struct CarrierCallingDiagnosticRecord: Codable, Equatable, Sendable {
    let platform: CarrierCallingPlatform
    var network: CarrierCallingNetworkSnapshot
    var telephonyConversationManager: String
    var cellularServices: [PublicCellularServiceSnapshot]
    var selectedCellularService: String
    var cellularPlanAuthorization: String
    var cellularPlanStatus: String
    var cellularDataAccess: String
    var serviceProviderLabels: [String]
    var radioAccessTechnologies: [String]
    var watchPaired: Bool?
    var watchAppInstalled: Bool?
    var watchConnectivityReachable: Bool?
    var watchConnectivityState: String
    var systemCellularCallCapability: String
    var publicWiFiCallingState: PublicCarrierCallingState
    var publicICloudDeviceCallingState: PublicCarrierCallingState
    var publicVoWiFiICloudEntitlementState: PublicCarrierCallingState
    var publicThumperState: PublicCarrierCallingState
    var publicIMSState: PublicCarrierCallingState
    var publicCompanionTelephonyState: PublicCarrierCallingState
    var build44OfflineCommCenterFineGrained: String
    var currentBuildCommCenterFineGrained: PublicCarrierCallingState
    var publicProvisioningPathResult: String

    static func baseline(platform: CarrierCallingPlatform) -> CarrierCallingDiagnosticRecord {
        CarrierCallingDiagnosticRecord(
            platform: platform,
            network: .unknown,
            telephonyConversationManager: platform == .watchOS ? "UNAVAILABLE_ON_WATCHOS" : "REQUIRES_IOS_26",
            cellularServices: [],
            selectedCellularService: PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue,
            cellularPlanAuthorization: "NOT_CHECKED",
            cellularPlanStatus: "NOT_CHECKED",
            cellularDataAccess: PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue,
            serviceProviderLabels: [],
            radioAccessTechnologies: [],
            watchPaired: nil,
            watchAppInstalled: nil,
            watchConnectivityReachable: nil,
            watchConnectivityState: "unknown",
            systemCellularCallCapability: platform == .watchOS ? "TEL_HANDOFF_REQUEST_API_AVAILABLE" : "REQUIRES_IOS_26",
            publicWiFiCallingState: .unknownPublicAPINotExposed,
            publicICloudDeviceCallingState: .unknownPublicAPINotExposed,
            publicVoWiFiICloudEntitlementState: .unknownPublicAPINotExposed,
            publicThumperState: .unknownPublicAPINotExposed,
            publicIMSState: .unknownPublicAPINotExposed,
            publicCompanionTelephonyState: .unknownPublicAPINotExposed,
            build44OfflineCommCenterFineGrained: "BUILD44_OFFLINE_VERIFIED_COMM_CENTER_FINE_GRAINED_ABSENT",
            currentBuildCommCenterFineGrained: .unknownPublicAPINotExposed,
            publicProvisioningPathResult: "NO_PUBLIC_PATH_FOUND"
        )
    }
}

enum CarrierCallingPublicSurface {
    static let callableFrameworks = [
        "CoreTelephony",
        "LiveCommunicationKit",
        "CallKit",
        "Network",
        "NetworkExtension",
        "WatchConnectivity",
        "AVFAudio",
        "WatchKit",
    ]

    static let usesPrivateAPI = false
    static let accessesSIMOrIMSSecrets = false
}

@MainActor
final class CarrierCallingNetworkProbe: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot = CarrierCallingNetworkSnapshot.unknown

    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.carrierProbe.network")
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let next = NWPathMonitor()
        next.pathUpdateHandler = { [weak self] path in
            let value = Self.safeSnapshot(from: path)
            Task { @MainActor [weak self] in self?.snapshot = value }
        }
        monitor = next
        next.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    nonisolated private static func safeSnapshot(from path: NWPath) -> CarrierCallingNetworkSnapshot {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wiredEthernet") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        return .init(
            status: status,
            interfaces: interfaces,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
