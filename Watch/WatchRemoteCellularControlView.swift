#if os(watchOS)
import SwiftUI

@MainActor
final class WatchRemoteCellularControlProbe: ObservableObject {
    static let shared = WatchRemoteCellularControlProbe()

    enum SafeState: String, Equatable {
        case idle = "IDLE"
        case validating = "VALIDATING"
        case requesting = "REQUESTING"
        case serverAccepted = "SERVER_ACCEPTED"
        case iPhoneDeliveryPending = "IPHONE_DELIVERY_PENDING"
        case iPhoneBackgroundReceived = "IPHONE_BACKGROUND_RECEIVED"
        case iPhoneNotificationActionReceived = "IPHONE_NOTIFICATION_ACTION_RECEIVED"
        case iPhoneActionRequired = "IPHONE_ACTION_REQUIRED"
        case iPhoneStartAuthorized = "IPHONE_START_AUTHORIZED"
        case iPhoneBackgroundStartAttempted = "IPHONE_BACKGROUND_START_ATTEMPTED"
        case iPhoneForegroundStartAttempted = "IPHONE_FOREGROUND_START_ATTEMPTED"
        case iPhoneNotificationActionStartAttempted = "IPHONE_NOTIFICATION_ACTION_START_ATTEMPTED"
        case systemStartAccepted = "SYSTEM_START_ACCEPTED"
        case publicStartError = "PUBLIC_START_ERROR"
        case backgroundExecutionNotObserved = "BACKGROUND_EXECUTION_NOT_OBSERVED"
        case notificationActionNotObserved = "NOTIFICATION_ACTION_NOT_OBSERVED"
        case notificationActionObservedResultUnknown = "NOTIFICATION_ACTION_OBSERVED_RESULT_UNKNOWN"
        case startAttemptAcknowledgedResultUnknown = "START_ATTEMPT_ACKNOWLEDGED_RESULT_UNKNOWN"
        case failedSafe = "FAILED_SAFE"
        case expired = "EXPIRED"
        case cancelled = "CANCELLED"
    }

    @Published private(set) var state: SafeState = .idle
    @Published private(set) var requestID: UUID?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var deliveryStatus = "NOT_SUBMITTED"
    @Published private(set) var iPhoneReceived = false
    @Published private(set) var startAttempted = false
    @Published private(set) var safeResult = "NOT_STARTED"
    @Published private(set) var submissionResult = "READY"
    @Published var selectedDeliveryMode: RemoteCellularDeliveryMode = .silentBackground
    @Published private(set) var requestDeliveryMode: RemoteCellularDeliveryMode?
    @Published private(set) var ordinaryReceiptObserved = false
    @Published private(set) var notificationActionReceived = false
    @Published private(set) var ordinaryReceivedAt: Date?
    @Published private(set) var notificationActionReceivedAt: Date?
    @Published private(set) var startAttemptedAt: Date?
    @Published private(set) var iPhoneApplicationState: RemoteCellularApplicationState?

