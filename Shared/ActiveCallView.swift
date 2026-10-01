import SwiftUI

struct ActiveCallView: View {
    @ObservedObject var session: CallSession

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: session.isEndToEndEncryptedMedia ? "lock.shield.fill" : "phone.fill")
                .font(.largeTitle).foregroundStyle(session.isEndToEndEncryptedMedia ? .green : .accentColor)
            Text(session.incomingCallerName ?? "Співрозмовник").font(.title2).multilineTextAlignment(.center)
            Text(connectionText).foregroundStyle(.secondary)
            if session.elapsedSeconds > 0 { Text(duration).monospacedDigit() }
            if case .incomingRinging = session.state {
                HStack {
                    Button("Прийняти") { Task { await session.accept() } }
                        .tint(.green)
                    Button("Відхилити", role: .destructive) { Task { await session.reject() } }
                }
            }
            HStack(spacing: 30) {
                Button { session.toggleMute() } label: {
                    Label(session.isMuted ? "Увімкнути мікрофон" : "Вимкнути мікрофон", systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill")
                }
                .accessibilityLabel(session.isMuted ? ProductAccessibility.unmute : ProductAccessibility.mute)
                Button(role: .destructive) { Task { await session.endCall() } } label: { Label("Завершити", systemImage: "phone.down.fill") }
                    .accessibilityLabel(ProductAccessibility.endCall)
            }
        }
        .padding()
        .navigationTitle("Дзвінок")
    }

    private var duration: String { String(format: "%02d:%02d", session.elapsedSeconds / 60, session.elapsedSeconds % 60) }
    private var connectionText: String {
        switch session.state {
        case .idle: return "Готово"
        case .incomingRinging: return "Вхідний дзвінок"
        case .outgoingRinging: return "Виклик…"
        case .connecting: return "З’єднання…"
        case .active:
            return session.isEndToEndEncryptedMedia ? "Наскрізне шифрування активне" : "Дзвінок зі зв’язаним пристроєм — без E2EE аудіо"
        case .reconnecting: return "Повторне з’єднання…"
        case .ending: return "Завершення…"
        case .ended: return "Дзвінок завершено"
        case .failed(_, .accountMutationInProgress): return "Зачекайте завершення зміни акаунта"
        case .failed: return "Помилка дзвінка"
        }
    }
}
