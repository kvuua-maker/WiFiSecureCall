import Foundation

struct DiagnosticEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let platform: String
    let role: DeviceRole
    let callID: UUID?
    let category: String
    let value: String

    init(id: UUID = UUID(), timestamp: Date, platform: String, role: DeviceRole, callID: UUID?, category: String, value: String) {
        self.id = id
        self.timestamp = timestamp
        self.platform = platform
        self.role = role
        self.callID = callID
        self.category = category
        self.value = value
    }
}

@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    @Published private(set) var events: [DiagnosticEvent] = []
    private let capacity = 500
    private let persistedCapacity = 300
    private let retention: TimeInterval = 7 * 24 * 60 * 60
    private let defaults: UserDefaults
    private let storageKey = "WiFiSecureCall.safeCallDiagnostics.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let cutoff = Date().addingTimeInterval(-retention)
        events = (defaults.data(forKey: storageKey)).flatMap { try? JSONDecoder().decode([DiagnosticEvent].self, from: $0) }?.filter { $0.timestamp >= cutoff } ?? []
    }

    func record(role: DeviceRole, callID: UUID? = nil, category: String, value: String) {
        #if os(watchOS)
        let platform = "watchOS"
        #else
        let platform = "iOS"
        #endif
        events.append(.init(timestamp: Date(), platform: platform, role: role, callID: callID, category: category, value: value))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        persistSafeEvents()
    }

    private func persistSafeEvents() {
        let cutoff = Date().addingTimeInterval(-retention)
        let safe = events.filter { event in
            event.timestamp >= cutoff && event.callID != nil && Self.permittedCategory(event.category)
        }.suffix(persistedCapacity)
        defaults.set(try? JSONEncoder().encode(Array(safe)), forKey: storageKey)
    }

    private static func permittedCategory(_ category: String) -> Bool {
        ["mic", "pcm", "network_audio", "media_peer", "encrypted_audio", "playback", "audio_", "state"].contains(where: category.contains)
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