    private let api: any RemoteCellularControlAPI
    private let accountStore: AccountSessionStore
    private var pollTask: Task<Void, Never>?
    private var cancelMutationID: UUID?
    private var controlAccountID: UUID?
    private var liveRequestGate = RemoteCellularLiveRequestGate()
    private var lastServerState: RemoteCellularControlState?

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
        case .requesting, .serverAccepted, .iPhoneDeliveryPending,
             .iPhoneBackgroundReceived, .iPhoneNotificationActionReceived,
             .iPhoneActionRequired:
            return requestID != nil
        default:
            return false
        }
    }

    var hasLiveRequest: Bool { liveRequestGate.isLive }

    @discardableResult
    func submit(transientE164 value: String) async -> Bool {
        guard let number = RemoteCellularControlPolicy.normalizedE164(value) else {
            submissionResult = liveRequestGate.isLive
                ? "INVALID_E164_EXISTING_REQUEST_PRESERVED"
                : "INVALID_E164"
            if !liveRequestGate.isLive {
                state = .failedSafe
                safeResult = "INVALID_E164"
            }
            return false
        }
        guard let accountID = accountStore.activeAccountID,
              accountStore.callableAccounts.contains(where: { $0.accountID == accountID }) else {
            submissionResult = liveRequestGate.isLive
                ? "ACCOUNT_SESSION_REQUIRED_EXISTING_REQUEST_PRESERVED"
                : "ACCOUNT_SESSION_REQUIRED"
            if !liveRequestGate.isLive {
                state = .failedSafe
                safeResult = "ACCOUNT_SESSION_REQUIRED"
            }
            return false
        }

        let controlID = UUID()
        guard liveRequestGate.begin(requestID: controlID) else {
            submissionResult = "LIVE_REQUEST_MUST_CANCEL_OR_FINISH"
            return false
        }
        pollTask?.cancel()
        pollTask = nil
        requestID = controlID
        let deliveryModeSnapshot = selectedDeliveryMode
        requestDeliveryMode = deliveryModeSnapshot
        controlAccountID = accountID
        cancelMutationID = UUID()
        deliveryStatus = "NOT_SUBMITTED"
        iPhoneReceived = false
        ordinaryReceiptObserved = false
        notificationActionReceived = false
        ordinaryReceivedAt = nil
        notificationActionReceivedAt = nil
        startAttemptedAt = nil
        iPhoneApplicationState = nil
        startAttempted = false
        lastServerState = nil
        state = .requesting
        safeResult = "REQUESTING"
        submissionResult = "REQUEST_ACCEPTED_LOCALLY"
        do {
            let result: RemoteCellularControlView
            switch deliveryModeSnapshot {
            case .silentBackground:
                result = try await api.createRemoteCellularControl(
                    accountID: accountID,
                    requestID: controlID,
                    phoneNumber: number
                )
            case .notificationAction:
                result = try await api.createRemoteCellularNotificationActionControl(
                    accountID: accountID,
                    requestID: controlID,
                    phoneNumber: number
                )
            }
            guard result.effectiveDeliveryMode == deliveryModeSnapshot else {
                throw AccountAPIError.status(409, AccountAPIErrorResponse(error: "delivery_mode_mismatch", retryAt: nil))
            }
            apply(result)
            if liveRequestGate.isLive {
                beginPolling(accountID: accountID, requestID: controlID, expiresAt: result.expiresAt)
            }
        } catch {
            if Self.isAmbiguousTransport(error) {
                state = .iPhoneDeliveryPending
                safeResult = "CREATE_RESPONSE_AMBIGUOUS_RECONCILING"
                let localExpiry = Date().addingTimeInterval(RemoteCellularControlPolicy.requestTTL)
                expiresAt = localExpiry
                beginPolling(accountID: accountID, requestID: controlID, expiresAt: localExpiry)
            } else {
                state = .failedSafe
                safeResult = Self.safeError(error)
                finishLiveRequest(controlID)
            }
        }
        return true
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

    private func beginPolling(accountID: UUID, requestID: UUID, expiresAt: Date?) {
        pollTask?.cancel()
        let deadline = RemoteCellularControlPolicy.watchPollingDeadline(expiresAt: expiresAt, startedAt: Date())
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Date() >= deadline {
                    self.finishPollingDeadline(requestID: requestID)
                    return
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard Date() < deadline else {
                    self.finishPollingDeadline(requestID: requestID)
                    return
                }
                do {
                    let value = try await self.api.remoteCellularControl(accountID: accountID, requestID: requestID)
                    self.apply(value)
                    if Self.isTerminal(value.state) { return }
                } catch {
                    if Self.isRequestNotFound(error), Date() >= (self.expiresAt ?? deadline) {
                        self.finishPollingDeadline(requestID: requestID)
                        return
                    }
                    self.safeResult = Self.safeError(error)
                }
            }
        }
    }

    private func apply(_ value: RemoteCellularControlView) {
        guard liveRequestGate.owns(value.requestID), requestID == value.requestID else { return }
        expiresAt = value.expiresAt
        guard requestDeliveryMode == value.effectiveDeliveryMode else {
            state = .failedSafe
            safeResult = "DELIVERY_MODE_MISMATCH"
            finishLiveRequest(value.requestID)
            return
        }
        deliveryStatus = (value.deliveryStatus ?? "unknown").uppercased()
        iPhoneReceived = iPhoneReceived || value.receivedAt != nil
        ordinaryReceiptObserved = ordinaryReceiptObserved || value.ordinaryReceivedAt != nil
        notificationActionReceived = notificationActionReceived || value.notificationActionReceivedAt != nil
        ordinaryReceivedAt = ordinaryReceivedAt ?? value.ordinaryReceivedAt
        notificationActionReceivedAt = notificationActionReceivedAt ?? value.notificationActionReceivedAt
        startAttemptedAt = startAttemptedAt ?? value.startAttemptedAt
        if value.applicationState != nil {
            iPhoneApplicationState = value.applicationState
        }
        startAttempted = startAttempted || value.startAttemptedAt != nil
        lastServerState = value.state
        switch value.state {
        case .deliveryPending:
            state = .iPhoneDeliveryPending
            safeResult = "IPHONE_DELIVERY_PENDING"
        case .iPhoneActionRequired:
            state = .iPhoneActionRequired
            safeResult = "IPHONE_ACTION_REQUIRED"
        case .iPhoneBackgroundReceived:
            state = .iPhoneBackgroundReceived
            safeResult = "IPHONE_BACKGROUND_RECEIVED"
        case .iPhoneNotificationActionReceived:
            state = .iPhoneNotificationActionReceived
            safeResult = "IPHONE_NOTIFICATION_ACTION_RECEIVED"
        case .iPhoneStartAuthorized:
            state = .iPhoneStartAuthorized
            safeResult = "IPHONE_START_AUTHORIZED"
        case .iPhoneBackgroundStartAttempted:
            state = .iPhoneBackgroundStartAttempted
            safeResult = "IPHONE_BACKGROUND_START_ATTEMPTED"
        case .iPhoneForegroundStartAttempted:
            state = .iPhoneForegroundStartAttempted
            safeResult = "IPHONE_FOREGROUND_START_ATTEMPTED"
        case .iPhoneNotificationActionStartAttempted:
            state = .iPhoneNotificationActionStartAttempted
            safeResult = "IPHONE_NOTIFICATION_ACTION_START_ATTEMPTED"
        case .systemStartAccepted:
            state = .systemStartAccepted
            safeResult = "SYSTEM_START_ACCEPTED"
        case .publicStartError:
            state = .publicStartError
            safeResult = Self.publicError(value)
        case .cancelled:
            state = .cancelled
            safeResult = "CANCELLED_BEFORE_SYSTEM_START"
        case .expired:
            if value.terminalReason == "notification_action_not_observed" {
                state = .notificationActionNotObserved
                safeResult = "NOTIFICATION_ACTION_NOT_OBSERVED"
            } else if value.terminalReason == "background_execution_not_observed" {
                state = .backgroundExecutionNotObserved
                safeResult = "BACKGROUND_EXECUTION_NOT_OBSERVED"
            } else {
                state = .expired
                safeResult = "EXPIRED"
            }
        case .failedSafe:
            state = .failedSafe
            safeResult = "FAILED_SAFE"
        }
        if Self.isTerminal(value.state) {
            finishLiveRequest(value.requestID)
        }
    }

    private func finishPollingDeadline(requestID: UUID) {
        guard liveRequestGate.owns(requestID) else { return }
        if requestDeliveryMode == .notificationAction {
            guard let classification = RemoteCellularWatchDeadlinePolicy.classifyNotificationActionTimeout(
                lastServerState: lastServerState,
                notificationActionReceivedAt: notificationActionReceivedAt,
                startAttemptedAt: startAttemptedAt
            ) else {
                finishLiveRequest(requestID)
                return
            }
            switch classification.result {
            case .notificationActionNotObserved:
                state = .notificationActionNotObserved
            case .notificationActionObservedResultUnknown:
                state = .notificationActionObservedResultUnknown
            case .startAttemptAcknowledgedResultUnknown:
                state = .startAttemptAcknowledgedResultUnknown
            }
            safeResult = classification.result.rawValue
        } else if deliveryStatus == "SUBMISSION_ACCEPTED" && !iPhoneReceived {
            state = .backgroundExecutionNotObserved
            safeResult = "BACKGROUND_EXECUTION_NOT_OBSERVED"
        } else {
            state = .expired
            safeResult = "EXPIRED_WITHOUT_TERMINAL_RESPONSE"
        }
        finishLiveRequest(requestID)
    }

    private func finishLiveRequest(_ requestID: UUID) {
        liveRequestGate.finish(requestID: requestID)
        pollTask?.cancel()
        pollTask = nil
    }

    private static func isTerminal(_ value: RemoteCellularControlState) -> Bool {
        value == .systemStartAccepted || value == .publicStartError ||
            value == .cancelled || value == .expired || value == .failedSafe
    }

    private static func publicError(_ value: RemoteCellularControlView) -> String {
        guard value.safeErrorDomain != nil, let code = value.safeErrorCode else {
            return "PUBLIC_START_ERROR"
        }
        return "PUBLIC_START_ERROR_PublicCellularAPI_\(code)"
    }

    private static func safeError(_ error: Error) -> String {
        if case let AccountAPIError.status(_, response) = error { return response?.error ?? "SERVER_REJECTED_SAFE" }
        if case let AccountAPIError.transport(domain, code) = error { return "TRANSPORT_\(domain)_\(code)" }
        return "FAILED_SAFE"
    }

    private static func isAmbiguousTransport(_ error: Error) -> Bool {
        if case AccountAPIError.transport = error { return true }
        return false
    }

    private static func isRequestNotFound(_ error: Error) -> Bool {
        if case let AccountAPIError.status(status, response) = error {
            return status == 404 && response?.error == "request_not_found"
        }
        return false
    }
}

