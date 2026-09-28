import SwiftUI

struct ConversationView: View {
    @ObservedObject var store: SecureMessageStore
    let conversation: SecureConversation
    @State private var draft = ""
    @State private var sending = false
    @State private var safeError: String?

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.messages[conversation.id, default: []]) { message in
                            HStack {
                                if message.isSentByCurrentUser { Spacer(minLength: 32) }
                                Text(message.text)
                                    .padding(10)
                                    .background(message.isSentByCurrentUser ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel(message.isSentByCurrentUser ? "Sent secure message" : "Received secure message")
                                if !message.isSentByCurrentUser { Spacer(minLength: 32) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: store.messages[conversation.id, default: []].count) { _ in
                    if let last = store.messages[conversation.id]?.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
                        do { try await store.send(text: text, conversation: conversation); safeError = nil }
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
                    if store.safetyFingerprints[conversation.id, default: []].isEmpty {
                        Text("Safety fingerprint becomes available after authenticated key retrieval.")
                    } else {
                        ForEach(store.safetyFingerprints[conversation.id, default: []], id: \.self) { fingerprint in
                            Text(fingerprint).font(.caption.monospaced())
                                #if !os(watchOS)
                                .textSelection(.enabled)
                                #endif
                        }
                    }
                    Text("A changed key blocks calls and messages until independently approved.").font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle("Safety")
            }
        }
        .task { await store.loadMessages(conversationID: conversation.id); await store.markRead(conversationID: conversation.id) }
    }
}
