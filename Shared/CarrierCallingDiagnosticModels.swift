import Combine
import Foundation
import Network

enum PublicCarrierCallingState: String, Codable, CaseIterable, Equatable, Sendable {
    case yes = "YES"
    case no = "NO"
    case unknownPublicAPINotExposed = "UNKNOWN_PUBLIC_API_NOT_EXPOSED"
}

enum CarrierCallingPlatform: String, Codable, Equatable, Sendable {
    case iOS
    case watchOS
}

struct CarrierCallingNetworkSnapshot: Codable, Equatable, Sendable {
    let status: String
    let interfaces: [String]
    let isExpensive: Bool
    let isConstrained: Bool

    static let unknown = CarrierCallingNetworkSnapshot(
        status: "unknown",
        interfaces: [],
        isExpensive: false,
        isConstrained: false
    )
}

struct PublicCellularServiceSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let label: String
}

struct CarrierCallingDiagnosticRecord: Codable, Equatable, Sendable {
    let platform: CarrierCallingPlatform
    var network: CarrierCallingNetworkSnapshot
    var telephonyConversationManager: String
    var cellularServices: [PublicCellularServiceSnapshot]
    var selectedCellularService: String
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
    var signedCellularEntitlements: String
    var publicProvisioningPathResult: String

    static func baseline(platform: CarrierCallingPlatform) -> CarrierCallingDiagnosticRecord {
        CarrierCallingDiagnosticRecord(
            platform: platform,
            network: .unknown,
            telephonyConversationManager: platform == .watchOS ? "UNAVAILABLE_ON_WATCHOS" : "REQUIRES_IOS_26",
            cellularServices: [],
            selectedCellularService: PublicCarrierCallingState.unknownPublicAPINotExposed.rawValue,
            cellularPlanStatus: "SDK27_API_REQUIRES_EXPLICIT_E164_NOT_QUERIED",
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
            signedCellularEntitlements: "ABSENT_IN_SIGNED_BUILD44",
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
        return CarrierCallingNetworkSnapshot(
            status: status,
            interfaces: interfaces,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
