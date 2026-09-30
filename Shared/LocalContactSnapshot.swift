import Foundation

struct LocalContactSnapshot: Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let generation: UInt64
    let updatedAt: Date
    let contacts: [LocalContactEntry]

    init(generation: UInt64, updatedAt: Date = Date(), contacts: [LocalContactEntry]) {
        self.formatVersion = Self.formatVersion
        self.generation = generation
        self.updatedAt = updatedAt
        self.contacts = contacts
    }

    var isValid: Bool {
        formatVersion == Self.formatVersion && generation > 0 && contacts.count <= 10_000 &&
        contacts.allSatisfy(\.isValid)
    }
}

final class LocalContactGenerationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "localContacts.snapshotGeneration") {
        self.defaults = defaults
        self.key = key
    }

    func next() -> UInt64 {
        lock.wscLocked {
            let current = UInt64(max(0, defaults.integer(forKey: key)))
            let next = current == UInt64.max ? current : current + 1
            defaults.set(next, forKey: key)
            return max(next, 1)
        }
    }

    var current: UInt64 { lock.wscLocked { UInt64(max(0, defaults.integer(forKey: key))) } }
}

final class LocalContactSnapshotDiskCache: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func load() -> LocalContactSnapshot? {
        lock.wscLocked {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(LocalContactSnapshot.self, from: data),
                  snapshot.isValid else { return nil }
            return snapshot
        }
    }

    @discardableResult
    func storeIfNewer(_ snapshot: LocalContactSnapshot) -> Bool {
        guard snapshot.isValid else { return false }
        return lock.wscLocked {
            if let data = try? Data(contentsOf: url),
               let current = try? JSONDecoder().decode(LocalContactSnapshot.self, from: data),
               current.isValid, current.generation >= snapshot.generation { return false }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                return true
            } catch { return false }
        }
    }
}

struct LocalContactEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let normalizedNumbers: [String]

    var isValid: Bool {
        !id.isEmpty && id.count <= 256 && !name.isEmpty && name.count <= 256 &&
        !normalizedNumbers.isEmpty && normalizedNumbers.count <= 16 &&
        normalizedNumbers.allSatisfy { $0.hasPrefix("+") && $0.dropFirst().allSatisfy(\.isNumber) && (4...15).contains($0.dropFirst().count) }
    }
}

enum LocalPhoneNumberNormalizer {
    static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return nil }
        let digits = trimmed.dropFirst().filter(\.isNumber)
        guard (4...15).contains(digits.count),
              trimmed.dropFirst().allSatisfy({ $0.isNumber || " -().".contains($0) }) else { return nil }
        return "+" + digits
    }
}
