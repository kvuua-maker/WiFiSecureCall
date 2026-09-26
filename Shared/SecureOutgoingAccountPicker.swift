import SwiftUI

struct SecureAccountChoice: Identifiable, Equatable {
    let accountID: UUID
    let phoneNumber: String

    var id: UUID { accountID }

    init(account: AccountSummary) {
        accountID = account.accountID
        phoneNumber = account.phoneNumber
    }
}

struct SecureOutgoingAccountPicker: View {
    let choices: [SecureAccountChoice]
    let onSelect: (SecureAccountChoice) -> Void

    var body: some View {
        NavigationView {
            List(choices) { choice in
                Button(choice.phoneNumber) { onSelect(choice) }
            }
            .navigationTitle("Secure Call account")
        }
    }
}
