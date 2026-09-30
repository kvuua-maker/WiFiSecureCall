import SwiftUI

struct ConversationListView: View {
    @ObservedObject var store: SecureMessageStore
    let runtime: NotificationRuntime
    @ObservedObject private var navigation = ProductNavigation.shared
    @State private var query = ""
    @State private var routedConversation: SecureConversation?
    @State private var routedAccountID: UUID?
    @State private var showsRoutedConversation = false

    init(store: SecureMessageStore, runtime: NotificationRuntime) {
        self.store = store
        self.runtime = runtime
    }

    private var filteredConversations: [SecureConversation] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return store.conversations }
        return store.conversations.filter {
            $0.peerDisplayName.localizedCaseInsensitiveContains(value) ||
            ($0.peer?.username.localizedCaseInsensitiveContains(value) ?? false)
        }
    }

    var body: some View {
        Group {
            NavigationLink(
                destination: Group {
                    if let routedConversation, let routedAccountID {
                        ConversationView(store: store, conversation: routedConversation, accountID: routedAccountID)
                    }
                    else { EmptyView() }
                },
                isActive: $showsRoutedConversation,
                label: { EmptyView() }
            )
            if store.conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle)
                    Text("Розмов поки немає").font(.headline)
                    Text("Знайдіть користувача за @іменем або підтвердженим номером.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    NavigationLink("Написати повідомлення") { RecipientSearchView(messageStore: store, runtime: runtime) }
                }.padding()
            } else {
                List(filteredConversations) { conversation in
                    NavigationLink {
                        if let accountID = store.activeAccountID {
                            ConversationView(store: store, conversation: conversation, accountID: accountID)
                        } else {
                            EmptyView()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.peerDisplayName).font(.headline).lineLimit(1)
                            if let accountID = store.activeAccountID,
                               let last = store.messages(conversationID: conversation.id, accountID: accountID).last {
                                Text(last.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text("Відкрити розмову").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(conversation.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Чати")
        .searchable(text: $query, prompt: "Пошук розмов")
        .toolbar { NavigationLink("Новий чат") { RecipientSearchView(messageStore: store, runtime: runtime) } }
        .task { await store.refresh() }
        .onReceive(navigation.$pendingConversation) { _ in routeIfPossible() }
        .onChange(of: store.conversations) { _ in routeIfPossible() }
        .overlay { if store.state == .loading { ProgressView().accessibilityLabel("Loading secure conversations") } }
    }

    private func routeIfPossible() {
        guard let route = navigation.pendingConversation,
              route.accountID == store.activeAccountID,
              let conversation = store.conversations.first(where: { $0.id == route.conversationID }) else { return }
        routedConversation = conversation
        routedAccountID = route.accountID
        showsRoutedConversation = true
        _ = navigation.consumeConversation()
    }
}
