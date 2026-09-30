import SwiftUI

struct WatchProductRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accountStore: AccountSessionStore
    @StateObject private var messages: SecureMessageStore
    @StateObject private var callHistory: CallHistoryStore
    @ObservedObject private var navigation = ProductNavigation.shared
    @State private var routedConversation: SecureConversation?
    @State private var routedAccountID: UUID?
    @State private var showsRoutedConversation = false
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
            ZStack {
                NavigationLink(
                    destination: Group {
                        if let routedConversation, let routedAccountID {
                            ConversationView(store: messages, conversation: routedConversation, accountID: routedAccountID)
                        } else { EmptyView() }
                    },
                    isActive: $showsRoutedConversation,
                    label: { EmptyView() }
                )
                if accountStore.callableAccounts.isEmpty {
                    WatchAccountLinkView(store: accountStore)
                } else {
                    List {
                        if session.state != .idle && !session.state.isTerminal {
                            NavigationLink("Поточний дзвінок") { ActiveCallView(session: session) }
                        }
                        NavigationLink("Чати") { ConversationListView(store: messages, runtime: runtime) }
                        NavigationLink("Дзвінки") {
                            if session.state == .idle || session.state.isTerminal {
                                CallHistoryView(store: callHistory, accountID: accountStore.activeAccountID, runtime: runtime)
                            }
                            else { ActiveCallView(session: session) }
                        }
                        NavigationLink("Контакти") { RecipientSearchView(messageStore: messages, runtime: runtime) }
                        NavigationLink("Набрати номер") { WatchDialEntry(messageStore: messages, runtime: runtime) }
                        NavigationLink("Акаунт") {
                            List {
                                WatchAccountLinkView(store: accountStore)
                                Text("Наскрізне шифрування — для дзвінків між різними користувачами").font(.caption)
                                CallKeyChangeWarningsView(accountID: accountStore.activeAccountID)
                                #if DEBUG
                                NavigationLink("Developer diagnostics") { WatchRootView(session: session) }
                                #endif
                            }
                        }
                    }
                    .navigationTitle("WiFi Secure Call")
                }
            }
        }
        .onAppear { routeIfPossible() }
        .onReceive(navigation.$pendingConversation) { _ in routeIfPossible() }
        .onChange(of: messages.conversations) { _ in routeIfPossible() }
    }

    private func routeIfPossible() {
        guard let route = navigation.pendingConversation,
              route.accountID == messages.activeAccountID,
              let conversation = messages.conversations.first(where: { $0.id == route.conversationID }) else { return }
        routedConversation = conversation
        routedAccountID = route.accountID
        showsRoutedConversation = true
        _ = navigation.consumeConversation()
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