struct WatchRemoteCellularControlView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var probe = WatchRemoteCellularControlProbe.shared
    @State private var e164 = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    private let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    var body: some View {
        List {
            Section("Destination number") {
                Text(e164.isEmpty ? "+E.164 destination" : e164)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(maxWidth: .infinity)

                HStack {
                    Button("+") { append("+") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text("Outgoing SIM: selected on iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(digits, id: \.self) { digit in
                        Button(String(digit)) { append(digit) }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))
                    }

                    Button {
                        e164 = WatchSystemDialerNumber.deletingLast(from: e164)
                    } label: {
                        Image(systemName: "delete.left")
                    }
                    .accessibilityLabel("Delete")
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))

                    Button("0") { append("0") }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.28)))

                    Color.clear.frame(minHeight: 24)
                }
            }
            Section("Delivery probe") {
                Picker("Delivery", selection: $probe.selectedDeliveryMode) {
                    Text("Silent (existing)").tag(RemoteCellularDeliveryMode.silentBackground)
                    Text("Notification action (probe)").tag(RemoteCellularDeliveryMode.notificationAction)
                }
                .disabled(probe.hasLiveRequest)
                if probe.selectedDeliveryMode == .notificationAction {
                    Text("Потрібне додаткове натискання на пересланому сповіщенні Watch. Показ сповіщення не гарантовано; iPhone може показати системний вибір SIM.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Button("Test cellular start on iPhone") {
                let transientNumber = e164
                Task {
                    if await probe.submit(transientE164: transientNumber) {
                        e164.removeAll(keepingCapacity: false)
                    }
                }
            }
            .disabled(probe.hasLiveRequest || e164.isEmpty)
            Text("Source-line mode is configured locally on iPhone. SYSTEM_START_ACCEPTED means API acceptance only—not a connected call, hidden SIM picker, or Watch audio.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            line("State", probe.state.rawValue)
            line("Request", probe.requestID?.uuidString.lowercased() ?? "none")
            line("APNs", probe.deliveryStatus)
            line("Delivery mode", probe.requestDeliveryMode?.rawValue ?? "none")
            line("iPhone received", probe.iPhoneReceived ? "YES" : "NO")
            line("Ordinary receipt", probe.ordinaryReceiptObserved ? "YES" : "NO")
            line("Ordinary receipt at", probe.ordinaryReceivedAt.map(Self.timestamp) ?? "none")
            line("Notification action", probe.notificationActionReceived ? "YES" : "NO")
            line("Notification action at", probe.notificationActionReceivedAt.map(Self.timestamp) ?? "none")
            line("Start attempt ACK at", probe.startAttemptedAt.map(Self.timestamp) ?? "none")
            line("iPhone application state", probe.iPhoneApplicationState?.rawValue ?? "UNKNOWN")
            line("Start-attempt ACK", probe.startAttempted ? "YES" : "NO")
            line("Result", probe.safeResult)
            line("Submit", probe.submissionResult)
            if probe.canCancel {
                Button("Cancel pending request", role: .destructive) { Task { await probe.cancel() } }
            }
            Button("Close") { dismiss() }
        }
        .navigationTitle("Remote cellular probe")
        .onDisappear {
            e164.removeAll(keepingCapacity: false)
        }
    }

    private func append(_ value: Character) {
        e164 = WatchSystemDialerNumber.appending(value, to: e164)
    }

    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
#endif
