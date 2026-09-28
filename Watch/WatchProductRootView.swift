import SwiftUI

struct WatchProductRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accountStore: AccountSessionStore
    @StateObject private var messages: SecureMessageStore
    private let runtime: NotificationRuntime

    @MainActor init(session: CallSession, runtime: NotificationRuntime) {
        self.session = session
        self.runtime = runtime
        self.accountStore = runtime.accountStore
        _messages = StateObject(wrappedValue: .shared)
    }

    @MainActor init(session: CallSession) {
        self.init(session: session, runtime: .shared)
    }

    var body: some View {
        NavigationStack {
            if accountStore.callableAccounts.isEmpty {
                WatchAccountLinkView(store: accountStore)
            } else {
            List {
                NavigationLink("Recent calls") {
                    if session.state == .idle { Text("No active call").foregroundStyle(.secondary) }
                    else { ActiveCallView(session: session) }
                }
                NavigationLink("Contacts") { RecipientSearchView(messageStore: messages, runtime: runtime) }
                NavigationLink("Chats") { ConversationListView(store: messages) }
                NavigationLink("Settings") {
                    List {
                        WatchAccountLinkView(store: accountStore)
                        Text("End-to-end encryption").font(.caption)
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
}
