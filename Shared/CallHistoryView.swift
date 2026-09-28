import SwiftUI

struct CallHistoryView: View {
    @ObservedObject var store: CallHistoryStore
    let accountID: UUID?

    private var visibleRecords: [CallHistoryRecord] { store.records(for: accountID) }

    var body: some View {
        Group {
            if visibleRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                    Text("No recent calls").font(.headline)
                    Text("Secure app-to-app calls will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List(visibleRecords) { record in
                    HStack(spacing: 10) {
                        Image(systemName: record.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                            .foregroundStyle(record.status == .missed || record.status == .failed ? .red : .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.peerDisplayName).lineLimit(1)
                            Text(statusText(record.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(record.startedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Recent calls")
    }

    private func statusText(_ status: CallHistoryStatus) -> String {
        switch status {
        case .ringing: return "Ringing"
        case .active: return "Active secure call"
        case .answered: return "Answered"
        case .missed: return "Missed"
        case .rejected: return "Rejected"
        case .failed: return "Failed"
        }
    }
}
