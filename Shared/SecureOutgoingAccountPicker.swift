import SwiftUI

struct SecureAccountChoice: Identifiable, Equatable {
    let accountID: UUID
    let displayLabel: String

    var id: UUID { accountID }

    init(account: AccountSummary) {
        accountID = account.accountID
        displayLabel = account.displayLabel
    }
}

struct SecureOutgoingAccountPicker: View {
    let choices: [SecureAccountChoice]
    let onSelect: (SecureAccountChoice) -> Void

    var body: some View {
        NavigationView {
            List(choices) { choice in
                Button(choice.displayLabel) { onSelect(choice) }
            }
            .navigationTitle("Secure Call account")
        }
    }
}


struct CallUserView: View {
    @ObservedObject var store: AccountSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var selectedAccountID: UUID?
    @State private var resolved: ResolvedRecipient?
    @State private var errorMessage: String?
    @State private var working = false

    private var accounts: [AccountSummary] { store.callableAccounts }

    var body: some View {
        NavigationView {
            Form {
                if accounts.count > 1 {
                    Picker("Call from", selection: $selectedAccountID) {
                        ForEach(accounts) { account in
                            Text(account.displayLabel).tag(Optional(account.accountID))
                        }
                    }
                }
                TextField("@username or +phone", text: $recipient)
                    .autocorrectionDisabled()
                if let resolved {
                    VStack(alignment: .leading) {
                        Text("@" + resolved.username).font(.headline)
                        if let displayName = resolved.displayName, !displayName.isEmpty { Text(displayName) }
                        if let phone = resolved.phoneNumber, !phone.isEmpty { Text(phone).font(.caption) }
                    }
                    Button("Secure Call") { beginCall(resolved) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(working ? "Resolving…" : "Resolve") { resolve() }
                        .disabled(working || recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Call user")
            .onAppear {
                if selectedAccountID == nil {
                    selectedAccountID = accounts.first(where: { account in account.accountID == store.activeAccountID })?.accountID ?? accounts.first?.accountID
                }
            }
            .onChange(of: recipient) { _ in resolved = nil; errorMessage = nil }
        }
    }

    private func resolve() {
        guard let accountID = selectedAccountID ?? accounts.first?.accountID else {
            errorMessage = "Link an account first"
            return
        }
        working = true; errorMessage = nil; resolved = nil
        let input = recipient
        Task { @MainActor in
            defer { working = false }
            do { resolved = try await NotificationRuntime.shared.resolveRecipient(input, accountID: accountID) }
            catch { errorMessage = Self.safeMessage(error) }
        }
    }

    private func beginCall(_ recipient: ResolvedRecipient) {
        guard let accountID = selectedAccountID ?? accounts.first?.accountID else { return }
        dismiss()
        Task { await NotificationRuntime.shared.startUserCall(targetUserID: recipient.userID, accountID: accountID) }
    }

    private static func safeMessage(_ error: Error) -> String {
        guard let apiError = error as? AccountAPIError else { return "Call failed" }
        switch apiError {
        case let .status(_, response):
            switch response?.error {
            case "invalid_recipient": return "Invalid recipient"
            case "recipient_not_found": return "User not found"
            case "recipient_unavailable": return "User unavailable"
            default: return "Call failed"
            }
        case .missingSession: return "Link an account first"
        default: return "Call failed"
        }
    }
}
