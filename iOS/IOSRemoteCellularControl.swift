#if os(iOS)
import Foundation
import LiveCommunicationKit
import SwiftUI
import UIKit

@MainActor
protocol CellularConversationStarting: AnyObject {
    func startCellularConversation(to e164: String) async throws
}

enum RemoteCellularLocalError: String, Error {
    case foregroundRequired = "FOREGROUND_USER_ACTION_REQUIRED"
    case unsupportedOS = "PUBLIC_CELLULAR_API_UNAVAILABLE"
    case invalidNumber = "INVALID_E164"
    case startNotGranted = "START_NOT_GRANTED"
}

@MainActor
final class IOSPublicCellularConversationStarter: CellularConversationStarting {
    func startCellularConversation(to e164: String) async throws {
        guard UIApplication.shared.applicationState == .active else {
            throw RemoteCellularLocalError.foregroundRequired
        }
        guard let number = RemoteCellularControlPolicy.normalizedE164(e164) else {
            throw RemoteCellularLocalError.invalidNumber
        }
        guard #available(iOS 26.0, *) else {
            throw RemoteCellularLocalError.unsupportedOS
        }

        // This is the exact public, default-service path proven by the earlier
        // foreground cellular-conversation probe. No carrier is guessed.
        let handle = Handle(type: .phoneNumber, value: number)
        let action = StartCellularConversationAction(handle)
        try await TelephonyConversationManager.sharedInstance.startCellularConversation(action)
    }
}

@MainActor
final class IOSRemoteCellularControlCoordinator: ObservableObject {
    static let shared = IOSRemoteCellularControlCoordinator()

    @Published private(set) var diagnostic: RemoteCellularControlDiagnostic?
    @Published private(set) var isStarting = false
    @Published var presentationRequested = false

    private let api: any RemoteCellularControlAPI
    private let accountStore: AccountSessionStore
    private let starter: any CellularConversationStarting
    private let applicationIsActive: () -> Bool
    private var claimMutationIDs: [UUID: UUID] = [:]
    private var startResultMutationIDs: [UUID: UUID] = [:]
    private var locallyConsumed: Set<UUID> = []

    convenience private init() {
        let runtime = NotificationRuntime.shared
        self.init(
            api: runtime.accountAPI,
            accountStore: runtime.accountStore,
            starter: IOSPublicCellularConversationStarter(),
            applicationIsActive: { UIApplication.shared.applicationState == .active }
        )
    }

    init(
        api: any RemoteCellularControlAPI,
        accountStore: AccountSessionStore,
        starter: any CellularConversationStarting,
        applicationIsActive: @escaping () -> Bool
    ) {
        self.api = api
        self.accountStore = accountStore
        self.starter = starter
        self.applicationIsActive = applicationIsActive
    }

    func receive(_ envelope: RemoteCellularControlPushEnvelope, context: RemoteCellularReceiptContext) async {
        guard accountStore.accounts.contains(where: { $0.accountID == envelope.accountID }) else {
            diagnostic = Self.safeDiagnostic(
                envelope: envelope,
                context: context,
                state: .failedSafe,
                authorized: false,
                attempted: false,
                result: "LOCAL_ACCOUNT_NOT_FOUND"
            )
            presentationRequested = context != .background
            return
        }
        do {
            let control = try await api.receiveRemoteCellularControl(
                accountID: envelope.accountID,
                requestID: envelope.requestID,
                mutationID: envelope.requestID
            )
            guard control.requestID == envelope.requestID,
                  control.expiresAt > Date(),
                  control.sameOwnerAuthorized,
                  control.sourcePlatform == "watchOS",
                  control.targetPlatform == "iOS" else {
                throw RemoteCellularLocalError.startNotGranted
            }
            let userActionRequired = control.state == .iPhoneActionRequired
            diagnostic = RemoteCellularControlDiagnostic(
                requestID: control.requestID,
                accountID: envelope.accountID,
                expiresAt: control.expiresAt,
                state: control.state,
                receiptContext: context,
                sameOwnerAuthorized: true,
                userActionRequired: userActionRequired,
                systemStartAttempted: control.state == .startRequested,
                safeResult: Self.safeReceiptResult(state: control.state, context: context)
            )
            presentationRequested = context != .background
        } catch {
            diagnostic = Self.safeDiagnostic(
                envelope: envelope,
                context: context,
                state: .failedSafe,
                authorized: false,
                attempted: false,
                result: Self.safeError(error)
            )
            presentationRequested = context != .background
        }
    }

