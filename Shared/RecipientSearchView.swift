import SwiftUI

struct RecipientSearchOperation: Equatable {
    let accountID: UUID
    fileprivate let generation: UInt64
}

struct RecipientSearchOperationGate {
    private(set) var generation: UInt64 = 0

    mutating func begin(accountID: UUID) -> RecipientSearchOperation {
        generation &+= 1
        return RecipientSearchOperation(accountID: accountID, generation: generation)
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ operation: RecipientSearchOperation, selectedAccountID: UUID?) -> Bool {
        operation.generation == generation && operation.accountID == selectedAccountID
    }
}

struct RecipientSearchView: View {
    @ObservedObject var messageStore: SecureMessageStore
    let runtime: NotificationRuntime
    @State private var recipient = ""
    @State private var result: ResolvedRecipient?
    @State private var state: ProductLoadingState = .idle
    @State private var selectedAccountID: UUID?
    @State private var createdConversation: SecureConversation?
    @State private var createdConversationAccountID: UUID?
    @State private var showCreatedConversation = false
    @State private var operationGate = RecipientSearchOperationGate()

    private var accounts: [AccountSummary] { runtime.accountStore.callableAccounts }

    var body: some View {
        Form {
            NavigationLink(
                destination: Group {
                    if let createdConversation, let createdConversationAccountID {
                        ConversationView(store: messageStore, conversation: createdConversation, accountID: createdConversationAccountID)
                    }
                    else { EmptyView() }
                },
                isActive: $showCreatedConversation,
                label: { EmptyView() }
            )
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
                            .disabled(state == .loading)
                        Button("Message") { Task { await startMessage(result) } }
                            .disabled(state == .loading)
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
        .onChange(of: selectedAccountID) { _ in
            operationGate.invalidate()
            result = nil
            state = .idle
        }
        .onChange(of: recipient) { _ in
            operationGate.invalidate()
            result = nil
            state = .idle
        }
    }

    private func resolve() async {
        guard let accountID = currentAccountID else { state = .failed("Sign in to continue"); return }
        let operation = operationGate.begin(accountID: accountID)
        let query = recipient
        state = .loading
        do {
            let resolved = try await runtime.resolveRecipient(query, accountID: accountID)
            guard operationGate.accepts(operation, selectedAccountID: currentAccountID) else { return }
            result = resolved
            state = .ready
        }
        catch {
            guard operationGate.accepts(operation, selectedAccountID: currentAccountID) else { return }
            result = nil
            state = .failed("Recipient is unavailable")
        }
    }

    private func startCall(_ value: ResolvedRecipient) async {
        guard let accountID = selectedAccountID ?? runtime.accountStore.activeAccountID else { state = .failed("Choose a calling account"); return }
        let peer = value.displayName?.isEmpty == false ? "\(value.displayName!) (@\(value.username))" : "@\(value.username)"
        await runtime.startUserCall(targetUserID: value.userID, accountID: accountID, peerDisplayName: peer)
    }

    private func startMessage(_ value: ResolvedRecipient) async {
        guard state != .loading else { return }
        guard let accountID = currentAccountID else { state = .failed("Choose a messaging account"); return }
        let operation = operationGate.begin(accountID: accountID)
        state = .loading
        do {
            let conversation = try await messageStore.createConversation(targetUserID: value.userID, accountID: accountID)
            guard operationGate.accepts(operation, selectedAccountID: currentAccountID) else { return }
            // The explicit "From account" choice remains the conversation's
            // active identity when the destination is presented.
            runtime.accountStore.switchAccount(to: accountID)
            createdConversation = conversation
            createdConversationAccountID = accountID
            showCreatedConversation = true
            state = .ready
        }
        catch {
            guard operationGate.accepts(operation, selectedAccountID: currentAccountID) else { return }
            state = .failed("Secure conversation could not be created")
        }
    }

    private var currentAccountID: UUID? {
        let candidate = selectedAccountID ?? runtime.accountStore.activeAccountID
        guard let candidate, accounts.contains(where: { $0.accountID == candidate }) else { return nil }
        return candidate
    }
}
