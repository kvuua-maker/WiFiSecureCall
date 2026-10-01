import SwiftUI

struct WatchProductRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accountStore: AccountSessionStore
    @StateObject private var messages: SecureMessageStore
    @StateObject private var callHistory: CallHistoryStore
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
        NavigationStack {
            if accountStore.callableAccounts.isEmpty { WatchAccountLinkView(store: accountStore) }
            else { WatchChatsHomeView(session: session, accountStore: accountStore, messages: messages, callHistory: callHistory, runtime: runtime) }
        }
    }
}

private struct WatchChatsHomeView: View {
    @ObservedObject var session: CallSession
    @ObservedObject var accountStore: AccountSessionStore
    @ObservedObject var messages: SecureMessageStore
    @ObservedObject var callHistory: CallHistoryStore
    let runtime: NotificationRuntime
    @State private var query = ""
    @State private var showsSearch = false
    @State private var showsAccounts = false
    @State private var accountSwitchWarning = false

    private var visible: [SecureConversation] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return messages.conversations }
        return messages.conversations.filter {
            $0.peerDisplayName.localizedCaseInsensitiveContains(term) ||
            ($0.peer?.username.localizedCaseInsensitiveContains(term) ?? false)
        }
    }

    private var loadError: String? {
        if case .failed(let message) = messages.state { return message }
        return nil
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 5) {
                VStack(spacing: 4) {
                    HStack {
                        Text(accountStore.activeAccount?.displayLabel ?? "WiFi Secure Call")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Button {
                            if session.state == .idle || session.state.isTerminal { showsAccounts = true }
                            else { accountSwitchWarning = true }
                        } label: { Label("Акаунт", systemImage: "chevron.right").labelStyle(.titleAndIcon) }
                            .font(.caption2).buttonStyle(.plain)
                    }
                    NavigationLink { CallHistoryView(store: callHistory, accountID: accountStore.activeAccountID, runtime: runtime) } label: { Label("Дзвінки", systemImage: "phone") }
                    NavigationLink { WatchContactsView(messageStore: messages, runtime: runtime) } label: { Label("Контакти", systemImage: "person.2") }
                    HStack {
                        NavigationLink { RecipientSearchView(messageStore: messages, runtime: runtime) } label: { Label("Новий чат", systemImage: "square.and.pencil") }
                        Button { showsSearch.toggle(); if !showsSearch { query = "" } } label: { Image(systemName: "magnifyingglass").accessibilityLabel("Пошук чатів") }
                    }
                    .font(.caption)
                }
                if showsSearch { TextField("Пошук", text: $query).textInputAutocapitalization(.never) }
                if messages.state == .loading { ProgressView().accessibilityLabel("Завантаження чатів") }
                else if loadError != nil {
                    Text("Не вдалося завантажити чати").font(.caption)
                    Button("Повторити") { Task { await messages.refresh() } }.font(.caption)
                } else if visible.isEmpty {
                    Text(query.isEmpty ? "Розмов поки немає" : "Нічого не знайдено").font(.caption).foregroundStyle(.secondary)
                    if query.isEmpty { NavigationLink("Новий чат") { RecipientSearchView(messageStore: messages, runtime: runtime) }.font(.caption) }
                } else {
                    ForEach(visible) { conversation in
                        if let accountID = messages.activeAccountID {
                            NavigationLink { WatchConversationView(store: messages, conversation: conversation, accountID: accountID, runtime: runtime) } label: { row(conversation, accountID: accountID) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("Чати")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NavigationLink { WatchMoreView(session: session, accountStore: accountStore, messages: messages, callHistory: callHistory, runtime: runtime) } label: { Image(systemName: "ellipsis").accessibilityLabel("Інші дії") } }
        }
        .safeAreaInset(edge: .bottom) {
            if session.state != .idle && !session.state.isTerminal {
                NavigationLink("Поточний дзвінок") { ActiveCallView(session: session) }
                    .font(.caption.bold()).buttonStyle(.borderedProminent)
            }
        }
        .task(id: messages.activeAccountID) { await messages.refresh() }
        .sheet(isPresented: $showsAccounts) {
            WatchAccountSwitcher(store: accountStore, isPresented: $showsAccounts, canSwitchAccounts: { session.state == .idle || session.state.isTerminal })
        }
        .alert("Завершіть поточний виклик перед перемиканням акаунта.", isPresented: $accountSwitchWarning) { Button("Гаразд", role: .cancel) {} }
    }

    private func row(_ conversation: SecureConversation, accountID: UUID) -> some View {
        HStack(spacing: 6) {
            Text(String(conversation.peerDisplayName.prefix(1)).uppercased())
                .font(.caption.bold()).frame(width: 30, height: 30).background(Circle().fill(.blue.opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.peerDisplayName).font(.caption.bold()).lineLimit(1).truncationMode(.tail)
                Text(messages.messages(conversationID: conversation.id, accountID: accountID).last?.text ?? "Відкрити розмову")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 2)
            Text(conversation.updatedAt, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

private struct WatchAccountSwitcher: View {
    @ObservedObject var store: AccountSessionStore
    @Binding var isPresented: Bool
    let canSwitchAccounts: () -> Bool
    @State private var errorMessage: String?
    @State private var showsAccountLink = false
    @State private var accountLinkTarget: UUID?

    private var orphaned: [AccountSummary] {
        store.accounts.filter { account in !store.callableAccounts.contains(where: { $0.accountID == account.accountID }) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.callableAccounts) { account in
                    Button {
                        switch attemptWatchAccountSwitch(store: store, accountID: account.accountID, canSwitchAccounts: canSwitchAccounts()) {
                        case .switched: isPresented = false
                        case .blockedByActiveCall: errorMessage = "Завершіть виклик перед перемиканням акаунта."
                        case .missingSession: errorMessage = "Потрібне повторне зв’язування цього акаунта."
                        case .unknownAccount: errorMessage = "Акаунт більше недоступний. Оновіть список."
                        }
                    } label: {
                        HStack {
                            Text(account.displayLabel).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            if account.accountID == store.activeAccountID { Image(systemName: "checkmark") }
                        }
                    }
                }
                if !orphaned.isEmpty {
                    Section("Потрібне повторне зв’язування") {
                        ForEach(orphaned) { account in
                            Button {
                                guard canSwitchAccounts() else { errorMessage = "Завершіть виклик перед повторним зв’язуванням."; return }
                                accountLinkTarget = account.accountID
                                showsAccountLink = true
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(account.displayLabel).lineLimit(1)
                                    Text("Відновити або вилучити запис").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Button("Додати акаунт") {
                    guard canSwitchAccounts() else { errorMessage = "Завершіть виклик перед додаванням акаунта."; return }
                    accountLinkTarget = nil
                    showsAccountLink = true
                }
            }
            .navigationTitle("Акаунти")
            .navigationDestination(isPresented: $showsAccountLink) {
                WatchAccountLinkView(store: store, expectedAccountID: accountLinkTarget, canSwitchAccounts: canSwitchAccounts)
            }
            .alert("Не вдалося змінити акаунт", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Гаразд", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct WatchConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SecureMessageStore
    let conversation: SecureConversation
    let accountID: UUID
    let runtime: NotificationRuntime
    @State private var draft = ""
    @State private var sending = false
    @State private var safeError: String?
    @State private var loadingOlder = false
    @State private var paginationMutation = false
    @State private var isNearBottom = true
    @State private var scrollAfterSend = false

    private var blocked: Bool {
        !store.keyChangeWarnings(conversationID: conversation.id, accountID: accountID).isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 5) {
                        if store.hasOlderMessages(conversationID: conversation.id, accountID: accountID) {
                            Button(loadingOlder ? "Завантаження…" : "Раніші повідомлення") {
                                guard !loadingOlder, store.activeAccountID == accountID else { return }
                                let anchor = store.messages(conversationID: conversation.id, accountID: accountID).first?.id
                                loadingOlder = true
                                paginationMutation = true
                                Task {
                                    _ = await store.loadMessages(conversationID: conversation.id, accountID: accountID, append: true, reportsLoading: false)
                                    guard store.activeAccountID == accountID else { loadingOlder = false; dismiss(); return }
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                    await Task.yield()
                                    guard store.activeAccountID == accountID else { loadingOlder = false; dismiss(); return }
                                    loadingOlder = false
                                    paginationMutation = false
                                }
                            }
                            .disabled(loadingOlder)
                            .font(.caption2)
                        }
                        ForEach(store.messages(conversationID: conversation.id, accountID: accountID)) { message in
                            HStack {
                                if message.isSentByCurrentUser { Spacer(minLength: 16) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    Text(message.createdAt, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                .padding(6)
                                .background(message.isSentByCurrentUser ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                                if !message.isSentByCurrentUser { Spacer(minLength: 16) }
                            }
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                            .onAppear { if !paginationMutation { isNearBottom = true } }
                            .onDisappear { if !paginationMutation { isNearBottom = false } }
                    }
                }
                .onChange(of: store.messages(conversationID: conversation.id, accountID: accountID).count) { _ in
                    guard !paginationMutation, !loadingOlder else { return }
                    guard isNearBottom || scrollAfterSend else { return }
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    scrollAfterSend = false
                }
            }
            if blocked {
                Text("Ключ безпеки змінився. Підтвердьте його на iPhone.").font(.caption2).foregroundStyle(.red)
            }
            if let safeError { Text(safeError).font(.caption2).foregroundStyle(.red) }
            HStack(spacing: 4) {
                TextField("Повідомлення", text: $draft)
                Button {
                    let text = draft
                    sending = true
                    scrollAfterSend = true
                    Task {
                        guard store.activeAccountID == accountID else { safeError = "Акаунт змінено. Поверніться до списку чатів."; scrollAfterSend = false; sending = false; return }
                        do { try await store.send(text: text, conversation: conversation, accountID: accountID); guard store.activeAccountID == accountID else { scrollAfterSend = false; sending = false; dismiss(); return }; if draft == text { draft = "" }; safeError = nil }
                        catch { scrollAfterSend = false; safeError = SecureMessageStore.safeError(error) }
                        sending = false
                    }
                } label: { Image(systemName: "arrow.up.circle.fill").accessibilityLabel("Надіслати") }
                    .disabled(blocked || sending || store.activeAccountID != accountID || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(conversation.peerDisplayName)
        .toolbar {
            if let peer = conversation.peer {
                Button {
                    guard store.activeAccountID == accountID else { safeError = "Акаунт змінено. Поверніться до списку чатів."; return }
                    Task { await runtime.startUserCall(targetUserID: peer.userID, accountID: accountID, peerDisplayName: conversation.peerDisplayName) }
                } label: { Image(systemName: "phone").accessibilityLabel("Захищений дзвінок") }
                    .disabled(blocked)
            }
        }
        .task {
            guard store.activeAccountID == accountID else { dismiss(); return }
            await store.prepareSafety(conversation: conversation, accountID: accountID)
            guard store.activeAccountID == accountID else { dismiss(); return }
            await store.loadMessages(conversationID: conversation.id, accountID: accountID)
            guard store.activeAccountID == accountID else { dismiss(); return }
            await store.markRead(conversationID: conversation.id, accountID: accountID)
        }
        .onChange(of: store.activeAccountID) { value in if value != accountID { dismiss() } }
    }
}

private struct WatchMoreView: View {
    @ObservedObject var session: CallSession
    @ObservedObject var accountStore: AccountSessionStore
    @ObservedObject var messages: SecureMessageStore
    @ObservedObject var callHistory: CallHistoryStore
    let runtime: NotificationRuntime

    var body: some View {
        List {
            NavigationLink("Дзвінки") {
                if session.state == .idle || session.state.isTerminal { CallHistoryView(store: callHistory, accountID: accountStore.activeAccountID, runtime: runtime) }
                else { ActiveCallView(session: session) }
            }
            NavigationLink("Контакти") { WatchContactsView(messageStore: messages, runtime: runtime) }
            NavigationLink("Набрати номер") { WatchDialEntry(messageStore: messages, runtime: runtime) }
            NavigationLink("Акаунт і безпека") {
                List {
                    WatchAccountLinkView(store: accountStore, canSwitchAccounts: { session.state == .idle || session.state.isTerminal })
                    CallKeyChangeWarningsView(accountID: accountStore.activeAccountID)
                    #if DEBUG
                    NavigationLink("Developer diagnostics") { WatchRootView(session: session) }
                    #endif
                }
            }
        }
        .navigationTitle("Меню")
    }
}

private struct WatchContactsView: View {
    @ObservedObject private var cache = WatchContactsCache.shared
    @ObservedObject var messageStore: SecureMessageStore
    let runtime: NotificationRuntime
    @State private var query = ""

    private var visible: [LocalContactEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return cache.contacts }
        return cache.contacts.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.normalizedNumbers.contains(where: { $0.contains(term) }) }
    }

    var body: some View {
        List {
            NavigationLink("Ручний пошук") { RecipientSearchView(messageStore: messageStore, runtime: runtime) }
            if cache.contacts.isEmpty {
                if cache.generation == 0 {
                    Text("Контакти ще не синхронізовано. Ручний пошук працює через мережу годинника.").font(.caption)
                } else {
                    Text("Синхронізовані контакти очищено. Ручний пошук працює через мережу годинника.").font(.caption)
                }
            } else {
                if let updatedAt = cache.updatedAt { Text("Оновлено \(updatedAt, style: .relative)").font(.caption2) }
                ForEach(visible) { contact in
                    ForEach(contact.numbers) { number in
                        NavigationLink {
                            if let canonical = number.canonicalE164 {
                                RecipientSearchView(messageStore: messageStore, runtime: runtime, initialRecipient: canonical)
                            } else {
                                WatchCountryPrefixConfirmation(number: number, messageStore: messageStore, runtime: runtime)
                            }
                        } label: {
                            VStack(alignment: .leading) { Text(contact.name).lineLimit(1); Text(number.displayValue).font(.caption2) }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Пошук")
        .navigationTitle("Контакти")
    }
}

private struct WatchCountryPrefixConfirmation: View {
    let number: LocalContactNumber
    @ObservedObject var messageStore: SecureMessageStore
    let runtime: NotificationRuntime
    @State private var internationalNumber = "+"

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(number.displayValue).font(.headline).minimumScaleFactor(0.7)
                Text("Введіть повний міжнародний номер. Код країни не визначається автоматично.").font(.caption2)
                TextField("+код і номер", text: $internationalNumber)
                NavigationLink("Перевірити") {
                    RecipientSearchView(messageStore: messageStore, runtime: runtime, initialRecipient: normalized ?? "")
                }
                .disabled(normalized == nil)
            }
        }
        .navigationTitle("Номер")
    }

    private var normalized: String? {
        let value = RecipientQueryNormalization.normalize(internationalNumber)
        guard value.hasPrefix("+"), value.dropFirst().allSatisfy(\.isNumber), value.count >= 8 else { return nil }
        return value
    }
}

private struct WatchDialEntry: View {
    @ObservedObject var messageStore: SecureMessageStore
    let runtime: NotificationRuntime
    @State private var number = "+"
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "0", "⌫"]

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text(number).font(.headline.monospacedDigit()).lineLimit(2).minimumScaleFactor(0.7)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(keys, id: \.self) { key in
                        Button(key) {
                            if key == "⌫" { if !number.isEmpty { number.removeLast() } }
                            else if key == "+" { if number.isEmpty { number = "+" } }
                            else if number.count < 16 { number += key }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(key == "⌫" ? "Видалити" : key)
                    }
                }
                NavigationLink("Знайти користувача") {
                    RecipientSearchView(messageStore: messageStore, runtime: runtime, initialRecipient: number)
                }
                .disabled(number.count < 3 || !number.hasPrefix("+"))
                Text("Перед дзвінком номер перевіряється у сервісі.").font(.caption2)
            }
        }
        .navigationTitle("Номер")
    }
}
