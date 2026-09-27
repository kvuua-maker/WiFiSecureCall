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
    func availableCellularServices() throws -> [RemoteCellularServiceOption]
    func prepareCellularService(id: UUID) throws -> RemoteCellularPreparedService
    func startCellularConversation(to e164: String, using service: RemoteCellularPreparedService) async throws
}

enum RemoteCellularLocalError: String, Error {
    case unsupportedOS = "PUBLIC_CELLULAR_API_UNAVAILABLE"
    case invalidNumber = "INVALID_E164"
    case startNotGranted = "START_NOT_GRANTED"
    case ownerLineMappingRequired = "OWNER_LINE_MAPPING_REQUIRED"
    case selectedLineUnavailable = "SELECTED_CELLULAR_SERVICE_UNAVAILABLE"
    case ambiguousLine = "AMBIGUOUS_CELLULAR_SERVICE_ID"
}

struct RemoteCellularServiceOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
}

enum RemoteCellularServiceCatalogState: String, Equatable, Sendable {
    case notChecked = "NOT_CHECKED"
    case loading = "LOADING"
    case emptyWithUnknownCause = "EMPTY_WITH_UNKNOWN_CAUSE"
    case available = "AVAILABLE"
    case unsupported = "UNSUPPORTED"
    case error = "ERROR"
}

enum RemoteCellularDefaultCallingRoleStatus: String, Equatable, Sendable {
    case unknownPublicAPINotExposed = "UNKNOWN_PUBLIC_API_NOT_EXPOSED"
}

@MainActor
struct RemoteCellularPreparedService {
    let id: UUID
    let label: String
    private let operation: @MainActor (String) async throws -> Void

    init(
        id: UUID,
        label: String,
        operation: @escaping @MainActor (String) async throws -> Void
    ) {
        self.id = id
        self.label = label
        self.operation = operation
    }

    func start(_ e164: String) async throws {
        try await operation(e164)
    }
}

final class RemoteCellularLineSelectionStore {
    private let defaults: UserDefaults
    private let keyPrefix = "WiFiSecureCall.remoteCellular.selectedService.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectedServiceID(for accountID: UUID) -> UUID? {
        defaults.string(forKey: key(for: accountID)).flatMap(UUID.init(uuidString:))
    }

    func setSelectedServiceID(_ serviceID: UUID, for accountID: UUID) {
        defaults.set(serviceID.uuidString.lowercased(), forKey: key(for: accountID))
    }

    private func key(for accountID: UUID) -> String {
        keyPrefix + accountID.uuidString.lowercased()
    }
}

@MainActor
final class IOSPublicCellularConversationStarter: CellularConversationStarting {
    func availableCellularServices() throws -> [RemoteCellularServiceOption] {
        guard #available(iOS 26.0, *) else {
            throw RemoteCellularLocalError.unsupportedOS
        }
        return TelephonyConversationManager.sharedInstance.cellularServices.map {
            RemoteCellularServiceOption(id: $0.id, label: $0.label)
        }
    }

    func prepareCellularService(id: UUID) throws -> RemoteCellularPreparedService {
        guard #available(iOS 26.0, *) else {
            throw RemoteCellularLocalError.unsupportedOS
        }
        let matches = TelephonyConversationManager.sharedInstance.cellularServices.filter { $0.id == id }
        guard !matches.isEmpty else { throw RemoteCellularLocalError.selectedLineUnavailable }
        guard matches.count == 1, let selectedService = matches.first else {
            throw RemoteCellularLocalError.ambiguousLine
        }
        return RemoteCellularPreparedService(id: selectedService.id, label: selectedService.label) { number in
            let handle = Handle(type: .phoneNumber, value: number)
            let action = StartCellularConversationAction(handle, cellularService: selectedService)
            try await TelephonyConversationManager.sharedInstance.startCellularConversation(action)
        }
    }

    func startCellularConversation(to e164: String, using service: RemoteCellularPreparedService) async throws {
        guard let number = RemoteCellularControlPolicy.normalizedE164(e164) else {
            throw RemoteCellularLocalError.invalidNumber
        }
        try await service.start(number)
    }
}

