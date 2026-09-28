import Foundation

struct MediaTransportDiagnostic: Sendable {
    let event: String
    let status: String
    let callID: UUID
    let errorDomain: String?
    let errorCode: Int?
}

enum MediaDisconnectReason: String, Sendable { case remoteClosed, authFailed, protocolViolation, serverRestart, transientNetwork, sendFailed, peerUnavailable, localClose }

enum MediaPeerIdentity: Equatable, Sendable {
    case legacy(DeviceRole)
    case account(CallPartySide)
    case secureAccount(CallPartySide)

    var queryName: String { switch self { case .legacy: return "role"; case .account, .secureAccount: return "side" } }
    var queryValue: String { switch self { case let .legacy(role): return role.rawValue; case let .account(side), let .secureAccount(side): return side.rawValue } }
    var protocolVersion: Int { if case .secureAccount = self { return 2 }; return 1 }
}

struct MediaDisconnect: Sendable {
    let callID: UUID
    let connectionID: UUID
    let closeCode: Int?
    let reason: MediaDisconnectReason
}

protocol MediaTransport: AnyObject, Sendable {
    var onPacket: (@Sendable (AudioPacket, UUID) -> Void)? { get set }
    var onDisconnect: (@Sendable (MediaDisconnect) -> Void)? { get set }
    var onPeerReady: (@Sendable (UUID, UUID) -> Void)? { get set }
    var onDiagnostic: (@Sendable (MediaTransportDiagnostic) -> Void)? { get set }
    func connect(callID: UUID, peer: MediaPeerIdentity, token: String) async throws -> UUID
    func send(_ packet: AudioPacket, connectionID: UUID) async throws
    func close(connectionID: UUID?) async
}

struct ReconnectSchedule: Equatable, Sendable {
    let intervals: [TimeInterval]
    init(total: TimeInterval = CallTimeouts.reconnectTotal) {
        var values: [TimeInterval] = [], elapsed: TimeInterval = 0, next: TimeInterval = 0.25
        while elapsed + next <= total { values.append(next); elapsed += next; next = min(next * 2, 2) }
        intervals = values
    }
}
