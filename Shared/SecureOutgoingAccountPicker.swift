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
