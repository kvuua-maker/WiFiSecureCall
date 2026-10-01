import Foundation

struct DiagnosticEvent: Sendable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let platform: String
    let role: DeviceRole
    let callID: UUID?
    let category: String
    let value: String
}

@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    @Published private(set) var events: [DiagnosticEvent] = []
    private let capacity = 500

    func record(role: DeviceRole, callID: UUID? = nil, category: String, value: String) {
        #if os(watchOS)
        let platform = "watchOS"
        #else
        let platform = "iOS"
        #endif
        events.append(.init(timestamp: Date(), platform: platform, role: role, callID: callID, category: category, value: value))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    func lastCallReport() -> String {
        guard let callID = events.reversed().compactMap(\.callID).first else {
            return "Діагностика останнього дзвінка відсутня."
        }
        let permitted = ["mic", "pcm", "network_audio", "media_peer", "encrypted_audio", "playback", "audio_", "state"]
        let formatter = ISO8601DateFormatter()
        let rows = events.filter { $0.callID == callID && permitted.contains(where: $0.category.contains) }
        return (["WiFi Secure Call — діагностика останнього дзвінка", "callID: \(callID.uuidString)"] + rows.map {
            "\(formatter.string(from: $0.timestamp)) \($0.platform)/\($0.role.rawValue) \($0.category): \($0.value)"
        }).joined(separator: "\n")
    }
}
