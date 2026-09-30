import SwiftUI
import Contacts

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
    @StateObject private var contactsStore = LocalContactsStore.shared
    @State private var query = ""

    private var visibleContacts: [LocalContactEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return contactsStore.contacts }
        return contactsStore.contacts.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.normalizedNumbers.contains(where: { $0.contains(term) }) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink("Пошук за @іменем або номером") {
                    RecipientSearchView(messageStore: messageStore, runtime: runtime)
                }
            }
            if contactsStore.authorizationStatus == .notDetermined {
                Section {
                    Text("Дозвольте доступ, щоб знайти людину у своїй телефонній книзі. Контакти не надсилаються списком на сервер.")
                    Button("Показати контакти iPhone") { contactsStore.requestAccess() }
                }
            } else if contactsStore.authorizationStatus == .denied || contactsStore.authorizationStatus == .restricted {
                Section {
                    Text("Доступ до контактів вимкнено. Ручний пошук залишається доступним.")
                    Button("Відкрити налаштування доступу") { contactsStore.openSystemSettings() }
                }
            } else {
                if #available(iOS 18.0, *), contactsStore.authorizationStatus == .limited {
                    Section {
                        Text("Показано лише вибрані контакти.")
                        Button("Додати доступ до контактів") { contactsStore.openSystemSettings() }
                    }
                }
                if let loadError = contactsStore.errorMessage { Text(loadError).foregroundStyle(.red) }
                if contactsStore.contacts.isEmpty { Text("Контактів із міжнародним номером немає. Скористайтеся ручним пошуком.") }
                ForEach(visibleContacts) { contact in
                    ForEach(contact.normalizedNumbers, id: \.self) { number in
                        NavigationLink {
                            RecipientSearchView(messageStore: messageStore, runtime: runtime, initialRecipient: number)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(contact.name).font(.headline)
                                Text(number).font(.caption).foregroundStyle(.secondary)
                                Text("Статус у сервісі невідомий — перевірити").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Контакти")
        .searchable(text: $query, prompt: "Ім’я або номер")
        .onAppear { contactsStore.refreshAuthorizationAndContacts() }
    }
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
