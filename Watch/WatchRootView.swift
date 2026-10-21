import SwiftUI

struct WatchRootView: View {
    @ObservedObject var session: CallSession
    @ObservedObject private var bridge = WatchCallBridge.shared
    @StateObject private var accountStore = AccountSessionStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAccount = false
    @State private var showAccountPicker = false
    @State private var showCallUser = false
    @State private var showSecureDialer = false
    @State private var showSystemDialer = false
    @State private var showCarrierCallingProbe = false

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text("WiFi Secure Call").font(.headline)
                Text(status).font(.caption2).multilineTextAlignment(.center)
                Text(audioPlacement).font(.system(size: 9)).foregroundStyle(.secondary)
                bridgeStatus
                controls
            }
            .padding(.horizontal, 3)
        }
        .sheet(isPresented: $showAccount) { WatchAccountLinkView(store: accountStore) }
        .sheet(isPresented: $showAccountPicker) {
            SecureOutgoingAccountPicker(choices: accountStore.callableAccounts.map(SecureAccountChoice.init)) { choice in
                showAccountPicker = false
                Task { await NotificationRuntime.shared.startLocalPeerCall(accountID: choice.accountID) }
            }
        }
        .sheet(isPresented: $showCallUser) { CallUserView(store: accountStore) }
        .sheet(isPresented: $showSecureDialer) { WatchSecureDialerView() }
        .sheet(isPresented: $showSystemDialer) { WatchSystemDialerView() }
        .sheet(isPresented: $showCarrierCallingProbe) { WatchCarrierCallingDiagnosticView() }
        .onAppear { bridge.activate() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: bridge.applicationDidBecomeActive()
            case .inactive, .background: bridge.applicationWillResignActive()
            @unknown default: break
            }
        }
    }

    /// The iPhone link, shown only when it has something to say. A watch that is
    /// out of range of its phone is the single most common reason a call does not
    /// start, so the reason is on screen rather than in a log.
    @ViewBuilder private var bridgeStatus: some View {
        if let incoming = bridge.incoming {
            VStack(spacing: 1) {
                Text("Incoming call").font(.system(size: 10, weight: .semibold))
                if let caller = incoming.caller, !caller.isEmpty {
                    Text(caller).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text("Answer on iPhone or the system banner")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Dismiss") { bridge.clearIncoming() }.font(.system(size: 9))
            }
        } else if !bridge.status.isEmpty {
            Text(bridge.status).font(.system(size: 9)).foregroundStyle(.secondary)
        } else if bridge.isSupported && !bridge.isActivated {
            Text("Linking to iPhone…").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch session.state {
        case .idle: return "Ready"
        case .outgoingRinging: return "Calling…"
        case .incomingRinging: return session.incomingCallerName.map { "Incoming from " + $0 } ?? "Incoming Wi-Fi call"
        case .connecting: return "Connecting…"
        case .active: return String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60)
        case .reconnecting: return "Reconnecting…"
        case .ending: return "Ending…"
        case .ended: return "Call ended"
        case let .failed(_, failure): return failure.rawValue
        }
    }

    /// The watch captures and renders both directions of the call itself; no paired iPhone process
    /// takes part in the media path.
    private var audioPlacement: String {
        switch session.state {
        case .idle, .ended, .failed:
            return "Microphone and speaker stay on this Apple Watch"
        case .outgoingRinging, .incomingRinging, .connecting, .active, .reconnecting, .ending:
            return session.isMuted ? "Muted on Apple Watch" : "Call audio on Apple Watch"
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.state {
        case .idle:
            VStack(spacing: 4) {
                Button("Call number") { beginSecureCall() }
                    .font(.body.weight(.semibold))
                Button("Call user") { if accountStore.callableAccounts.isEmpty { showAccount = true } else { showCallUser = true } }
                    .font(.caption)
                Button("Call linked device") { beginLinkedDeviceCall() }
                    .font(.caption2)
                Button(accountStore.accounts.isEmpty ? "Link Account" : "Account") { showAccount = true }
                    .font(.caption2)
                Button("Cellular call") { showSystemDialer = true }
                    .font(.caption2)
                Button("Carrier probe") { showCarrierCallingProbe = true }
                    .font(.caption2)
            }
        case .outgoingRinging:
            Button("Cancel", role: .destructive) { Task { await session.cancel() } }
        case .incomingRinging:
            HStack { Button("Reject", role: .destructive) { Task { await session.reject() } }; Button("Accept") { Task { await session.accept() } } }
        case .active:
            HStack { Button(session.isMuted ? "Unmute" : "Mute") { session.toggleMute() }; Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .connecting, .reconnecting:
            VStack { ProgressView(); Button("End", role: .destructive) { Task { await session.endCall() } } }
        case .ending:
            ProgressView()
        case .ended, .failed:
            Button("Done") { session.reset() }
        }
    }

    private func beginSecureCall() {
        guard !accountStore.callableAccounts.isEmpty else {
            showAccount = true
            return
        }
        showSecureDialer = true
    }

    private func beginLinkedDeviceCall() {
        let accounts = accountStore.callableAccounts
        if accounts.isEmpty {
            showAccount = true
        } else if accounts.count == 1, let account = accounts.first {
            Task { await NotificationRuntime.shared.startLocalPeerCall(accountID: account.accountID) }
        } else {
            showAccountPicker = true
        }
    }
}