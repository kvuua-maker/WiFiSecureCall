import SwiftUI

struct ConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SecureMessageStore
    let conversation: SecureConversation
    let accountID: UUID
    @State private var draft = ""
    @State private var sending = false
    @State private var safeError: String?
    @State private var approvingDeviceID: UUID?
    @State private var pendingApproval: E2EEKeyChangeWarning?
    @State private var showsApprovalConfirmation = false
    @State private var loadingOlder = false

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if store.hasOlderMessages(conversationID: conversation.id, accountID: accountID) {
                            Button(loadingOlder ? "Завантаження…" : "Раніші повідомлення") {
                                let anchor = store.messages(conversationID: conversation.id, accountID: accountID).first?.id
                                loadingOlder = true
                                Task {
                                    _ = await store.loadMessages(conversationID: conversation.id, accountID: accountID, append: true, reportsLoading: false)
                                    loadingOlder = false
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }.disabled(loadingOlder)
                        }
                        ForEach(store.messages(conversationID: conversation.id, accountID: accountID)) { message in
                            HStack {
                                if message.isSentByCurrentUser { Spacer(minLength: 32) }
                                Text(message.text)
                                    .padding(10)
                                    .background(message.isSentByCurrentUser ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(message.availability == .available ? Color.primary : Color.secondary)
                                    .accessibilityLabel(message.availability == .available ? (message.isSentByCurrentUser ? "Sent secure message" : "Received secure message") : "Secure message unavailable")
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(message.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                                    if message.isSentByCurrentUser && message.read { Text("Прочитано").font(.caption2) }
                                    else if message.isSentByCurrentUser && message.delivered { Text("Доставлено").font(.caption2) }
                                }
                                if !message.isSentByCurrentUser { Spacer(minLength: 32) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: store.messages(conversationID: conversation.id, accountID: accountID).count) { _ in
                    guard !loadingOlder else { return }
                    if let last = store.messages(conversationID: conversation.id, accountID: accountID).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if let safeError { Text(safeError).font(.caption).foregroundStyle(.red) }
            HStack {
                TextField("Повідомлення", text: $draft)
                    #if !os(watchOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .accessibilityLabel("Secure message text")
                Button {
                    let text = draft
                    sending = true
                    Task {
                        guard store.activeAccountID == accountID else {
                            safeError = "Акаунт змінено. Поверніться до списку чатів."
                            sending = false
                            return
                        }
                        do {
                            try await store.send(text: text, conversation: conversation, accountID: accountID)
                            if draft == text { draft = "" }
                            safeError = nil
                        }
                        catch { safeError = SecureMessageStore.safeError(error) }
                        sending = false
                    }
                } label: {
                    if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill") }
                }
                .disabled(sending || store.activeAccountID != accountID || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(ProductAccessibility.sendMessage)
            }
            .padding([.horizontal, .bottom])
        }
        .navigationTitle(conversation.peerDisplayName)
        .toolbar {
            if let peer = conversation.peer {
                Button {
                    Task { await NotificationRuntime.shared.startUserCall(targetUserID: peer.userID, accountID: accountID, peerDisplayName: conversation.peerDisplayName) }
                } label: { Image(systemName: "phone") }
                    .accessibilityLabel("Захищений дзвінок")
                    .disabled(store.activeAccountID != accountID)
            }
            NavigationLink("Безпека") {
                List {
                    let devices = store.safetyDevices(conversationID: conversation.id, accountID: accountID)
                    let warnings = store.keyChangeWarnings(conversationID: conversation.id, accountID: accountID)
                    if devices.isEmpty {
                        Text("Отримуємо відбитки пристроїв співрозмовника…")
                    } else {
                        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Пристрій співрозмовника \(index + 1)").font(.caption)
                                Text(device.fingerprint).font(.caption.monospaced())
                                    #if !os(watchOS)
                                    .textSelection(.enabled)
                                    #endif
                                Text(device.trustState == .keyChanged ? "Ключ безпеки змінився. Захищений зв’язок заблоковано." : "Збережено під час першого з’єднання; незалежно не перевірено")
                                    .font(.caption2).foregroundStyle(device.trustState == .keyChanged ? .red : .secondary)
                            }
                        }
                    }
                    ForEach(warnings) { warning in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Ключ безпеки змінився").font(.headline).foregroundStyle(.red)
                            Text("Раніше збережений відбиток").font(.caption)
                            Text(warning.pinnedFingerprint).font(.caption2.monospaced())
                            Text("Новий відбиток").font(.caption)
                            Text(warning.observedFingerprint).font(.caption2.monospaced())
                            #if os(watchOS)
                            Text("Підтвердьте зміну у WiFi Secure Call на зв’язаному iPhone, перш ніж повторити дію.").font(.caption)
                            #else
                            Button("Підтвердити новий відбиток") {
                                pendingApproval = warning
                                showsApprovalConfirmation = true
                            }
                            .disabled(approvingDeviceID != nil)
                            #endif
                        }
                    }
                }
                .navigationTitle("Безпека")
                .task { await store.prepareSafety(conversation: conversation, accountID: accountID) }
            }
        }
        #if !os(watchOS)
        .confirmationDialog("Підтвердити змінений відбиток?", isPresented: $showsApprovalConfirmation, titleVisibility: .visible) {
            Button("Підтвердити новий відбиток", role: .destructive) {
                guard let warning = pendingApproval else { return }
                approvingDeviceID = warning.deviceID
                Task {
                    do { try await store.approveKeyChange(warning); await store.loadMessages(conversationID: conversation.id, accountID: accountID); safeError = nil }
                    catch { safeError = SecureMessageStore.safeError(error) }
                    approvingDeviceID = nil
                    pendingApproval = nil
                }
            }
            Button("Скасувати", role: .cancel) { pendingApproval = nil }
        } message: {
            Text("Підтверджуйте лише після незалежної звірки нового відбитка. Скасування збереже попередній відбиток і блокування захищеного зв’язку.")
        }
        #endif
        .task {
            guard store.activeAccountID == accountID else { dismiss(); return }
            await store.prepareSafety(conversation: conversation, accountID: accountID)
            guard store.activeAccountID == accountID else { dismiss(); return }
            await store.loadMessages(conversationID: conversation.id, accountID: accountID)
            guard store.activeAccountID == accountID else { dismiss(); return }
            await store.markRead(conversationID: conversation.id, accountID: accountID)
        }
        .onChange(of: store.activeAccountID) { value in
            if value != accountID { dismiss() }
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
