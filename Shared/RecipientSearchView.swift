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

enum RecipientQueryNormalization {
    static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("+") else { return trimmed }
        let digits = trimmed.dropFirst().filter { $0.isNumber }
        guard !digits.isEmpty,
              trimmed.dropFirst().allSatisfy({ $0.isNumber || " -().".contains($0) }) else { return trimmed }
        return "+" + digits
    }
}

struct RecipientSearchView: View {
    @ObservedObject var messageStore: SecureMessageStore
    let runtime: NotificationRuntime
    @State private var recipient: String
    @State private var result: ResolvedRecipient?
    @State private var state: ProductLoadingState = .idle
    @State private var selectedAccountID: UUID?
    @State private var createdConversation: SecureConversation?
    @State private var createdConversationAccountID: UUID?
    @State private var showCreatedConversation = false
    @State private var operationGate = RecipientSearchOperationGate()

    private var accounts: [AccountSummary] { runtime.accountStore.callableAccounts }

    init(messageStore: SecureMessageStore, runtime: NotificationRuntime, initialRecipient: String = "") {
        self.messageStore = messageStore
        self.runtime = runtime
        _recipient = State(initialValue: initialRecipient)
    }

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
                Picker("Від акаунта", selection: $selectedAccountID) {
                    ForEach(accounts) { account in Text(account.displayLabel).tag(Optional(account.accountID)) }
                }
            }
            Section("Знайти користувача") {
                TextField("@ім’я або підтверджений номер", text: $recipient)
                    .accessibilityLabel("Recipient search")
                Button("Знайти") { Task { await resolve() } }
                    .disabled(recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state == .loading)
            }
            if state == .loading { ProgressView("Пошук") }
            if case let .failed(message) = state { Text(message).foregroundStyle(.red) }
            if let result {
                Section("Користувач у сервісі") {
                    Text(result.displayName?.isEmpty == false ? result.displayName! : "@\(result.username)").font(.headline)
                    Text("@\(result.username)").foregroundStyle(.secondary)
                    HStack {
                        Button("Захищений дзвінок") { Task { await startCall(result) } }
                            .disabled(state == .loading)
                        Button("Повідомлення") { Task { await startMessage(result) } }
                            .disabled(state == .loading)
                    }
                }
            }
        }
        .navigationTitle("Контакти")
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
        guard let accountID = currentAccountID else { state = .failed("Увійдіть до акаунта"); return }
        let operation = operationGate.begin(accountID: accountID)
        let query = RecipientQueryNormalization.normalize(recipient)
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
            state = .failed("Користувача не знайдено або мережа недоступна. Дзвінок через сервіс неможливий.")
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
