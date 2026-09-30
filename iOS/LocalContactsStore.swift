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
    private var refreshGeneration: UInt64 = 0
    private let fetchQueue = DispatchQueue(label: "com.vkapps.wifisecurecall.contacts", qos: .userInitiated)

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
        refreshGeneration &+= 1
        let operation = refreshGeneration
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        guard hasReadableAuthorization else {
            contacts = []
            updatedAt = nil
            errorMessage = nil
            ContactsToWatchSync.shared.publishCleared(generation: generationStore.next())
            return
        }
        let contactStore = store
        fetchQueue.async { [weak self] in
        do {
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as NSString, CNContactFamilyNameKey as NSString, CNContactPhoneNumbersKey as NSString]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var loaded: [LocalContactEntry] = []
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let numbers = contact.phoneNumbers.enumerated().compactMap { index, labeled -> LocalContactNumber? in
                    let display = labeled.value.stringValue
                    guard let normalized = LocalPhoneNumberNormalizer.normalize(display) else { return nil }
                    return LocalContactNumber(id: "\(contact.identifier):\(index)", displayValue: display, digits: normalized.digits, canonicalE164: normalized.canonicalE164)
                }
                guard !numbers.isEmpty else { return }
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                loaded.append(.init(id: contact.identifier, name: name.isEmpty ? "Без імені" : name, numbers: numbers))
            }
            let sorted = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == operation, self.hasReadableAuthorization else { return }
                self.contacts = sorted
                let snapshot = LocalContactSnapshot(generation: self.generationStore.next(), contacts: sorted)
                self.updatedAt = snapshot.updatedAt; self.errorMessage = nil
                ContactsToWatchSync.shared.publish(snapshot)
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self, self.refreshGeneration == operation else { return }
                self.contacts = []; self.updatedAt = nil
                self.errorMessage = "Не вдалося прочитати контакти. Доступний ручний пошук."
                ContactsToWatchSync.shared.publishCleared(generation: self.generationStore.next())
            }
        }
        }
    }
}
