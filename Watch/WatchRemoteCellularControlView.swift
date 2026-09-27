#if os(watchOS)
import SwiftUI

@MainActor
final class WatchRemoteCellularControlProbe: ObservableObject {
    enum SafeState: String, Equatable {
        case idle = "IDLE"
        case validating = "VALIDATING"
        case requesting = "REQUESTING"
        case serverAccepted = "SERVER_ACCEPTED"
        case iPhoneDeliveryPending = "IPHONE_DELIVERY_PENDING"
        case iPhoneReceived = "IPHONE_RECEIVED"
        case iPhoneActionRequired = "IPHONE_ACTION_REQUIRED"
        case iPhoneStartRequested = "IPHONE_START_REQUESTED"
        case systemHandoff = "SYSTEM_HANDOFF"
        case failedSafe = "FAILED_SAFE"
        case expired = "EXPIRED"
        case cancelled = "CANCELLED"
    }

    @Published private(set) var state: SafeState = .idle
    @Published private(set) var requestID: UUID?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var safeResult = "NOT_STARTED"

    private let api: any RemoteCellularControlAPI
    private let accountStore: AccountSessionStore
    private var pollTask: Task<Void, Never>?
    private var cancelMutationID: UUID?
    private var controlAccountID: UUID?

    convenience init() {
        let runtime = NotificationRuntime.shared
        self.init(api: runtime.accountAPI, accountStore: runtime.accountStore)
    }

    init(api: any RemoteCellularControlAPI, accountStore: AccountSessionStore) {
        self.api = api
        self.accountStore = accountStore
    }

    var canCancel: Bool {
        switch state {
        case .requesting, .serverAccepted, .iPhoneDeliveryPending, .iPhoneReceived, .iPhoneActionRequired:
            return requestID != nil
        default:
            return false
        }
    }

    func submit(transientE164 value: String) async {
        pollTask?.cancel()
        state = .validating
        guard let number = RemoteCellularControlPolicy.normalizedE164(value) else {
            state = .failedSafe
            safeResult = "INVALID_E164"
            return
        }
        guard let accountID = accountStore.activeAccountID,
              accountStore.callableAccounts.contains(where: { $0.accountID == accountID }) else {
            state = .failedSafe
            safeResult = "ACCOUNT_SESSION_REQUIRED"
            return
        }

        let controlID = UUID()
        requestID = controlID
        controlAccountID = accountID
        cancelMutationID = UUID()
        state = .requesting
        safeResult = "REQUESTING"
        do {
            let result = try await api.createRemoteCellularControl(
                accountID: accountID,
                requestID: controlID,
                phoneNumber: number
            )
            apply(result)
            beginPolling(accountID: accountID, requestID: controlID)
        } catch {
            state = .failedSafe
            safeResult = Self.safeError(error)
        }
    }

    func cancel() async {
        guard let accountID = controlAccountID,
              let requestID,
              let mutationID = cancelMutationID else { return }
        do {
            let result = try await api.cancelRemoteCellularControl(
                accountID: accountID,
                requestID: requestID,
                mutationID: mutationID
            )
            apply(result)
        } catch {
            safeResult = Self.safeError(error)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func beginPolling(accountID: UUID, requestID: UUID) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                do {
                    let value = try await self.api.remoteCellularControl(accountID: accountID, requestID: requestID)
                    self.apply(value)
                    if Self.isTerminal(value.state) { return }
                } catch {
                    self.safeResult = Self.safeError(error)
                }
            }
        }
    }

    private func apply(_ value: RemoteCellularControlView) {
        expiresAt = value.expiresAt
        switch value.state {
        case .deliveryPending:
            state = .iPhoneDeliveryPending
            safeResult = "IPHONE_DELIVERY_PENDING"
        case .iPhoneActionRequired:
            state = .iPhoneActionRequired
            safeResult = "IPHONE_ACTION_REQUIRED"
        case .iPhoneStartAuthorized:
            state = .iPhoneStartRequested
            safeResult = "IPHONE_START_AUTHORIZED"
        case .startRequested:
            state = .systemHandoff
            safeResult = "SYSTEM_HANDOFF"
        case .cancelled:
            state = .cancelled
            safeResult = "CANCELLED_BEFORE_SYSTEM_START"
        case .expired:
            state = .expired
            safeResult = "EXPIRED"
        case .failedSafe:
            state = .failedSafe
            safeResult = "FAILED_SAFE"
        }
    }

    private static func isTerminal(_ value: RemoteCellularControlState) -> Bool {
        value == .startRequested || value == .cancelled || value == .expired || value == .failedSafe
    }

    private static func safeError(_ error: Error) -> String {
        if case let AccountAPIError.status(_, response) = error { return response?.error ?? "SERVER_REJECTED_SAFE" }
        if case let AccountAPIError.transport(domain, code) = error { return "TRANSPORT_\(domain)_\(code)" }
        return "FAILED_SAFE"
    }
}

struct WatchRemoteCellularControlView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var probe = WatchRemoteCellularControlProbe()
    @State private var e164 = ""

    var body: some View {
        List {
            TextField("+country number", text: $e164)
            Button("Request on iPhone") {
                let transientNumber = e164
                e164.removeAll(keepingCapacity: false)
                Task { await probe.submit(transientE164: transientNumber) }
            }
            .disabled(probe.state == .requesting)
            line("State", probe.state.rawValue)
            line("Request", probe.requestID?.uuidString.lowercased() ?? "none")
            line("Result", probe.safeResult)
            if probe.canCancel {
                Button("Cancel pending request", role: .destructive) { Task { await probe.cancel() } }
            }
            Button("Close") { dismiss() }
        }
        .navigationTitle("Remote cellular probe")
        .onDisappear {
            e164.removeAll(keepingCapacity: false)
            probe.stop()
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }
}
#endif
