import SwiftUI

/// Where the watch stores the SIP account it registers with.
///
/// The form asks for the server, the user and the password a SIP trunk or the
/// WiFi Secure Call SIP gateway issued. Nothing is prefilled and nothing is
/// written to an Info.plist: a password typed here goes straight to the keychain.
struct WatchSIPAccountView: View {
    @ObservedObject var store: SIPAccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var host = ""
    @State private var port = "443"
    @State private var path = "/sip"
    @State private var domain = ""
    @State private var password = ""
    @State private var status: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button("Close") { dismiss() }.font(.caption2)
                    Spacer()
                    Button("Save") { save() }.font(.caption2.weight(.semibold))
                }

                field("User", text: $username, placeholder: "watch1")
                field("Server", text: $host, placeholder: "sip.example.com")
                field("Port", text: $port, placeholder: "443")
                field("Path", text: $path, placeholder: "/sip")
                field("Domain", text: $domain, placeholder: "sip.example.com")
                secureField("Password", text: $password)

                if let status {
                    Text(status)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                if store.isConfigured {
                    Button("Forget account", role: .destructive) {
                        store.clear()
                        load()
                    }
                    .font(.caption2)
                }
            }
            .padding(.horizontal, 2)
        }
        .onAppear(perform: load)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(.caption2)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            SecureField(label, text: text)
                .font(.caption2)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func load() {
        let account = store.account
        guard account.isComplete else { return }
        username = account.username
        host = account.host
        port = String(account.port)
        path = account.webSocketPath
        domain = account.domain
        password = store.password
    }

    private func save() {
        let account = SIPAccount(
            username: username.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 0,
            webSocketPath: path.isEmpty ? "/" : path,
            displayName: username,
            domain: domain.isEmpty ? host : domain
        )
        guard account.isComplete else {
            status = "User, server, port and domain are required"
            return
        }
        guard password.count >= 8 else {
            status = "The password must be at least 8 characters"
            return
        }
        store.save(account: account, password: password)
        status = "Saved"
        dismiss()
    }
}
