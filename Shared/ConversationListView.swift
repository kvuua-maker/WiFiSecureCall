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
            if store.conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle)
                    Text("Розмов поки немає").font(.headline)
                    Text("Знайдіть користувача за @іменем або підтвердженим номером.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    NavigationLink("Написати повідомлення") { RecipientSearchView(messageStore: store, runtime: runtime) }
                }.padding()
            } else {
                #if os(watchOS)
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 5) {
                        ForEach(filteredConversations) { conversation in
                            NavigationLink {
                                if let accountID = store.activeAccountID { ConversationView(store: store, conversation: conversation, accountID: accountID) }
                            } label: { compactWatchRow(conversation) }
                            .buttonStyle(.plain)
                        }
                    }
                }
                #else
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
                #endif
            }
        }
        .navigationTitle("Чати")
        .searchable(text: $query, prompt: "Пошук розмов")
        .toolbar {
            NavigationLink { RecipientSearchView(messageStore: store, runtime: runtime) } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("Новий чат")
        }
        .task(id: store.activeAccountID) { await store.refresh() }
        .onReceive(navigation.$pendingConversation) { _ in routeIfPossible() }
        .onChange(of: store.conversations) { _ in routeIfPossible() }
        .overlay { if store.state == .loading { ProgressView().accessibilityLabel("Loading secure conversations") } }
        .sheet(isPresented: $showsRoutedConversation) {
            if let routedConversation, let routedAccountID {
                NavigationView { ConversationView(store: store, conversation: routedConversation, accountID: routedAccountID) }
            }
        }
    }

    #if os(watchOS)
    private func compactWatchRow(_ conversation: SecureConversation) -> some View {
        HStack(spacing: 6) {
            Text(String(conversation.peerDisplayName.prefix(1)).uppercased())
                .font(.caption.bold()).frame(width: 30, height: 30).background(Circle().fill(.blue.opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.peerDisplayName).font(.caption.bold()).lineLimit(1)
                if let accountID = store.activeAccountID, let last = store.messages(conversationID: conversation.id, accountID: accountID).last {
                    Text(last.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else { Text("Відкрити розмову").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 2)
            Text(conversation.updatedAt, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
    #endif

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
