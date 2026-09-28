import SwiftUI

struct IOSProductRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accountStore: AccountSessionStore
    @StateObject private var messages: SecureMessageStore
    @StateObject private var callHistory: CallHistoryStore
    @ObservedObject private var navigation = ProductNavigation.shared
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
        Group {
        if accountStore.callableAccounts.isEmpty {
            NavigationView { AccountView(store: accountStore).navigationTitle("WiFi Secure Call") }
        } else {
        TabView(selection: Binding(
            get: { navigation.selectedSection },
            set: { navigation.select($0) }
        )) {
            NavigationView { ConversationListView(store: messages) }
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(ProductSection.chats)
            NavigationView {
                Group {
                    if session.state == .idle || session.state.isTerminal {
                        CallHistoryView(store: callHistory, accountID: accountStore.activeAccountID)
                    }
                    else { ActiveCallView(session: session) }
                }
            }
            .tabItem { Label("Calls", systemImage: "phone") }
            .tag(ProductSection.calls)
            NavigationView { RecipientSearchView(messageStore: messages, runtime: runtime) }
                .tabItem { Label("Contacts", systemImage: "person.2") }
                .tag(ProductSection.contacts)
            NavigationView {
                List {
                    AccountView(store: accountStore)
                    NavigationLink("Encryption details") { EncryptionDetailsView(accountID: accountStore.activeAccountID) }
                    #if DEBUG
                    NavigationLink("Developer diagnostics") { IOSRootView(session: session) }
                    #endif
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(ProductSection.settings)
        }
        }
        }
    }
}

private struct EncryptionDetailsView: View {
    let accountID: UUID?

    var body: some View {
        List {
            Label("End-to-end encrypted calls and messages", systemImage: "lock.fill")
            Text("Safety fingerprints are pinned on first authenticated contact. A changed key blocks secure communication until independently reviewed.")
            CallKeyChangeWarningsView(accountID: accountID)
        }
        .navigationTitle("Encryption")
    }
}
