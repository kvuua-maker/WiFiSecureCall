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
            else { ConversationListView(store: messages, runtime: runtime) }
        }
        .overlay(alignment: .top) {
            if session.state != .idle && !session.state.isTerminal {
                NavigationLink("Поточний дзвінок") { ActiveCallView(session: session) }
                    .font(.caption.bold()).buttonStyle(.borderedProminent)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                NavigationLink {
                    WatchMoreView(session: session, accountStore: accountStore, messages: messages, callHistory: callHistory, runtime: runtime)
                } label: { Image(systemName: "line.3.horizontal").accessibilityLabel("Меню") }
            }
        }
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
                    WatchAccountLinkView(store: accountStore)
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
                    ForEach(contact.normalizedNumbers, id: \.self) { number in
                        NavigationLink {
                            RecipientSearchView(messageStore: messageStore, runtime: runtime, initialRecipient: number)
                        } label: {
                            VStack(alignment: .leading) { Text(contact.name).lineLimit(1); Text(number).font(.caption2) }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Пошук")
        .navigationTitle("Контакти")
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
