import SwiftUI

struct IOSProductRootView: View {
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
        Group {
        if accountStore.callableAccounts.isEmpty {
            NavigationView { AccountView(store: accountStore).navigationTitle("WiFi Secure Call") }
        } else {
        TabView {
            NavigationView { ConversationListView(store: messages) }
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            NavigationView {
                Group {
                    if session.state == .idle { VStack(spacing: 8) { Image(systemName: "phone").font(.largeTitle); Text("No active call").font(.headline); Text("Your secure calls will appear here.").foregroundStyle(.secondary) }.padding() }
                    else { ActiveCallView(session: session) }
                }
                .navigationTitle("Calls")
            }
            .tabItem { Label("Calls", systemImage: "phone") }
            NavigationView { RecipientSearchView(messageStore: messages, runtime: runtime) }
                .tabItem { Label("Contacts", systemImage: "person.2") }
            NavigationView {
                List {
                    AccountView(store: accountStore)
                    NavigationLink("Encryption details") { EncryptionDetailsView() }
                    #if DEBUG
                    NavigationLink("Developer diagnostics") { IOSRootView(session: session) }
                    #endif
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
        }
        }
        }
    }
}

private struct EncryptionDetailsView: View {
    var body: some View {
        List {
            Label("End-to-end encrypted calls and messages", systemImage: "lock.fill")
            Text("Safety fingerprints are pinned on first authenticated contact. A changed key blocks secure communication until independently reviewed.")
        }
        .navigationTitle("Encryption")
    }
}
