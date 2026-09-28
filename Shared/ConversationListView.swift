import SwiftUI

struct ConversationListView: View {
    @ObservedObject var store: SecureMessageStore

    var body: some View {
        Group {
            if store.conversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle)
                    Text("No chats yet").font(.headline)
                    Text("Find a contact to start an end-to-end encrypted conversation.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding()
            } else {
                List(store.conversations) { conversation in
                    NavigationLink {
                        ConversationView(store: store, conversation: conversation)
                    } label: {
                        Label("Secure conversation", systemImage: "lock.fill")
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .task { await store.refresh() }
        .overlay { if store.state == .loading { ProgressView().accessibilityLabel("Loading secure conversations") } }
    }
}
