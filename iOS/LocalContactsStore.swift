import Combine
import Contacts
import Foundation
import UIKit

@MainActor
final class LocalContactsStore: ObservableObject {
    static let shared = LocalContactsStore()

    @Published private(set) var authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var contacts: [LocalContactEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatedAt: Date?

    private let store = CNContactStore()
    private let generationStore = LocalContactGenerationStore()
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        observer = notificationCenter.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAuthorizationAndContacts() }
        }
        refreshAuthorizationAndContacts()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var hasReadableAuthorization: Bool {
        if authorizationStatus == .authorized { return true }
        if #available(iOS 18.0, *), authorizationStatus == .limited { return true }
        return false
    }

    func requestAccess() {
        store.requestAccess(for: .contacts) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAuthorizationAndContacts() }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func refreshAuthorizationAndContacts() {
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard hasReadableAuthorization else {
            contacts = []
            updatedAt = nil
            errorMessage = nil
            ContactsToWatchSync.shared.publishCleared(generation: generationStore.next())
            return
        }
        do {
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as NSString, CNContactFamilyNameKey as NSString, CNContactPhoneNumbersKey as NSString]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var loaded: [LocalContactEntry] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let numbers = Array(Set(contact.phoneNumbers.compactMap { LocalPhoneNumberNormalizer.normalize($0.value.stringValue) })).sorted()
                guard !numbers.isEmpty else { return }
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                loaded.append(.init(id: contact.identifier, name: name.isEmpty ? "Без імені" : name, normalizedNumbers: numbers))
            }
            contacts = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let snapshot = LocalContactSnapshot(generation: generationStore.next(), contacts: contacts)
            updatedAt = snapshot.updatedAt
            errorMessage = nil
            ContactsToWatchSync.shared.publish(snapshot)
        } catch {
            contacts = []
            updatedAt = nil
            errorMessage = "Не вдалося прочитати контакти. Доступний ручний пошук."
            ContactsToWatchSync.shared.publishCleared(generation: generationStore.next())
        }
    }
}