@MainActor
final class IOSRemoteCellularControlCoordinator: ObservableObject {
    static let shared = IOSRemoteCellularControlCoordinator()

    @Published private(set) var diagnostic: RemoteCellularControlDiagnostic?
    @Published private(set) var isStarting = false
    @Published var presentationRequested = false
    @Published private(set) var availableCellularServices: [RemoteCellularServiceOption] = []
    @Published private(set) var selectedCellularServiceID: UUID?
    @Published private(set) var selectedCellularServiceLabel: String?
    @Published private(set) var cellularLineSelectionState = "OWNER_LINE_MAPPING_REQUIRED"
    @Published private(set) var explicitCellularServicePassed = false
    @Published private(set) var cellularServiceCatalogState: RemoteCellularServiceCatalogState = .notChecked
    @Published private(set) var cellularServiceCatalogCount = 0
    @Published private(set) var cellularServiceCatalogReadAt: Date?
    @Published private(set) var storedCellularServiceIDPresent = false
    @Published private(set) var storedCellularServiceIDMatchesCatalog: Bool?

    let cellularServiceCatalogReadMethod = "SYNCHRONOUS_PUBLIC_GETTER"
    let defaultCallingRoleStatus: RemoteCellularDefaultCallingRoleStatus = .unknownPublicAPINotExposed

    private let api: any RemoteCellularControlAPI
    private let accountStore: AccountSessionStore
    private let starter: any CellularConversationStarting
    private let lineSelectionStore: RemoteCellularLineSelectionStore
    private var claimMutationIDs: [UUID: UUID] = [:]
    private var startAttemptMutationIDs: [UUID: UUID] = [:]
    private var completionMutationIDs: [UUID: UUID] = [:]
    private var locallyConsumed: Set<UUID> = []

    convenience private init() {
        let runtime = NotificationRuntime.shared
        self.init(
            api: runtime.accountAPI,
            accountStore: runtime.accountStore,
            starter: IOSPublicCellularConversationStarter(),
            lineSelectionStore: RemoteCellularLineSelectionStore()
        )
    }

    init(
        api: any RemoteCellularControlAPI,
        accountStore: AccountSessionStore,
        starter: any CellularConversationStarting,
        lineSelectionStore: RemoteCellularLineSelectionStore = RemoteCellularLineSelectionStore()
    ) {
        self.api = api
        self.accountStore = accountStore
        self.starter = starter
        self.lineSelectionStore = lineSelectionStore
    }

    func refreshCellularLines() {
        cellularServiceCatalogState = .loading
        cellularServiceCatalogCount = 0
        cellularServiceCatalogReadAt = nil
        availableCellularServices = []
        resetSelectionDiagnostics(for: accountStore.activeAccountID)
        do {
            let services = try starter.availableCellularServices()
            availableCellularServices = services
            cellularServiceCatalogCount = services.count
            cellularServiceCatalogReadAt = Date()
            cellularServiceCatalogState = services.isEmpty ? .emptyWithUnknownCause : .available
            applyStoredSelection(accountID: accountStore.activeAccountID, services: services)
        } catch {
            availableCellularServices = []
            cellularServiceCatalogCount = 0
            cellularServiceCatalogReadAt = Date()
            cellularServiceCatalogState = error as? RemoteCellularLocalError == .unsupportedOS
                ? .unsupported
                : .error
            applyCatalogFailure(error, accountID: accountStore.activeAccountID)
        }
    }

    func activeAccountDidChange() {
        refreshCellularLines()
    }

    func selectCellularLine(_ serviceID: UUID) {
        guard let accountID = accountStore.activeAccountID else {
            cellularLineSelectionState = "ACCOUNT_SESSION_REQUIRED"
            return
        }
        let matches = availableCellularServices.filter { $0.id == serviceID }
        guard !matches.isEmpty else {
            cellularLineSelectionState = "SELECTED_CELLULAR_SERVICE_UNAVAILABLE"
            return
        }
        guard matches.count == 1, let selected = matches.first else {
            cellularLineSelectionState = "AMBIGUOUS_CELLULAR_SERVICE_ID"
            return
        }
        lineSelectionStore.setSelectedServiceID(serviceID, for: accountID)
        selectedCellularServiceID = serviceID
        selectedCellularServiceLabel = selected.label
        storedCellularServiceIDPresent = true
        storedCellularServiceIDMatchesCatalog = true
        cellularLineSelectionState = "EXPLICIT_CELLULAR_SERVICE_SELECTED"
    }

