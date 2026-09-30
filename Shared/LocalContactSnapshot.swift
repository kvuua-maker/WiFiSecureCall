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
