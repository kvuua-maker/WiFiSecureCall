import Foundation

struct LocalContactSnapshot: Codable, Equatable, Sendable {
    static let formatVersion = 2

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
        (formatVersion == 1 || formatVersion == Self.formatVersion) && generation > 0 && contacts.count <= 10_000 &&
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

struct LocalContactNumber: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayValue: String
    let digits: String
    let canonicalE164: String?

    var isValid: Bool {
        !id.isEmpty && id.count <= 256 && !displayValue.isEmpty && displayValue.count <= 64 &&
        (3...15).contains(digits.count) && digits.allSatisfy(\.isNumber) &&
        (canonicalE164 == nil || (canonicalE164!.hasPrefix("+") && canonicalE164!.dropFirst().allSatisfy(\.isNumber)))
    }
}

struct LocalContactEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let numbers: [LocalContactNumber]

    init(id: String, name: String, numbers: [LocalContactNumber]) { self.id = id; self.name = name; self.numbers = numbers }
    init(id: String, name: String, normalizedNumbers: [String]) {
        self.id = id; self.name = name
        self.numbers = normalizedNumbers.enumerated().compactMap { index, value in
            guard let normalized = LocalPhoneNumberNormalizer.normalize(value) else { return nil }
            return LocalContactNumber(id: "\(id):\(index)", displayValue: value, digits: normalized.digits, canonicalE164: normalized.canonicalE164)
        }
    }

    var normalizedNumbers: [String] { numbers.map { $0.canonicalE164 ?? $0.displayValue } }

    var isValid: Bool {
        !id.isEmpty && id.count <= 256 && !name.isEmpty && name.count <= 256 &&
        !numbers.isEmpty && numbers.count <= 16 && numbers.allSatisfy(\.isValid)
    }

    private enum CodingKeys: String, CodingKey { case id, name, numbers, normalizedNumbers }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try values.decode(String.self, forKey: .id)
        let decodedName = try values.decode(String.self, forKey: .name)
        let decodedNumbers: [LocalContactNumber]
        if let decoded = try values.decodeIfPresent([LocalContactNumber].self, forKey: .numbers) { decodedNumbers = decoded }
        else {
            let legacy = try values.decode([String].self, forKey: .normalizedNumbers)
            decodedNumbers = legacy.enumerated().compactMap { index, value in
                guard let normalized = LocalPhoneNumberNormalizer.normalize(value) else { return nil }
                return LocalContactNumber(id: "\(decodedID):\(index)", displayValue: value, digits: normalized.digits, canonicalE164: normalized.canonicalE164)
            }
        }
        id = decodedID; name = decodedName; numbers = decodedNumbers
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name); try values.encode(numbers, forKey: .numbers)
    }
}

enum LocalPhoneNumberNormalizer {
    struct Result: Equatable { let digits: String; let canonicalE164: String? }
    static func normalize(_ value: String) -> Result? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || "+ -().".contains($0) }) else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard (3...15).contains(digits.count) else { return nil }
        if trimmed.hasPrefix("+") { return Result(digits: digits, canonicalE164: "+" + digits) }
        if trimmed.hasPrefix("00"), digits.count > 2 { return Result(digits: String(digits.dropFirst(2)), canonicalE164: "+" + String(digits.dropFirst(2))) }
        return Result(digits: digits, canonicalE164: nil)
    }
}
