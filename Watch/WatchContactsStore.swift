import SwiftUI

/// A person the watch can call.
struct WatchContact: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let isSelf: Bool

    var initials: String {
        let letters = name.compactMap { $0.isLetter ? String($0) : nil }
        let value = letters.prefix(2).joined().uppercased()
        return value.isEmpty ? "?" : value
    }

    var hue: Double {
        // A stable colour per contact, so the same person always looks the same.
        let scalar = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Double(scalar % 360) / 360.0
    }
}

/// The people on this wrist.
///
/// The watch keeps its own account, and the paired iPhone publishes its account
/// list over WatchConnectivity. Both are merged here so the list looks the same on
/// both devices without either device holding the other's tokens.
@MainActor
final class WatchContactsStore: ObservableObject {
    static let shared = WatchContactsStore()

    @Published private(set) var contacts: [WatchContact] = []
    private let hiddenKey = "watch.contacts.hidden.v1"
    private var hidden: Set<String> = []

    private init() {
        if let stored = UserDefaults.standard.stringArray(forKey: hiddenKey) {
            hidden = Set(stored)
        }
        refresh(synced: [])
    }

    func refresh(synced: [String]) {
        var seen = Set<String>()
        var result: [WatchContact] = []

        if let account = AccountSessionStore.shared.activeAccount {
            let name = account.displayLabel.isEmpty ? "Me" : account.displayLabel
            result.append(WatchContact(id: account.accountID.uuidString, name: name, detail: "This Watch", isSelf: true))
            seen.insert(account.accountID.uuidString)
        }
        for label in synced where !label.isEmpty {
            let id = "synced:" + label
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(WatchContact(id: id, name: label, detail: "iPhone", isSelf: false))
        }
        contacts = result.filter { !hidden.contains($0.id) }
    }

    /// A simulator has no accounts, so UI tests get two stable rows to act on.
    func seedForUITesting() {
        guard contacts.isEmpty else { return }
        contacts = [
            WatchContact(id: "ui-1", name: "Alex Rivera", detail: "iPhone", isSelf: false),
            WatchContact(id: "ui-2", name: "Sam Lee", detail: "iPhone", isSelf: false)
        ]
    }

    func hide(_ contact: WatchContact) {
        hidden.insert(contact.id)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
        contacts.removeAll { $0.id == contact.id }
    }

    /// The person a Mode A call is placed to: the first contact that is not me.
    var callable: WatchContact? {
        contacts.first { !$0.isSelf } ?? contacts.first
    }
}
