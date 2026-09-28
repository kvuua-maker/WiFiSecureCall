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
                        NavigationLink("Recent calls") {
                            if session.state == .idle || session.state.isTerminal {
                                CallHistoryView(store: callHistory, accountID: accountStore.activeAccountID)
                            }
                            else { ActiveCallView(session: session) }
                        }
                        NavigationLink("Contacts") { RecipientSearchView(messageStore: messages, runtime: runtime) }
                        NavigationLink("Chats") { ConversationListView(store: messages) }
                        NavigationLink("Settings") {
                            List {
                                WatchAccountLinkView(store: accountStore)
                                Text("End-to-end encryption").font(.caption)
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
