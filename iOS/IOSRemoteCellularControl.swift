#if os(iOS)
import Foundation
import LiveCommunicationKit
import SwiftUI

@MainActor
final class RemoteCellularExactlyOnceCompletion<Result> {
    private var finished = false
    private let completion: (Result) -> Void

    init(_ completion: @escaping (Result) -> Void) {
        self.completion = completion
    }

    func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        completion(result)
    }
}

@MainActor
protocol CellularConversationStarting: AnyObject {
    func startCellularConversation(to e164: String) async throws
}

enum RemoteCellularLocalError: String, Error {
    case unsupportedOS = "PUBLIC_CELLULAR_API_UNAVAILABLE"
    case invalidNumber = "INVALID_E164"
    case startNotGranted = "START_NOT_GRANTED"
}

@MainActor
final class IOSPublicCellularConversationStarter: CellularConversationStarting {
    func startCellularConversation(to e164: String) async throws {
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
    private var claimMutationIDs: [UUID: UUID] = [:]
    private var startAttemptMutationIDs: [UUID: UUID] = [:]
    private var completionMutationIDs: [UUID: UUID] = [:]
    private var locallyConsumed: Set<UUID> = []

    convenience private init() {
        let runtime = NotificationRuntime.shared
        self.init(
            api: runtime.accountAPI,
            accountStore: runtime.accountStore,
            starter: IOSPublicCellularConversationStarter()
        )
    }

    init(
        api: any RemoteCellularControlAPI,
        accountStore: AccountSessionStore,
        starter: any CellularConversationStarting
    ) {
        self.api = api
        self.accountStore = accountStore
        self.starter = starter
    }

    func receive(
        _ envelope: RemoteCellularControlPushEnvelope,
        context: RemoteCellularReceiptContext,
        applicationState: RemoteCellularApplicationState
    ) async {
        let automaticBackgroundAttempt = context == .background || context == .inactive
        guard accountStore.accounts.contains(where: { $0.accountID == envelope.accountID }) else {
            diagnostic = Self.safeDiagnostic(
                envelope: envelope,
                context: context,
                applicationState: applicationState,
                state: .failedSafe,
                authorized: false,
                attempted: false,
                result: "LOCAL_ACCOUNT_NOT_FOUND"
            )
            presentationRequested = !automaticBackgroundAttempt
            return
        }
        do {
            let control = try await api.receiveRemoteCellularControl(
                accountID: envelope.accountID,
                requestID: envelope.requestID,
                mutationID: envelope.requestID,
                context: context
            )
            guard control.requestID == envelope.requestID,
                  control.expiresAt > Date(),
                  control.sameOwnerAuthorized,
                  control.sourcePlatform == "watchOS",
                  control.targetPlatform == "iOS" else {
                throw RemoteCellularLocalError.startNotGranted
            }
            let value = RemoteCellularControlDiagnostic(
                requestID: control.requestID,
                accountID: envelope.accountID,
                expiresAt: control.expiresAt,
                state: control.state,
                receiptContext: context,
                applicationStateAtReceipt: applicationState,
                sameOwnerAuthorized: true,
                userActionRequired: control.state == .iPhoneActionRequired && !automaticBackgroundAttempt,
                startClaimObtained: Self.hasStartClaim(control.state),
                systemStartAttempted: Self.hasStartAttempt(control.state),
                publicStartReturnedSuccess: Self.publicStartSuccess(control.state),
                safeResult: Self.safeReceiptResult(state: control.state, context: context)
            )
            diagnostic = value
            presentationRequested = !automaticBackgroundAttempt
            if automaticBackgroundAttempt && control.state == .iPhoneBackgroundReceived {
                await attemptStart(value)
            }
        } catch {
            diagnostic = Self.safeDiagnostic(
                envelope: envelope,
                context: context,
                applicationState: applicationState,
                state: .failedSafe,
                authorized: false,
                attempted: false,
                result: Self.safeError(error)
            )
            presentationRequested = !automaticBackgroundAttempt
        }
    }

    func startPendingControl() async {
        guard let current = diagnostic, current.sameOwnerAuthorized,
              current.state == .iPhoneActionRequired else { return }
        await attemptStart(current)
    }

    private func attemptStart(_ current: RemoteCellularControlDiagnostic) async {
        guard !isStarting, !locallyConsumed.contains(current.requestID) else { return }
        guard current.expiresAt.map({ $0 > Date() }) == true else {
            diagnostic = RemoteCellularControlDiagnostic(
                requestID: current.requestID, accountID: current.accountID, expiresAt: current.expiresAt,
                state: .expired, receiptContext: current.receiptContext,
                applicationStateAtReceipt: current.applicationStateAtReceipt,
                sameOwnerAuthorized: true, userActionRequired: false,
                startClaimObtained: false, systemStartAttempted: false,
                publicStartReturnedSuccess: nil, safeResult: "EXPIRED"
            )
            return
        }

        isStarting = true
        locallyConsumed.insert(current.requestID)
        defer { isStarting = false }
        let claimID = claimMutationIDs[current.requestID] ?? UUID()
        claimMutationIDs[current.requestID] = claimID

        do {
            var grant = try await api.claimRemoteCellularControlStart(
                accountID: current.accountID,
                requestID: current.requestID,
                mutationID: claimID
            )
            guard grant.startGranted, var transientNumber = grant.phoneNumber,
                  RemoteCellularControlPolicy.normalizedE164(transientNumber) != nil else {
                throw RemoteCellularLocalError.startNotGranted
            }
            grant.phoneNumber = nil
            defer { transientNumber.removeAll(keepingCapacity: false) }
            diagnostic = RemoteCellularControlDiagnostic(
                requestID: current.requestID,
                accountID: current.accountID,
                expiresAt: current.expiresAt,
                state: .iPhoneStartAuthorized,
                receiptContext: current.receiptContext,
                applicationStateAtReceipt: current.applicationStateAtReceipt,
                sameOwnerAuthorized: true,
                userActionRequired: false,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil,
                safeResult: "IPHONE_START_AUTHORIZED"
            )

            let publicStartError: Error?
            do {
                try await starter.startCellularConversation(to: transientNumber)
                publicStartError = nil
            } catch {
                publicStartError = error
            }
            transientNumber.removeAll(keepingCapacity: false)

            let attemptID = startAttemptMutationIDs[current.requestID] ?? UUID()
            startAttemptMutationIDs[current.requestID] = attemptID
            let attemptedView = try? await api.markRemoteCellularControlStartAttempted(
                accountID: current.accountID,
                requestID: current.requestID,
                mutationID: attemptID
            )
            diagnostic = RemoteCellularControlDiagnostic(
                requestID: current.requestID,
                accountID: current.accountID,
                expiresAt: current.expiresAt,
                state: attemptedView?.state ?? Self.attemptedState(for: current.receiptContext),
                receiptContext: current.receiptContext,
                applicationStateAtReceipt: current.applicationStateAtReceipt,
                sameOwnerAuthorized: true,
                userActionRequired: false,
                startClaimObtained: true,
                systemStartAttempted: true,
                publicStartReturnedSuccess: nil,
                safeResult: Self.attemptedResult(for: current.receiptContext)
            )
            if publicStartError == nil {
                let completionID = completionMutationIDs[current.requestID] ?? UUID()
                completionMutationIDs[current.requestID] = completionID
                _ = try? await api.completeRemoteCellularControlStart(
                    accountID: current.accountID,
                    requestID: current.requestID,
                    mutationID: completionID,
                    result: .accepted,
                    errorDomain: nil,
                    errorCode: nil
                )
                diagnostic = RemoteCellularControlDiagnostic(
                    requestID: current.requestID, accountID: current.accountID, expiresAt: current.expiresAt,
                    state: .systemStartAccepted, receiptContext: current.receiptContext,
                    applicationStateAtReceipt: current.applicationStateAtReceipt,
                    sameOwnerAuthorized: true, userActionRequired: false,
                    startClaimObtained: true, systemStartAttempted: true,
                    publicStartReturnedSuccess: true, safeResult: "SYSTEM_START_ACCEPTED"
                )
            } else if let publicStartError {
                let metadata = Self.safePublicStartError(publicStartError)
                let completionID = completionMutationIDs[current.requestID] ?? UUID()
                completionMutationIDs[current.requestID] = completionID
                _ = try? await api.completeRemoteCellularControlStart(
                    accountID: current.accountID,
                    requestID: current.requestID,
                    mutationID: completionID,
                    result: .error,
                    errorDomain: metadata.domain,
                    errorCode: metadata.code
                )
                diagnostic = RemoteCellularControlDiagnostic(
                    requestID: current.requestID, accountID: current.accountID, expiresAt: current.expiresAt,
                    state: .publicStartError, receiptContext: current.receiptContext,
                    applicationStateAtReceipt: current.applicationStateAtReceipt,
                    sameOwnerAuthorized: true, userActionRequired: false,
                    startClaimObtained: true, systemStartAttempted: true,
                    publicStartReturnedSuccess: false, safeResult: metadata.classification
                )
            }
        } catch {
            updatePreStartFailure(Self.safeError(error))
        }
    }

    func dismissPresentation() {
        presentationRequested = false
    }

    private func updatePreStartFailure(_ result: String) {
        guard let current = diagnostic else { return }
        diagnostic = RemoteCellularControlDiagnostic(
            requestID: current.requestID,
            accountID: current.accountID,
            expiresAt: current.expiresAt,
            state: .failedSafe,
            receiptContext: current.receiptContext,
            applicationStateAtReceipt: current.applicationStateAtReceipt,
            sameOwnerAuthorized: current.sameOwnerAuthorized,
            userActionRequired: false,
            startClaimObtained: false,
            systemStartAttempted: false,
            publicStartReturnedSuccess: nil,
            safeResult: result
        )
    }

    private static func safeDiagnostic(
        envelope: RemoteCellularControlPushEnvelope,
        context: RemoteCellularReceiptContext,
        applicationState: RemoteCellularApplicationState,
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
            applicationStateAtReceipt: applicationState,
            sameOwnerAuthorized: authorized,
            userActionRequired: !attempted,
            startClaimObtained: false,
            systemStartAttempted: attempted,
            publicStartReturnedSuccess: nil,
            safeResult: result
        )
    }

