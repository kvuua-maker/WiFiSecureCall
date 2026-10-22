import SwiftUI

/// The iPhone app's shell: the three-tab messenger, plus the sheets that belong to
/// configuration rather than to a conversation.
struct TelegramRootView: View {
    @ObservedObject var session: CallSession
    @StateObject private var accountStore = AccountSessionStore.shared
    @State private var showAccount = false
    @State private var showCallUser = false
    @State private var showDialDiagnostics = false
    @State private var showCarrierCallingProbe = false

    private var isOnCall: Bool {
        switch session.state {
        case .idle, .ended, .failed: return false
        default: return true
        }
    }

    var body: some View {
        IOSMainView(session: session)
            .preferredColorScheme(.dark)
            .fullScreenCover(isPresented: .constant(isOnCall), onDismiss: { session.reset() }) {
                IOSCallScreenView(session: session)
            }
            .sheet(isPresented: $showAccount) { AccountView(store: accountStore) }
            .sheet(isPresented: $showCallUser) { CallUserView(store: accountStore) }
            .sheet(isPresented: $showDialDiagnostics) { SystemDialDiagnosticsView() }
            .sheet(isPresented: $showCarrierCallingProbe) { CarrierCallingDiagnosticView() }
            .onAppear {
                DiagnosticsLog.shared.start()
                DiagnosticsEnvironment.recordLaunch()
                IOSWatchCallBridge.shared.activate()
                IOSDialRelay.shared.start()
            }
    }
}
