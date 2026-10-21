import SwiftUI
#if os(watchOS)
import WatchKit
#endif

/// The watch's home screen for the standalone SIP client.
///
/// Everything the previous screen did through the iPhone app — linking an account,
/// picking a peer device, asking a server to route the call — is gone. What is
/// left is a dialpad, a registration indicator, and the call in progress.
struct WatchRootView: View {
    @ObservedObject var session: SIPCallSession
    @EnvironmentObject private var accountStore: SIPAccountStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDialPad = false
    @State private var showAccount = false
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                header
                content
            }
            .padding(.horizontal, 2)
        }
        .sheet(isPresented: $showDialPad) { WatchDialPadView(session: session) }
        .sheet(isPresented: $showAccount) { WatchSIPAccountView(store: accountStore) }
        .sheet(isPresented: $showSettings) { WatchSIPDiagnosticsView(session: session) }
        .onAppear {
            session.installCallKitAdapter()
            session.connect()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                session.connect()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("WiFi Secure Call")
                .font(.headline)
            HStack(spacing: 4) {
                Circle()
                    .fill(session.isRegistered ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text(session.registrationText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .idle:
            idleControls
        case let .dialing(destination):
            busyControls(title: "Calling \(destination)…", canEnd: true)
        case let .ringing(destination):
            incomingControls(destination: destination)
        case let .connecting(destination):
            busyControls(title: "Connecting \(destination)…", canEnd: true)
        case .active:
            activeControls
        case let .ended(reason):
            VStack(spacing: 4) {
                Text("Call ended").font(.caption)
                if !reason.isEmpty {
                    Text(reason).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Button("Done") { session.reset() }
                    .font(.caption)
            }
        case let .failed(reason):
            VStack(spacing: 4) {
                Text("Call failed").font(.caption)
                Text(reason)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { session.reset() }
                    .font(.caption)
            }
        }
    }

    private var idleControls: some View {
        VStack(spacing: 5) {
            Button {
                if accountStore.isConfigured {
                    showDialPad = true
                } else {
                    showAccount = true
                }
            } label: {
                Label("Call", systemImage: "phone.fill")
                    .font(.body.weight(.semibold))
            }

            if let last = session.lastDialled, !last.isEmpty {
                Button("Redial \(last)") { session.placeCall(to: last) }
                    .font(.caption2)
            }

            Button(accountStore.isConfigured ? "SIP account" : "Set up SIP account") { showAccount = true }
                .font(.caption2)

            Button("Diagnostics") { showSettings = true }
                .font(.caption2)
        }
    }

    private func incomingControls(destination: String) -> some View {
        VStack(spacing: 5) {
            Text("Incoming call").font(.caption).foregroundStyle(.secondary)
            Text(destination).font(.caption).lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                Button("Decline", role: .destructive) { session.hangUp() }
                    .font(.caption)
                Button("Accept") { session.answerIncoming() }
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var activeControls: some View {
        VStack(spacing: 5) {
            Text(String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60))
                .font(.title3.monospacedDigit())
            if !session.remoteDisplay.isEmpty {
                Text(session.remoteDisplay)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack(spacing: 8) {
                Button(session.isMuted ? "Unmute" : "Mute") { session.toggleMute() }
                    .font(.caption2)
                Button("End", role: .destructive) { session.hangUp() }
                    .font(.caption2)
            }
            Button("Keypad") { showDialPad = true }
                .font(.caption2)
        }
    }

    private func busyControls(title: String, canEnd: Bool) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if canEnd {
                Button("Cancel", role: .destructive) { session.hangUp() }
                    .font(.caption)
            }
        }
    }
}

/// A dialpad that sends DTMF tones during a call and starts one when idle.
struct WatchDialPadView: View {
    @ObservedObject var session: SIPCallSession
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var typedDomain = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    private let keys: [(String, String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", "")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 3) {
                HStack {
                    Button("Back") { dismiss() }.font(.caption2)
                    Spacer()
                    Button("SIP") { typedDomain = true }.font(.caption2)
                }

                Text(number.isEmpty ? "Number" : number)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)

                if typedDomain {
                    TextField("sip:alice@example.com", text: $number)
                        .font(.caption2)
                        .textInputAutocapitalization(.never)
                }

                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Button {
                            append(key.0)
                        } label: {
                            VStack(spacing: 0) {
                                Text(key.0).font(.body)
                                if !key.1.isEmpty { Text(key.1).font(.system(size: 7)).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 26)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    Button {
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                    }
                    .buttonStyle(.plain)

                    if case .active = session.state {
                        Button("Send") { sendTone() }.font(.caption2)
                    } else {
                        Button("Call") { startCall() }.font(.caption2.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func append(_ key: String) {
        if key == "+" && !number.isEmpty { number.append("+"); return }
        if number.contains("+") && key == "+" { return }
        number.append(key)
        if case .active = session.state { sendTone() }
    }

    private func sendTone() {
        guard let last = number.last else { return }
        session.sendDTMF(String(last))
    }

    private func startCall() {
        let destination = number.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else { return }
        dismiss()
        session.placeCall(to: destination)
    }
}

/// Short diagnostic list, so a failing registration can be read on the watch.
struct WatchSIPDiagnosticsView: View {
    @ObservedObject var session: SIPCallSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Button("Close") { dismiss() }.font(.caption2)
                row("Registration", session.registrationText)
                row("State", String(describing: session.state))
                row("Remote", session.remoteDisplay.isEmpty ? "—" : session.remoteDisplay)
                row("Muted", session.isMuted ? "yes" : "no")
                if let failure = session.lastFailure, !failure.isEmpty {
                    Text(failure)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10)).lineLimit(2)
        }
    }
}