    private func resetSelectionDiagnostics(for accountID: UUID?) {
        let storedID = accountID.flatMap(lineSelectionStore.selectedServiceID(for:))
        selectedCellularServiceID = storedID
        selectedCellularServiceLabel = nil
        storedCellularServiceIDPresent = storedID != nil
        storedCellularServiceIDMatchesCatalog = nil
        cellularLineSelectionState = accountID == nil ? "ACCOUNT_SESSION_REQUIRED" : "LOADING"
    }

    private func applyCatalogFailure(_ error: Error, accountID: UUID?) {
        resetSelectionDiagnostics(for: accountID)
        guard accountID != nil else { return }
        cellularLineSelectionState = Self.safeError(error)
    }

    private func applyStoredSelection(accountID: UUID?, services: [RemoteCellularServiceOption]) {
        guard let accountID else {
            selectedCellularServiceID = nil
            selectedCellularServiceLabel = nil
            storedCellularServiceIDPresent = false
            storedCellularServiceIDMatchesCatalog = nil
            cellularLineSelectionState = "ACCOUNT_SESSION_REQUIRED"
            return
        }
        guard let storedID = lineSelectionStore.selectedServiceID(for: accountID) else {
            selectedCellularServiceID = nil
            selectedCellularServiceLabel = nil
            storedCellularServiceIDPresent = false
            storedCellularServiceIDMatchesCatalog = nil
            cellularLineSelectionState = services.isEmpty
                ? RemoteCellularServiceCatalogState.emptyWithUnknownCause.rawValue
                : "OWNER_LINE_MAPPING_REQUIRED"
            return
        }
        selectedCellularServiceID = storedID
        storedCellularServiceIDPresent = true
        let matches = services.filter { $0.id == storedID }
        if matches.count == 1, let selected = matches.first {
            selectedCellularServiceLabel = selected.label
            storedCellularServiceIDMatchesCatalog = true
            cellularLineSelectionState = "EXPLICIT_CELLULAR_SERVICE_SELECTED"
        } else {
            selectedCellularServiceLabel = nil
            storedCellularServiceIDMatchesCatalog = false
            cellularLineSelectionState = matches.isEmpty
                ? "SELECTED_CELLULAR_SERVICE_UNAVAILABLE"
                : "AMBIGUOUS_CELLULAR_SERVICE_ID"
        }
    }

