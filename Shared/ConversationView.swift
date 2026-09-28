import SwiftUI

struct ConversationView: View {
    @ObservedObject var store: SecureMessageStore
    let conversation: SecureConversation
    let accountID: UUID
    @State private var draft = ""
    @State private var sending = false
    @State private var safeError: String?
    @State private var approvingDeviceID: UUID?
    @State private var pendingApproval: E2EEKeyChangeWarning?
    @State private var showsApprovalConfirmation = false

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.messages(conversationID: conversation.id, accountID: accountID)) { message in
                            HStack {
                                if message.isSentByCurrentUser { Spacer(minLength: 32) }
                                Text(message.text)
                                    .padding(10)
                                    .background(message.isSentByCurrentUser ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(message.availability == .available ? Color.primary : Color.secondary)
                                    .accessibilityLabel(message.availability == .available ? (message.isSentByCurrentUser ? "Sent secure message" : "Received secure message") : "Secure message unavailable")
                                if !message.isSentByCurrentUser { Spacer(minLength: 32) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: store.messages(conversationID: conversation.id, accountID: accountID).count) { _ in
                    if let last = store.messages(conversationID: conversation.id, accountID: accountID).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if let safeError { Text(safeError).font(.caption).foregroundStyle(.red) }
            HStack {
                TextField("Message", text: $draft)
                    #if !os(watchOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .accessibilityLabel("Secure message text")
                Button {
                    let text = draft
                    draft = ""
                    sending = true
                    Task {
                        do { try await store.send(text: text, conversation: conversation, accountID: accountID); safeError = nil }
                        catch { safeError = SecureMessageStore.safeError(error); draft = text }
                        sending = false
                    }
                } label: {
                    if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill") }
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(ProductAccessibility.sendMessage)
            }
            .padding([.horizontal, .bottom])
        }
        .navigationTitle("Secure chat")
        .toolbar {
            NavigationLink("Safety") {
                List {
                    let devices = store.safetyDevices(conversationID: conversation.id, accountID: accountID)
                    let warnings = store.keyChangeWarnings(conversationID: conversation.id, accountID: accountID)
                    if devices.isEmpty {
                        Text("Retrieving peer device fingerprints…")
                    } else {
                        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Peer device \(index + 1)").font(.caption)
                                Text(device.fingerprint).font(.caption.monospaced())
                                    #if !os(watchOS)
                                    .textSelection(.enabled)
                                    #endif
                                Text(device.trustState == .keyChanged ? "KEY_CHANGED — secure communication blocked" : "Stored by trust on first use; not independently verified")
                                    .font(.caption2).foregroundStyle(device.trustState == .keyChanged ? .red : .secondary)
                            }
                        }
                    }
                    ForEach(warnings) { warning in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("KEY_CHANGED").font(.headline).foregroundStyle(.red)
                            Text("Previously pinned").font(.caption)
                            Text(warning.pinnedFingerprint).font(.caption2.monospaced())
                            Text("Newly observed").font(.caption)
                            Text(warning.observedFingerprint).font(.caption2.monospaced())
                            #if os(watchOS)
                            Text("Approve this change in WiFi Secure Call on the paired/account iPhone before retrying.").font(.caption)
                            #else
                            Button("Approve new fingerprint") {
                                pendingApproval = warning
                                showsApprovalConfirmation = true
                            }
                            .disabled(approvingDeviceID != nil)
                            #endif
                        }
                    }
                }
                .navigationTitle("Safety")
                .task { await store.prepareSafety(conversation: conversation, accountID: accountID) }
            }
        }
        #if !os(watchOS)
        .confirmationDialog("Approve changed fingerprint?", isPresented: $showsApprovalConfirmation, titleVisibility: .visible) {
            Button("Approve new fingerprint", role: .destructive) {
                guard let warning = pendingApproval else { return }
                approvingDeviceID = warning.deviceID
                Task {
                    do { try await store.approveKeyChange(warning); await store.loadMessages(conversationID: conversation.id, accountID: accountID); safeError = nil }
                    catch { safeError = SecureMessageStore.safeError(error) }
                    approvingDeviceID = nil
                    pendingApproval = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingApproval = nil }
        } message: {
            Text("Only approve after independently confirming the new fingerprint. Cancel keeps the previous pin and secure communication blocked.")
        }
        #endif
        .task {
            await store.prepareSafety(conversation: conversation, accountID: accountID)
            await store.loadMessages(conversationID: conversation.id, accountID: accountID)
            await store.markRead(conversationID: conversation.id, accountID: accountID)
        }
    }
}

