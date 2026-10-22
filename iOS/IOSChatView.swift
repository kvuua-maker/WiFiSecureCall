import SwiftUI

/// One conversation: who you are talking to, what happened, and a place to type.
///
/// The call button is in the header because that is the action this product
/// exists for; the bubbles below are the shared history of calls.
struct IOSChatView: View {
    let contact: ChatContact
    @ObservedObject var session: CallSession
    @ObservedObject private var history = CallHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        ZStack {
            IOSTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(bubbles) { record in
                                bubble(record)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                inputBar
            }
        }
        .onAppear {
            DiagnosticsLog.shared.log(.ui, "screen_rendered", .info, details: "chat")
        }
    }

    private var bubbles: [CallRecord] {
        let records = history.records(for: contact.name)
        return records.isEmpty ? [] : records
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IOSTheme.accent)
            }
            .buttonStyle(.plain)

            IOSAvatar(name: contact.name, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text("tap the phone to call")
                    .font(.system(size: 12))
                    .foregroundStyle(IOSTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                call()
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(IOSTheme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.call")
            .accessibilityLabel("Call \(contact.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(IOSTheme.surface)
    }

    private func bubble(_ record: CallRecord) -> some View {
        HStack {
            if record.kind != .outgoing { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: record.symbol)
                        .font(.system(size: 12, weight: .semibold))
                    Text(record.kind == .outgoing ? "Outgoing call" : record.kind == .incoming ? "Incoming call" : "Call failed")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.white)
                Text(detail(record))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: IOSTheme.corner, style: .continuous)
                    .fill(record.kind == .outgoing ? IOSTheme.outgoingBubble : IOSTheme.incomingBubble)
            )
            if record.kind == .outgoing { Spacer(minLength: 40) }
        }
    }

    private func detail(_ record: CallRecord) -> String {
        let time = IOSMainView.time(record.date)
        guard record.duration > 0 else { return time }
        return "\(time) · \(WatchInCallView.format(record.duration))"
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft, prompt: Text("Message").foregroundStyle(IOSTheme.textSecondary))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(IOSTheme.surfaceRaised))
            Button {
                DiagnosticsLog.shared.log(.ui, "button_tapped", .info, details: "chat.send")
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(IOSTheme.accent))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(IOSTheme.surface)
    }

    private func call() {
        DiagnosticsLog.shared.log(.ui, "button_tapped", .info, details: "chat.call")
        DiagnosticsLog.shared.log(.signaling, "call_create_requested", .info, details: "target=watchOS")
        Task {
            await NotificationRuntime.shared.startPreferredCall(
                preferredPlatforms: ["watchOS"],
                accountID: contact.accountID,
                allowAnyPlatformFallback: true
            )
        }
    }
}
