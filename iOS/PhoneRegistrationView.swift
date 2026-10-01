import SwiftUI

struct PhoneRegistrationView: View {
    @ObservedObject var store: AccountSessionStore
    let client: AccountAPIClient
    let canActivateAccount: () -> Bool
    let onAccountAdded: (UUID, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var verificationID: UUID?
    @State private var busy = false
    @State private var message = ""

    init(
        store: AccountSessionStore,
        client: AccountAPIClient,
        canActivateAccount: @escaping () -> Bool = { true },
        onAccountAdded: @escaping (UUID, Bool) -> Void = { _, _ in }
    ) {
        self.store = store
        self.client = client
        self.canActivateAccount = canActivateAccount
        self.onAccountAdded = onAccountAdded
    }

    var body: some View {
        Form {
            if verificationID == nil {
                Section("Номер телефону") {
                    TextField("+380…", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    Button("Надіслати код") { Task { await sendCode() } }.disabled(busy || !E164Phone.isValid(E164Phone.canonicalized(phone)))
                }
            } else {
                Section("Код підтвердження") {
                    TextField("123456", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Підтвердити") { Task { await verify() } }.disabled(busy || code.count != 6)
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Реєстрація номера")
    }

    @MainActor private func sendCode() async {
        busy = true; defer { busy = false }
        do { verificationID = try await client.startPhone(E164Phone.canonicalized(phone)).verificationID; message = "Код надіслано" }
        catch { message = "Не вдалося надіслати код" }
    }

    @MainActor private func verify() async {
        guard let verificationID else { return }
        busy = true; defer { busy = false }
        do {
            let response = try await client.verifyPhone(verificationID: verificationID, code: code)
            let decision = accountSessionIntegrationDecision(canChangeActiveAccount: canActivateAccount(), activeAccountID: store.activeAccountID, incomingAccountID: response.account.accountID)
            try store.add(response, activate: decision.activate, invalidateE2EE: decision.invalidateE2EE)
            await AccountPushRegistrationCoordinator.shared.registerKnownTokens(for: response.account.accountID)
            onAccountAdded(response.account.accountID, decision.activate)
            dismiss()
        }
        catch { message = "Не вдалося підтвердити код" }
    }
}
