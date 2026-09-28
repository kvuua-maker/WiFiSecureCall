import SwiftUI

struct ConversationListView: View {
    @ObservedObject var store: SecureMessageStore
    @ObservedObject private var navigation = ProductNavigation.shared
    @State private var routedConversation: SecureConversation?
    @State private var routedAccountID: UUID?
    @State private var showsRoutedConversation = false

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
                    Text("No chats yet").font(.headline)
                    Text("Find a contact to start an end-to-end encrypted conversation.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding()
            } else {
                List(store.conversations) { conversation in
                    NavigationLink {
                        if let accountID = store.activeAccountID {
                            ConversationView(store: store, conversation: conversation, accountID: accountID)
                        } else {
                            EmptyView()
                        }
                    } label: {
                        Label("Secure conversation", systemImage: "lock.fill")
                    }
                }
            }
        }
        .navigationTitle("Chats")
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
