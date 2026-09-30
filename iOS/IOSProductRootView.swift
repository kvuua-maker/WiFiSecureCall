import SwiftUI
import Contacts
import UIKit

struct IOSProductRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accountStore: AccountSessionStore
    @StateObject private var messages: SecureMessageStore
    @StateObject private var callHistory: CallHistoryStore
    @ObservedObject private var navigation = ProductNavigation.shared
    private let runtime: NotificationRuntime

    @MainActor init(session: CallSession, runtime: NotificationRuntime) {
        self.session = session
        self.runtime = runtime
        self.accountStore = runtime.accountStore
        _messages = StateObject(wrappedValue: .shared)
        _callHistory = StateObject(wrappedValue: .shared)
    }

    @MainActor init(session: CallSession) {
        self.init(session: session, runtime: .shared)
    }

    var body: some View {
        Group {
        if accountStore.callableAccounts.isEmpty {
            NavigationView { AccountView(store: accountStore).navigationTitle("WiFi Secure Call") }
        } else {
        TabView(selection: Binding(
            get: { navigation.selectedSection },
            set: { navigation.select($0) }
        )) {
            NavigationView { ConversationListView(store: messages, runtime: runtime) }
                .tabItem { Label("Чати", systemImage: "bubble.left.and.bubble.right") }
                .tag(ProductSection.chats)
            NavigationView {
                Group {
                    if session.state == .idle || session.state.isTerminal {
                        CallHistoryView(store: callHistory, accountID: accountStore.activeAccountID, runtime: runtime)
                    }
                    else { ActiveCallView(session: session) }
                }
            }
            .tabItem { Label("Дзвінки", systemImage: "phone") }
            .tag(ProductSection.calls)
            NavigationView { IOSContactsView(messageStore: messages, runtime: runtime) }
                .tabItem { Label("Контакти", systemImage: "person.2") }
                .tag(ProductSection.contacts)
            NavigationView {
                AccountView(store: accountStore)
                    .toolbar {
                        NavigationLink("Шифрування") { EncryptionDetailsView(accountID: accountStore.activeAccountID) }
                    #if DEBUG
                        NavigationLink("Developer diagnostics") { IOSRootView(session: session) }
                    #endif
                    }
            }
            .tabItem { Label("Налаштування", systemImage: "gear") }
            .tag(ProductSection.settings)
        }
        .safeAreaInset(edge: .top) {
            if session.state != .idle && !session.state.isTerminal && navigation.selectedSection != .calls {
                Button("Повернутися до дзвінка") { navigation.select(.calls) }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.thinMaterial)
            }
        }
        }
        }
    }
}

private struct IOSContactsView: View {
    @ObservedObject var messageStore: SecureMessageStore
    let runtime: NotificationRuntime
    @State private var status = CNContactStore.authorizationStatus(for: .contacts)
    @State private var contacts: [LocalPhoneContact] = []
    @State private var query = ""
    @State private var loadError: String?
    private let contactStore = CNContactStore()

    private var visibleContacts: [LocalPhoneContact] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return contacts }
        return contacts.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.number.contains(term) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink("Пошук за @іменем або номером") {
                    RecipientSearchView(messageStore: messageStore, runtime: runtime)
                }
            }
            if status == .notDetermined {
                Section {
                    Text("Дозвольте доступ, щоб знайти людину у своїй телефонній книзі. Контакти не надсилаються списком на сервер.")
                    Button("Показати контакти iPhone") { requestContacts() }
                }
            } else if status == .denied || status == .restricted {
                Section {
                    Text("Доступ до контактів вимкнено. Ручний пошук залишається доступним.")
                    Button("Відкрити налаштування доступу") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } else {
                if let loadError { Text(loadError).foregroundStyle(.red) }
                if contacts.isEmpty { Text("Контактів із номером немає. Скористайтеся ручним пошуком.") }
                ForEach(visibleContacts) { contact in
                    NavigationLink {
                        RecipientSearchView(messageStore: messageStore, runtime: runtime, initialRecipient: contact.number)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(contact.name).font(.headline)
                            Text(contact.number).font(.caption).foregroundStyle(.secondary)
                            Text("Статус у сервісі невідомий — перевірити").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Контакти")
        .searchable(text: $query, prompt: "Ім’я або номер")
        .onAppear {
            status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .authorized { loadContacts() }
        }
    }

    private func requestContacts() {
        contactStore.requestAccess(for: .contacts) { granted, _ in
            Task { @MainActor in
                status = granted ? .authorized : .denied
                if granted { loadContacts() }
            }
        }
    }

    private func loadContacts() {
        do {
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as NSString, CNContactFamilyNameKey as NSString, CNContactPhoneNumbersKey as NSString]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var loaded: [LocalPhoneContact] = []
            try contactStore.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for phone in contact.phoneNumbers {
                    loaded.append(LocalPhoneContact(id: "\(contact.identifier):\(phone.identifier)", name: name.isEmpty ? "Без імені" : name, number: phone.value.stringValue))
                }
            }
            contacts = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadError = nil
        } catch {
            contacts = []
            loadError = "Не вдалося прочитати контакти. Доступний ручний пошук."
        }
    }
}

private struct LocalPhoneContact: Identifiable {
    let id: String
    let name: String
    let number: String
}

private struct EncryptionDetailsView: View {
    let accountID: UUID?

    var body: some View {
        List {
            Label("Наскрізне шифрування між різними користувачами", systemImage: "lock.fill")
            Text("Дзвінки між власними зв’язаними пристроями зараз використовують інший протокол і не позначаються як E2EE. Зміна ключа блокує захищений зв’язок до підтвердження.")
            CallKeyChangeWarningsView(accountID: accountID)
        }
        .navigationTitle("Шифрування")
    }
}
