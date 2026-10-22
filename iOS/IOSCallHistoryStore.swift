import Foundation

/// One line of call history, shared by the Calls tab and the chat bubbles.
struct CallRecord: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case outgoing, incoming, missed, failed }
    let id: UUID
    let name: String
    let kind: Kind
    let date: Date
    let duration: Int

    var symbol: String {
        switch kind {
        case .outgoing: return "arrow.up.right"
        case .incoming: return "arrow.down.left"
        case .missed, .failed: return "phone.down.fill"
        }
    }
}

/// Call history, kept on the device that placed the calls.
@MainActor
final class CallHistoryStore: ObservableObject {
    static let shared = CallHistoryStore()
    @Published private(set) var records: [CallRecord] = []
    private let key = "ios.call.history.v1"
    private var lastStateDescription = ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CallRecord].self, from: data) {
            records = decoded
        }
    }

    func record(name: String, kind: CallRecord.Kind, duration: Int = 0) {
        let record = CallRecord(id: UUID(), name: name, kind: kind, date: Date(), duration: duration)
        records.insert(record, at: 0)
        if records.count > 100 { records.removeLast(records.count - 100) }
        persist()
    }

    func records(for name: String) -> [CallRecord] {
        records.filter { $0.name == name }
    }

    /// Observes a call session and writes one history entry per finished call.
    func observe(_ session: CallSession) {
        lastStateDescription = String(describing: session.state)
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let description = String(describing: session.state)
                guard description != self.lastStateDescription else { continue }
                self.lastStateDescription = description
                if case .ended = session.state, session.elapsedSeconds > 0 {
                    self.record(name: session.incomingCallerName ?? "App call", kind: .outgoing, duration: session.elapsedSeconds)
                }
                if case .failed = session.state {
                    self.record(name: session.incomingCallerName ?? "App call", kind: .failed)
                }
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
