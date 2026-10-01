import SwiftUI

struct CallHistoryView: View {
    @ObservedObject var store: CallHistoryStore
    let accountID: UUID?
    let runtime: NotificationRuntime

    init(store: CallHistoryStore, accountID: UUID?, runtime: NotificationRuntime) {
        self.store = store
        self.accountID = accountID
        self.runtime = runtime
    }

    private var visibleRecords: [CallHistoryRecord] { store.records(for: accountID) }

    var body: some View {
        List {
            Section {
                NavigationLink("Новий дзвінок") {
                    RecipientSearchView(messageStore: .shared, runtime: runtime)
                }
                #if os(watchOS)
                Button("Мій iPhone") { startOwnCall(platform: "iOS") }
                #else
                Button("Подзвонити на мій Apple Watch") { startOwnCall(platform: "watchOS") }
                #endif
            }
            if visibleRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                    Text("Дзвінків поки немає").font(.headline)
                    Text("Почніть виклик через пошук користувача або свого зв’язаного пристрою.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                Section("Історія") { ForEach(visibleRecords) { record in
                    HStack(spacing: 10) {
                        Image(systemName: record.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                            .foregroundStyle(record.status == .missed || record.status == .failed ? .red : .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.peerDisplayName).lineLimit(1)
                            Text(statusText(record))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let terminalAt = record.terminalAt, let connectedAt = record.connectedAt, record.status == .answered {
                                Text(durationText(terminalAt.timeIntervalSince(connectedAt)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if let targetUserID = record.targetUserID, let accountID = record.accountID {
                            Button {
                                Task { await runtime.startUserCall(targetUserID: targetUserID, accountID: accountID, peerDisplayName: record.peerDisplayName) }
                            } label: { Image(systemName: "phone.arrow.up.right") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Повторити захищений дзвінок")
                        }
                        Text(record.startedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } }
            }
        }
        .navigationTitle("Дзвінки")
    }

    private func startOwnCall(platform: String) {
        guard let accountID else { return }
        Task { await runtime.startPreferredCall(targetPlatform: platform, accountID: accountID) }
    }

    private func statusText(_ record: CallHistoryRecord) -> String {
        switch record.status {
        case .ringing: return "Виклик"
        case .active: return "Триває"
        case .answered: return record.connectedAt == nil ? "Завершений" : "Відповіли"
        case .missed: return "Пропущено"
        case .rejected: return "Відхилено"
        case .failed: return "Не вдалося"
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
