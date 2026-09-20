import Foundation

protocol MediaTransport: AnyObject, Sendable {
    var onPacket: (@Sendable (AudioPacket) -> Void)? { get set }
    var onDisconnect: (@Sendable () -> Void)? { get set }
    func connect(callID: UUID, role: DeviceRole, token: String) async throws
    func send(_ packet: AudioPacket) async throws
    func close() async
}

struct ReconnectSchedule: Equatable, Sendable {
    let intervals: [TimeInterval]
    init(total: TimeInterval = CallTimeouts.reconnectTotal) {
        var values: [TimeInterval] = [], elapsed: TimeInterval = 0, next: TimeInterval = 0.25
        while elapsed + next <= total { values.append(next); elapsed += next; next = min(next * 2, 2) }
        intervals = values
    }
}