    private static func safeReceiptResult(
        state: RemoteCellularControlState,
        context: RemoteCellularReceiptContext
    ) -> String {
        switch state {
        case .iPhoneActionRequired:
            return "IPHONE_ACTION_REQUIRED"
        case .iPhoneBackgroundReceived: return "IPHONE_BACKGROUND_RECEIVED"
        case .deliveryPending: return "IPHONE_DELIVERY_PENDING"
        case .iPhoneStartAuthorized: return "IPHONE_START_AUTHORIZED"
        case .iPhoneBackgroundStartAttempted: return "IPHONE_BACKGROUND_START_ATTEMPTED"
        case .iPhoneForegroundStartAttempted: return "IPHONE_FOREGROUND_START_ATTEMPTED"
        case .systemStartAccepted: return "SYSTEM_START_ACCEPTED"
        case .publicStartError: return "PUBLIC_START_ERROR"
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

    private static func hasStartClaim(_ state: RemoteCellularControlState) -> Bool {
        switch state {
        case .iPhoneStartAuthorized, .iPhoneBackgroundStartAttempted,
             .iPhoneForegroundStartAttempted, .systemStartAccepted, .publicStartError:
            return true
        default:
            return false
        }
    }

    private static func hasStartAttempt(_ state: RemoteCellularControlState) -> Bool {
        switch state {
        case .iPhoneBackgroundStartAttempted, .iPhoneForegroundStartAttempted,
             .systemStartAccepted, .publicStartError:
            return true
        default:
            return false
        }
    }

    private static func publicStartSuccess(_ state: RemoteCellularControlState) -> Bool? {
        if state == .systemStartAccepted { return true }
        if state == .publicStartError { return false }
        return nil
    }

    private static func attemptedState(for context: RemoteCellularReceiptContext) -> RemoteCellularControlState {
        context == .background || context == .inactive
            ? .iPhoneBackgroundStartAttempted
            : .iPhoneForegroundStartAttempted
    }

    private static func attemptedResult(for context: RemoteCellularReceiptContext) -> String {
        context == .background || context == .inactive
            ? "IPHONE_BACKGROUND_START_ATTEMPTED"
            : "IPHONE_FOREGROUND_START_ATTEMPTED"
    }

    private static func safePublicStartError(_ error: Error) -> (domain: String, code: Int, classification: String) {
        let value = error as NSError
        let domain = "PublicCellularAPI"
        return (domain, value.code, "PUBLIC_START_ERROR_\(domain)_\(value.code)")
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
                    line("Application state", value.applicationStateAtReceipt.rawValue)
                    line("State", value.state.rawValue)
                    line("User action required", value.userActionRequired ? "YES" : "NO")
                    line("Start claim obtained", value.startClaimObtained ? "YES" : "NO")
                    line("System start attempted", value.systemStartAttempted ? "YES" : "NO")
                    line("Public start returned", value.publicStartReturnedSuccess.map { $0 ? "SUCCESS" : "ERROR" } ?? "NOT_RETURNED")
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