struct CallKeyChangeWarningsView: View {
    let accountID: UUID?
    @ObservedObject private var registry = E2EEKeyChangeRegistry.shared
    @State private var pendingApproval: E2EECallKeyChangeWarning?
    @State private var approving = false
    @State private var safeError: String?

    private var visibleWarnings: [E2EECallKeyChangeWarning] {
        registry.warnings(for: accountID)
    }

    var body: some View {
        Group {
            ForEach(Array(visibleWarnings.enumerated()), id: \.element.id) { index, warning in
                VStack(alignment: .leading, spacing: 5) {
                    Text("KEY_CHANGED — secure communication blocked").font(.headline).foregroundStyle(.red)
                    Text("Peer device \(index + 1)").font(.caption)
                    Text("Previously pinned").font(.caption2)
                    Text(warning.pinnedFingerprint).font(.caption2.monospaced())
                    Text("Newly observed").font(.caption2)
                    Text(warning.observedFingerprint).font(.caption2.monospaced())
                    #if os(watchOS)
                    Text("Approve this change in WiFi Secure Call on the paired/account iPhone before retrying.")
                        .font(.caption)
                    #else
                    Button("Approve new fingerprint") { pendingApproval = warning }
                        .disabled(approving)
                    #endif
                }
            }
            if let safeError { Text(safeError).font(.caption).foregroundStyle(.red) }
        }
        #if !os(watchOS)
        .confirmationDialog(
            "Approve changed fingerprint?",
            isPresented: Binding(
                get: { pendingApproval != nil },
                set: { if !$0 { pendingApproval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Approve new fingerprint", role: .destructive) {
                guard let warning = pendingApproval else { return }
                approving = true
                Task { await approve(warning) }
            }
            Button("Cancel", role: .cancel) { pendingApproval = nil }
        } message: {
            Text("Only approve after independently confirming the new fingerprint. Cancel keeps the previous pin and secure communication blocked.")
        }
        #endif
    }

    #if !os(watchOS)
    @MainActor
    private func approve(_ warning: E2EECallKeyChangeWarning) async {
        defer { approving = false; pendingApproval = nil }
        do {
            guard warning.accountID == accountID,
                  NotificationRuntime.shared.accountStore.accounts.contains(where: { $0.accountID == warning.accountID }) else {
                throw AccountAPIError.missingSession
            }
            let fresh = try await NotificationRuntime.shared.accountAPI.deviceKeys(accountID: warning.accountID, userID: warning.userID)
            guard let bundle = fresh.first(where: { $0.deviceID == warning.deviceID }),
                  bundle.signingPublicKey == warning.observedBundle.signingPublicKey,
                  bundle.agreementPublicKey == warning.observedBundle.agreementPublicKey,
                  bundle.keyVersion == warning.observedBundle.keyVersion,
                  bundle.protocolVersion == warning.observedBundle.protocolVersion else {
                throw E2EEIdentityError.keyChanged
            }
            try E2EEIdentityPinStore().approveReplacement(userID: warning.userID, bundle: bundle, accountID: warning.accountID)
            E2EEKeyChangeRegistry.shared.clear(accountID: warning.accountID, userID: warning.userID, deviceID: warning.deviceID)
            safeError = nil
        } catch {
            safeError = "The fresh fingerprint could not be approved"
        }
    }
    #endif
}