    func receive(
        _ envelope: RemoteCellularControlPushEnvelope,
        context: RemoteCellularReceiptContext,
        applicationState: RemoteCellularApplicationState
    ) async {
        if diagnostic?.requestID != envelope.requestID {
            explicitCellularServicePassed = false
        }
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
                appConfirmationRequired: control.state == .iPhoneActionRequired && !automaticBackgroundAttempt,
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
                sameOwnerAuthorized: true, appConfirmationRequired: false,
                startClaimObtained: false, systemStartAttempted: false,
                publicStartReturnedSuccess: nil, safeResult: "EXPIRED"
            )
            return
        }

        let preparedService: RemoteCellularPreparedService
        do {
            guard let selectedID = lineSelectionStore.selectedServiceID(for: current.accountID) else {
                throw RemoteCellularLocalError.ownerLineMappingRequired
            }
            preparedService = try starter.prepareCellularService(id: selectedID)
            selectedCellularServiceID = preparedService.id
            selectedCellularServiceLabel = preparedService.label
            storedCellularServiceIDPresent = true
            storedCellularServiceIDMatchesCatalog = true
            cellularLineSelectionState = "EXPLICIT_CELLULAR_SERVICE_SELECTED"
        } catch {
            explicitCellularServicePassed = false
            updatePreStartFailure(Self.safeError(error))
            return
        }

        isStarting = true
        locallyConsumed.insert(current.requestID)
        explicitCellularServicePassed = false
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
                appConfirmationRequired: false,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil,
                safeResult: "IPHONE_START_AUTHORIZED"
            )

            let publicStartError: Error?
            do {
                explicitCellularServicePassed = true
                try await starter.startCellularConversation(to: transientNumber, using: preparedService)
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
                appConfirmationRequired: false,
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
                    sameOwnerAuthorized: true, appConfirmationRequired: false,
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
                    sameOwnerAuthorized: true, appConfirmationRequired: false,
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
            appConfirmationRequired: false,
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
            appConfirmationRequired: !attempted,
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
    @ObservedObject var coordinator: IOSRemoteCellularControlCoordinator
    @ObservedObject private var accountStore: AccountSessionStore

    init(
        coordinator: IOSRemoteCellularControlCoordinator = .shared,
        accountStore: AccountSessionStore = NotificationRuntime.shared.accountStore
    ) {
        self.coordinator = coordinator
        _accountStore = ObservedObject(wrappedValue: accountStore)
    }

    var body: some View {
        NavigationView {
            List {
                Section("Outgoing cellular line") {
                    if coordinator.cellularServiceCatalogState == .loading {
                        ProgressView("Reading public cellular services")
                    } else if coordinator.availableCellularServices.isEmpty {
                        Text("No public cellular services currently listed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.availableCellularServices) { service in
                            Button {
                                coordinator.selectCellularLine(service.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(service.label.isEmpty ? "Cellular line" : service.label)
                                        Text(Self.shortID(service.id))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if coordinator.selectedCellularServiceID == service.id {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                        }
                    }
                    line("Catalog state", coordinator.cellularServiceCatalogState.rawValue)
                    line("Public role check", coordinator.defaultCallingRoleStatus.rawValue)
                    line("Catalog read method", coordinator.cellularServiceCatalogReadMethod)
                    line("Catalog read at", coordinator.cellularServiceCatalogReadAt.map(Self.timestamp) ?? "none")
                    line("Cellular services returned", String(coordinator.cellularServiceCatalogCount))
                    line("Stored service ID", coordinator.storedCellularServiceIDPresent ? "PRESENT" : "NONE")
                    line(
                        "Stored ID matches current list",
                        coordinator.storedCellularServiceIDMatchesCatalog.map { $0 ? "YES" : "NO" } ?? "UNKNOWN"
                    )
                    line("Line selection", coordinator.cellularLineSelectionState)
                    line("Selected line", coordinator.selectedCellularServiceLabel ?? "none")
                    line(
                        "Selected service ID",
                        coordinator.selectedCellularServiceID.map(Self.shortID) ?? "none"
                    )
                    Button("Refresh cellular lines") { coordinator.refreshCellularLines() }
                }
                if let value = coordinator.diagnostic {
                    line("Request", value.requestID.uuidString.lowercased())
                    line("Same-owner Watch", value.sameOwnerAuthorized ? "YES" : "NO")
                    line("Request within TTL now", value.expiresAt.map { $0 > Date() } == true ? "YES" : "NO")
                    line("Received", value.receiptContext.rawValue)
                    line("Application state", value.applicationStateAtReceipt.rawValue)
                    line("State", value.state.rawValue)
                    line("App confirmation required", value.appConfirmationRequired ? "YES" : "NO")
                    line("Start claim obtained", value.startClaimObtained ? "YES" : "NO")
                    line("Explicit cellular service passed", coordinator.explicitCellularServicePassed ? "YES" : "NO")
                    line("System start attempted", value.systemStartAttempted ? "YES" : "NO")
                    line("Public start returned", value.publicStartReturnedSuccess.map { $0 ? "SUCCESS" : "ERROR" } ?? "NOT_RETURNED")
                    line("Result", value.safeResult)
                    if value.appConfirmationRequired && value.sameOwnerAuthorized {
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
            .onAppear { coordinator.refreshCellularLines() }
            .onChange(of: accountStore.activeAccountID) { _ in coordinator.activeAccountDidChange() }
        }
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func line(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Text(value).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
#endif
