import SwiftUI

struct RecipientSearchView: View {
    @ObservedObject var messageStore: SecureMessageStore
    let runtime: NotificationRuntime
    @State private var recipient = ""
    @State private var result: ResolvedRecipient?
    @State private var state: ProductLoadingState = .idle
    @State private var selectedAccountID: UUID?

    private var accounts: [AccountSummary] { runtime.accountStore.callableAccounts }

    var body: some View {
        Form {
            if accounts.count > 1 {
                Picker("From account", selection: $selectedAccountID) {
                    ForEach(accounts) { account in Text(account.displayLabel).tag(Optional(account.accountID)) }
                }
            }
            Section("Find a person") {
                TextField("@username or verified phone", text: $recipient)
                    .accessibilityLabel("Recipient search")
                Button("Search") { Task { await resolve() } }
                    .disabled(recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state == .loading)
            }
            if state == .loading { ProgressView("Searching") }
            if case let .failed(message) = state { Text(message).foregroundStyle(.red) }
            if let result {
                Section("Recipient") {
                    Text(result.displayName?.isEmpty == false ? result.displayName! : "@\(result.username)").font(.headline)
                    Text("@\(result.username)").foregroundStyle(.secondary)
                    HStack {
                        Button("Secure call") { Task { await startCall(result) } }
                        Button("Message") { Task { await startMessage(result) } }
                    }
                }
            }
        }
        .navigationTitle("Contacts")
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = accounts.first(where: { $0.accountID == runtime.accountStore.activeAccountID })?.accountID ?? accounts.first?.accountID
            }
        }
        .onChange(of: selectedAccountID) { _ in result = nil; state = .idle }
    }

    private func resolve() async {
        guard let accountID = selectedAccountID ?? runtime.accountStore.activeAccountID else { state = .failed("Sign in to continue"); return }
        state = .loading
        do { result = try await runtime.resolveRecipient(recipient, accountID: accountID); state = .ready }
        catch { result = nil; state = .failed("Recipient is unavailable") }
    }

    private func startCall(_ value: ResolvedRecipient) async {
        guard let accountID = selectedAccountID ?? runtime.accountStore.activeAccountID else { state = .failed("Choose a calling account"); return }
        await runtime.startUserCall(targetUserID: value.userID, accountID: accountID)
    }

    private func startMessage(_ value: ResolvedRecipient) async {
        guard let accountID = selectedAccountID ?? runtime.accountStore.activeAccountID else { state = .failed("Choose a messaging account"); return }
        do { _ = try await messageStore.createConversation(targetUserID: value.userID, accountID: accountID); state = .ready }
        catch { state = .failed("Secure conversation could not be created") }
    }
}
