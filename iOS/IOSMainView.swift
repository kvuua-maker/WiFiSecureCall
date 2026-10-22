import SwiftUI

/// The iPhone app: three tabs, the way a messenger is laid out.
///
/// Chats is the list of people, Calls is the history, Settings is who you are and
/// what is synced. A phone is one tap away from the chat header, which is where a
/// thumb already is.
struct IOSMainView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var accounts = AccountSessionStore.shared
    @ObservedObject private var history = CallHistoryStore.shared
    @ObservedObject private var bridge = WatchCallBridgePhoneObserver.shared
    @State private var selectedTab = 0
    @State private var openChat: ChatContact?

    var body: some View {
        TabView(selection: $selectedTab) {
            chatsTab
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)
            callsTab
                .tabItem { Label("Calls", systemImage: "phone.fill") }
                .tag(1)
            settingsTab
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .tint(IOSTheme.accent)
        .sheet(item: $openChat) { contact in
            IOSChatView(contact: contact, session: session)
        }
        .onAppear {
            history.observe(session)
            DiagnosticsLog.shared.log(.ui, "screen_rendered", .info, details: "main")
        }
    }

    // MARK: - Chats

    private var contacts: [ChatContact] {
        accounts.callableAccounts.map { ChatContact(name: $0.displayLabel.isEmpty ? "Signed in" : $0.displayLabel, accountID: $0.accountID) }
    }

    private var chatsTab: some View {
        NavigationView {
            ZStack {
                IOSTheme.background.ignoresSafeArea()
                if contacts.isEmpty {
                    emptyChats
                } else {
                    List {
                        ForEach(contacts) { contact in
                            Button {
                                DiagnosticsLog.shared.log(.ui, "button_tapped", .info, details: "chat.open")
                                openChat = contact
                            } label: {
                                chatRow(contact)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(IOSTheme.background)
                            .listRowSeparatorTint(Color.white.opacity(0.06))
                        }
                    }
                    .listStyle(.plain)
                    
                }
            }
            .navigationTitle("Chats")
        }
    }

    private func chatRow(_ contact: ChatContact) -> some View {
        HStack(spacing: 12) {
            IOSAvatar(name: contact.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("Voice call over Wi-Fi")
                    .font(.system(size: 13))
                    .foregroundColor(IOSTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.time(history.records.first?.date ?? Date()))
                    .font(.system(size: 12))
                    .foregroundColor(IOSTheme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(IOSTheme.textSecondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var emptyChats: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundColor(IOSTheme.textSecondary)
            Text("No chats yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text("Sign in to see the people you can call")
                .font(.system(size: 14))
                .foregroundColor(IOSTheme.textSecondary)
        }
    }

    // MARK: - Calls

    private var callsTab: some View {
        NavigationView {
            ZStack {
                IOSTheme.background.ignoresSafeArea()
                if history.records.isEmpty {
                    Text("No calls yet")
                        .font(.system(size: 15))
                        .foregroundColor(IOSTheme.textSecondary)
                } else {
                    List {
                        ForEach(history.records) { record in
                            HStack(spacing: 12) {
                                Image(systemName: record.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(color(for: record.kind))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.name)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(Self.time(record.date))
                                        .font(.system(size: 12))
                                        .foregroundColor(IOSTheme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                if record.duration > 0 {
                                    Text(IOSTheme.format(record.duration))
                                        .font(.system(size: 13).monospacedDigit())
                                        .foregroundColor(IOSTheme.textSecondary)
                                }
                            }
                            .listRowBackground(IOSTheme.background)
                            .listRowSeparatorTint(Color.white.opacity(0.06))
                        }
                    }
                    .listStyle(.plain)
                    
                }
            }
            .navigationTitle("Calls")
        }
    }

    private func color(for kind: CallRecord.Kind) -> Color {
        switch kind {
        case .outgoing: return IOSTheme.success
        case .incoming: return IOSTheme.accent
        case .missed, .failed: return IOSTheme.destructive
        }
    }

    // MARK: - Settings

    private var settingsTab: some View {
        NavigationView {
            ZStack {
                IOSTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 14) {
                        profileCard
                        statusCard
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            IOSAvatar(name: accounts.activeAccount?.displayLabel ?? "Guest", size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(accounts.activeAccount?.displayLabel ?? "Not signed in")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                Text(accounts.activeAccount?.phoneNumber ?? "Sign in with Apple to call")
                    .font(.system(size: 13))
                    .foregroundColor(IOSTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: IOSTheme.corner).fill(IOSTheme.surface))
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            settingRow("Sign in with Apple", accounts.activeAccount == nil ? "Not signed in" : "Signed in")
            Divider().background(Color.white.opacity(0.08))
            settingRow("Watch sync", bridge.syncedAccounts.isEmpty ? "Waiting" : "\(bridge.syncedAccounts.count) account(s)")
            Divider().background(Color.white.opacity(0.08))
            settingRow("Build", Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        }
        .background(RoundedRectangle(cornerRadius: IOSTheme.corner).fill(IOSTheme.surface))
    }

    private func settingRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundColor(.white)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 14)).foregroundColor(IOSTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM"
        return formatter.string(from: date)
    }
}

/// A person the app can talk to.
struct ChatContact: Identifiable, Hashable {
    let name: String
    let accountID: UUID
    var id: UUID { accountID }
}

/// Mirrors the account list the phone publishes to the watch, for the Settings row.
@MainActor
final class WatchCallBridgePhoneObserver: ObservableObject {
    static let shared = WatchCallBridgePhoneObserver()
    @Published private(set) var syncedAccounts: [String] = []
    private init() {
        Task { @MainActor in
            while !Task.isCancelled {
                let labels = AccountSessionStore.shared.accounts.map { $0.displayLabel.isEmpty ? "Account" : $0.displayLabel }
                if labels != self.syncedAccounts { self.syncedAccounts = labels }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
