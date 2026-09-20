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
}

