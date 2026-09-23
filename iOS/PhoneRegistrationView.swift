import SwiftUI

struct PhoneRegistrationView: View {
    @ObservedObject var store: AccountSessionStore
    let client: AccountAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var verificationID: UUID?
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        Form {
            if verificationID == nil {
                Section("Phone number") {
                    TextField("+380…", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    Button("Send code") { Task { await sendCode() } }.disabled(busy || !E164Phone.isValid(E164Phone.canonicalized(phone)))
                }
            } else {
                Section("Verification code") {
                    TextField("123456", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Verify") { Task { await verify() } }.disabled(busy || code.count != 6)
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Register phone")
    }

    @MainActor private func sendCode() async {
        busy = true; defer { busy = false }
        do { verificationID = try await client.startPhone(E164Phone.canonicalized(phone)).verificationID; message = "Code sent" }
        catch { message = "Unable to send code" }
    }

    @MainActor private func verify() async {
        guard let verificationID else { return }
        busy = true; defer { busy = false }
        do {
            let response = try await client.verifyPhone(verificationID: verificationID, code: code)
            try store.add(response)
            await AccountPushRegistrationCoordinator.shared.registerKnownTokens(for: response.account.accountID)
            dismiss()
        }
        catch { message = "Verification failed" }
    }
}