    func startPendingControl() async {
        guard applicationIsActive() else {
            updateResult("FOREGROUND_USER_ACTION_REQUIRED", attempted: false)
            return
        }
        guard let current = diagnostic, current.sameOwnerAuthorized,
              current.state == .iPhoneActionRequired,
              !isStarting, !locallyConsumed.contains(current.requestID) else { return }
        guard current.expiresAt.map({ $0 > Date() }) == true else {
            diagnostic = RemoteCellularControlDiagnostic(
                requestID: current.requestID, accountID: current.accountID, expiresAt: current.expiresAt,
                state: .expired, receiptContext: current.receiptContext, sameOwnerAuthorized: true,
                userActionRequired: false, systemStartAttempted: false, safeResult: "EXPIRED"
            )
            return
        }

        isStarting = true
        locallyConsumed.insert(current.requestID)
        defer { isStarting = false }
        let claimID = claimMutationIDs[current.requestID] ?? UUID()
        claimMutationIDs[current.requestID] = claimID

        do {
            let grant = try await api.claimRemoteCellularControlStart(
                accountID: current.accountID,
                requestID: current.requestID,
                mutationID: claimID
            )
            guard grant.startGranted, var transientNumber = grant.phoneNumber,
                  RemoteCellularControlPolicy.normalizedE164(transientNumber) != nil else {
                throw RemoteCellularLocalError.startNotGranted
            }
            defer { transientNumber.removeAll(keepingCapacity: false) }
            try await starter.startCellularConversation(to: transientNumber)

            let resultID = startResultMutationIDs[current.requestID] ?? UUID()
            startResultMutationIDs[current.requestID] = resultID
            _ = try? await api.markRemoteCellularControlStartRequested(
                accountID: current.accountID,
                requestID: current.requestID,
                mutationID: resultID
            )
            diagnostic = RemoteCellularControlDiagnostic(
                requestID: current.requestID,
                accountID: current.accountID,
                expiresAt: current.expiresAt,
                state: .startRequested,
                receiptContext: current.receiptContext,
                sameOwnerAuthorized: true,
                userActionRequired: false,
                systemStartAttempted: true,
                safeResult: "SYSTEM_HANDOFF"
            )
        } catch {
            updateResult(Self.safeError(error), attempted: true)
        }
    }

    func dismissPresentation() {
        presentationRequested = false
    }

    private func updateResult(_ result: String, attempted: Bool) {
        guard let current = diagnostic else { return }
        diagnostic = RemoteCellularControlDiagnostic(
            requestID: current.requestID,
            accountID: current.accountID,
            expiresAt: current.expiresAt,
            state: attempted ? .failedSafe : current.state,
            receiptContext: current.receiptContext,
            sameOwnerAuthorized: current.sameOwnerAuthorized,
            userActionRequired: !attempted,
            systemStartAttempted: attempted,
            safeResult: result
        )
    }

    private static func safeDiagnostic(
        envelope: RemoteCellularControlPushEnvelope,
        context: RemoteCellularReceiptContext,
        state: RemoteCellularControlState,
        authorized: Bool,
        attempted: Bool,
        result: String
    ) -> RemoteCellularControlDiagnostic {
        RemoteCellularControlDiagnostic(
            requestID: envelope.requestID,
            accountID: envelope.accountID,
            expiresAt: nil,
            state: state,
            receiptContext: context,
            sameOwnerAuthorized: authorized,
            userActionRequired: !attempted,
            systemStartAttempted: attempted,
            safeResult: result
        )
    }

    private static func safeReceiptResult(
        state: RemoteCellularControlState,
        context: RemoteCellularReceiptContext
    ) -> String {
        switch state {
        case .iPhoneActionRequired:
            return context == .background ? "IPHONE_RECEIVED_BACKGROUND" : "IPHONE_ACTION_REQUIRED"
        case .deliveryPending: return "IPHONE_DELIVERY_PENDING"
        case .iPhoneStartAuthorized: return "IPHONE_START_AUTHORIZED"
        case .startRequested: return "SYSTEM_HANDOFF_ALREADY_REQUESTED"
        case .cancelled: return "CANCELLED_BEFORE_SYSTEM_START"
        case .expired: return "EXPIRED"
        case .failedSafe: return "FAILED_SAFE"
        }
    }

    private static func safeError(_ error: Error) -> String {
        if let local = error as? RemoteCellularLocalError { return local.rawValue }
        if case let AccountAPIError.status(_, response) = error { return response?.error ?? "SERVER_REJECTED_SAFE" }
        if case let AccountAPIError.transport(domain, code) = error { return "TRANSPORT_\(domain)_\(code)" }
        return "FAILED_SAFE"
    }
}

struct IOSRemoteCellularControlView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator = IOSRemoteCellularControlCoordinator.shared

    var body: some View {
        NavigationView {
            List {
                if let value = coordinator.diagnostic {
                    line("Request", value.requestID.uuidString.lowercased())
                    line("Same-owner Watch", value.sameOwnerAuthorized ? "YES" : "NO")
                    line("Server verified fresh", value.expiresAt.map { $0 > Date() } == true ? "YES" : "NO")
                    line("Received", value.receiptContext.rawValue)
                    line("State", value.state.rawValue)
                    line("User action required", value.userActionRequired ? "YES" : "NO")
                    line("System start attempted", value.systemStartAttempted ? "YES" : "NO")
                    line("Result", value.safeResult)
                    if value.userActionRequired && value.sameOwnerAuthorized {
                        Button("Start cellular conversation") {
                            Task { await coordinator.startPendingControl() }
                        }
                        .disabled(coordinator.isStarting)
                    }
                } else {
                    Text("No remote cellular request")
                }
            }
            .navigationTitle("Remote cellular probe")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
#endif
