import CryptoKit
import Foundation

enum CallHistoryDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

enum CallHistoryStatus: String, Codable, Sendable {
    case ringing
    case active
    case answered
    case missed
    case rejected
    case failed

    var isTerminal: Bool {
        switch self {
        case .answered, .missed, .rejected, .failed: return true
        case .ringing, .active: return false
        }
    }
}

struct CallHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let accountID: UUID?
    let direction: CallHistoryDirection
    let peerDisplayName: String
    let startedAt: Date
    var terminalAt: Date?
    var status: CallHistoryStatus
    let deduplicationToken: String?
    var targetUserID: UUID? = nil
}

protocol CallHistoryPersisting: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

final class CallHistoryFilePersistence: CallHistoryPersisting {
    private let url: URL

    init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        url = root.appendingPathComponent("WiFiSecureCall", isDirectory: true)
            .appendingPathComponent("call-history-v1.json", isDirectory: false)
    }

    func load() throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func save(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

@MainActor
final class CallHistoryStore: ObservableObject {
    static let shared = CallHistoryStore()

    @Published private(set) var records: [CallHistoryRecord] = []
    private let persistence: CallHistoryPersisting
    private let retentionLimit: Int
    private struct LogicalCallKey: Hashable {
        let accountID: UUID?
        let logicalCallID: UUID
    }

    private var logicalRecordIDs: [LogicalCallKey: UUID] = [:]
    private var logicalCallOrder: [LogicalCallKey] = []
    private let logicalCallLimit = 128

    init(persistence: CallHistoryPersisting = CallHistoryFilePersistence(), retentionLimit: Int = 100) {
        self.persistence = persistence
        self.retentionLimit = max(1, retentionLimit)
        if let data = try? persistence.load(),
           let decoded = try? JSONDecoder.wscISO8601.decode([CallHistoryRecord].self, from: data) {
            var recovered = decoded
            var repairedInterruptedState = false
            for index in recovered.indices where !recovered[index].status.isTerminal {
                recovered[index].status = recovered[index].direction == .incoming && recovered[index].status == .ringing ? .missed : .failed
                recovered[index].terminalAt = recovered[index].terminalAt ?? Date()
                repairedInterruptedState = true
            }
            records = Array(recovered.sorted { $0.startedAt > $1.startedAt }.prefix(self.retentionLimit))
            if repairedInterruptedState, let repaired = try? JSONEncoder.wscISO8601.encode(records) {
                try? persistence.save(repaired)
            }
        }
    }

    func records(for accountID: UUID?) -> [CallHistoryRecord] {
        guard let accountID else { return [] }
        return records.filter { $0.accountID == accountID }
    }

    @discardableResult
    func begin(accountID: UUID?, logicalCallID: UUID, direction: CallHistoryDirection, peerDisplayName: String?, targetUserID: UUID? = nil, at date: Date = Date()) -> UUID {
        let logicalKey = LogicalCallKey(accountID: accountID, logicalCallID: logicalCallID)
        if let existing = logicalRecordIDs[logicalKey] { return existing }
        let token = Self.deduplicationToken(accountID: accountID, logicalCallID: logicalCallID)
        if let existing = records.first(where: { $0.accountID == accountID && $0.deduplicationToken == token }) {
            logicalRecordIDs[logicalKey] = existing.id
            return existing.id
        }
        let id = UUID()
        let safeName = Self.safeDisplayName(peerDisplayName)
        records.insert(CallHistoryRecord(
            id: id,
            accountID: accountID,
            direction: direction,
            peerDisplayName: safeName,
            startedAt: date,
            terminalAt: nil,
            status: .ringing,
            deduplicationToken: token,
            targetUserID: targetUserID
        ), at: 0)
        logicalRecordIDs[logicalKey] = id
        logicalCallOrder.append(logicalKey)
        if logicalCallOrder.count > logicalCallLimit {
            for expired in logicalCallOrder.prefix(logicalCallOrder.count - logicalCallLimit) {
                logicalRecordIDs.removeValue(forKey: expired)
            }
            logicalCallOrder.removeFirst(logicalCallOrder.count - logicalCallLimit)
        }
        retainAndPersist()
        return id
    }

    func markActive(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].status.isTerminal else { return }
        records[index].status = .active
        persist()
    }

    func finish(_ id: UUID, status requestedStatus: CallHistoryStatus, at date: Date = Date()) {
        guard requestedStatus.isTerminal,
              let index = records.firstIndex(where: { $0.id == id }),
              !records[index].status.isTerminal else { return }
        records[index].status = records[index].status == .active ? .answered : requestedStatus
        records[index].terminalAt = date
        records.sort { $0.startedAt > $1.startedAt }
        retainAndPersist()
    }

    private func retainAndPersist() {
        if records.count > retentionLimit { records.removeLast(records.count - retentionLimit) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder.wscISO8601.encode(records) else { return }
        try? persistence.save(data)
    }

    private static func safeDisplayName(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return "Secure contact" }
        if trimmed.filter(\.isNumber).count >= 7 {
            return "Secure contact"
        }
        return trimmed
    }

    private static func deduplicationToken(accountID: UUID?, logicalCallID: UUID) -> String {
        let value: String
        if let accountID {
            value = "wsc-call-history-v2:\(accountID.uuidString.lowercased()):\(logicalCallID.uuidString.lowercased())"
        } else {
            value = "wsc-call-history-v1:\(logicalCallID.uuidString.lowercased())"
        }
        let material = Data(value.utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var wscISO8601: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }
}

private extension JSONDecoder {
    static var wscISO8601: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
