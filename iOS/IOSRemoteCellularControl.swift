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
final class RemoteCellularNotificationActionExecutionPermit {
    private let deadlineUptimeNanoseconds: UInt64
    private let monotonicNow: () -> UInt64
    private(set) var isClosed = false
    private(set) var publicStartEntered = false

    init(
        budgetNanoseconds: UInt64 = RemoteCellularControlPolicy.notificationActionExecutionBudgetNanoseconds,
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.monotonicNow = monotonicNow
        let now = monotonicNow()
        let (deadline, overflow) = now.addingReportingOverflow(budgetNanoseconds)
        deadlineUptimeNanoseconds = overflow ? UInt64.max : deadline
    }

    func allowsProgress() -> Bool {
        guard !isClosed, !publicStartEntered else { return false }
        guard monotonicNow() < deadlineUptimeNanoseconds else {
            isClosed = true
            return false
        }
        return true
    }

    func authorizePublicStart() -> Bool {
        guard allowsProgress() else { return false }
        publicStartEntered = true
        return true
    }

    func close() {
        isClosed = true
    }
}

@MainActor
protocol CellularConversationStarting: AnyObject {
    func availableCellularServices() throws -> [RemoteCellularServiceOption]
    func prepareCellularService(id: UUID) throws -> RemoteCellularPreparedStart
    func prepareSystemManagedStart() throws -> RemoteCellularPreparedStart
    func startCellularConversation(to e164: String, using preparedStart: RemoteCellularPreparedStart) async throws
}

enum RemoteCellularLocalError: String, Error {
    case unsupportedOS = "PUBLIC_CELLULAR_API_UNAVAILABLE"
    case invalidNumber = "INVALID_E164"
    case startNotGranted = "START_NOT_GRANTED"
    case ownerLineMappingRequired = "OWNER_LINE_MAPPING_REQUIRED"
    case selectedLineUnavailable = "SELECTED_CELLULAR_SERVICE_UNAVAILABLE"
    case ambiguousLine = "AMBIGUOUS_CELLULAR_SERVICE_ID"
    case startModeMismatch = "CELLULAR_START_MODE_MISMATCH"
    case claimAcknowledgementUnavailable = "SERVER_CLAIM_ACK_UNAVAILABLE"
    case startAttemptAcknowledgementUnavailable = "SERVER_START_ATTEMPT_ACK_UNAVAILABLE"
    case resultAcknowledgementUnavailable = "SERVER_RESULT_ACK_UNAVAILABLE"
    case notificationActionExecutionClosed = "NOTIFICATION_ACTION_EXECUTION_BUDGET_EXPIRED"
}

struct RemoteCellularServiceOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
}

enum RemoteCellularExecutionMode: String, Equatable, Sendable {
    case strictExplicitSIM = "STRICT_EXPLICIT_SIM"
    case systemManagedDiagnostic = "SYSTEM_MANAGED_DIAGNOSTIC"
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

struct RemoteCellularRequestKey: Hashable, Sendable {
    let requestID: UUID
    let accountID: UUID
}

enum RemoteCellularManualActionAvailability: String, Equatable, Sendable {
    case ready = "READY_FOR_IPHONE_ACTION"
    case noRequest = "NO_REQUEST"
    case requestReplaced = "REQUEST_REPLACED"
    case unauthorized = "REQUEST_UNAUTHORIZED"
    case expired = "REQUEST_EXPIRED"
    case notAwaitingAction = "REQUEST_NOT_AWAITING_IPHONE_ACTION"
    case inProgress = "START_IN_PROGRESS"
    case completed = "START_COMPLETED"
    case terminalError = "START_TERMINAL_ERROR"
    case cancelled = "REQUEST_CANCELLED"
    case anotherRequestInProgress = "ANOTHER_REQUEST_IN_PROGRESS"

    var allowsStart: Bool { self == .ready }
    var showsProgress: Bool { self == .inProgress }
}

private struct RemoteCellularMutationState {
    var ordinaryReceiptID: UUID? = nil
    var notificationActionReceiptID: UUID? = nil
    var claimID: UUID? = nil
    var startAttemptID: UUID? = nil
    var completionID: UUID? = nil
    var consumed = false
    var lastTouched: Date
    var retainUntil: Date
}

private enum RemoteCellularReceiveOperation: Hashable {
    case ordinary
    case notificationAction
}

private struct RemoteCellularReceiveGenerationKey: Hashable {
    let request: RemoteCellularRequestKey
    let operation: RemoteCellularReceiveOperation
}

@MainActor
struct RemoteCellularPreparedStart {
    let mode: RemoteCellularExecutionMode
    let explicitServiceID: UUID?
    let explicitServiceLabel: String?
    private let operation: @MainActor (String) async throws -> Void

    init(
        mode: RemoteCellularExecutionMode,
        explicitServiceID: UUID? = nil,
        explicitServiceLabel: String? = nil,
        operation: @escaping @MainActor (String) async throws -> Void
    ) {
        self.mode = mode
        self.explicitServiceID = explicitServiceID
        self.explicitServiceLabel = explicitServiceLabel
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

final class RemoteCellularExecutionModeStore {
    private let defaults: UserDefaults
    private let keyPrefix = "WiFiSecureCall.remoteCellular.executionMode.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func mode(for accountID: UUID) -> RemoteCellularExecutionMode {
        guard let rawValue = defaults.string(forKey: key(for: accountID)),
              let mode = RemoteCellularExecutionMode(rawValue: rawValue) else {
            return .strictExplicitSIM
        }
        return mode
    }

    func setMode(_ mode: RemoteCellularExecutionMode, for accountID: UUID) {
        defaults.set(mode.rawValue, forKey: key(for: accountID))
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

    func prepareCellularService(id: UUID) throws -> RemoteCellularPreparedStart {
        guard #available(iOS 26.0, *) else {
            throw RemoteCellularLocalError.unsupportedOS
        }
        let matches = TelephonyConversationManager.sharedInstance.cellularServices.filter { $0.id == id }
        guard !matches.isEmpty else { throw RemoteCellularLocalError.selectedLineUnavailable }
        guard matches.count == 1, let selectedService = matches.first else {
            throw RemoteCellularLocalError.ambiguousLine
        }
        return RemoteCellularPreparedStart(
            mode: .strictExplicitSIM,
            explicitServiceID: selectedService.id,
            explicitServiceLabel: selectedService.label
        ) { number in
            let handle = Handle(type: .phoneNumber, value: number)
            let action = StartCellularConversationAction(handle, cellularService: selectedService)
            try await TelephonyConversationManager.sharedInstance.startCellularConversation(action)
        }
    }

    func prepareSystemManagedStart() throws -> RemoteCellularPreparedStart {
        guard #available(iOS 26.0, *) else {
            throw RemoteCellularLocalError.unsupportedOS
        }
        return RemoteCellularPreparedStart(mode: .systemManagedDiagnostic) { number in
            let handle = Handle(type: .phoneNumber, value: number)
            let action = StartCellularConversationAction(handle)
            try await TelephonyConversationManager.sharedInstance.startCellularConversation(action)
        }
    }

    func startCellularConversation(to e164: String, using preparedStart: RemoteCellularPreparedStart) async throws {
        guard let number = RemoteCellularControlPolicy.normalizedE164(e164) else {
            throw RemoteCellularLocalError.invalidNumber
        }
        try await preparedStart.start(number)
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
    @Published private(set) var systemManagedPublicStartUsed = false
    @Published private(set) var executionMode: RemoteCellularExecutionMode = .strictExplicitSIM
    @Published private(set) var executionModeSnapshot: RemoteCellularExecutionMode?
    @Published private(set) var cellularServiceCatalogState: RemoteCellularServiceCatalogState = .notChecked
    @Published private(set) var cellularServiceCatalogCount = 0
    @Published private(set) var cellularServiceCatalogReadAt: Date?
    @Published private(set) var storedCellularServiceIDPresent = false
    @Published private(set) var storedCellularServiceIDMatchesCatalog: Bool?
    @Published private(set) var manualActionResult = RemoteCellularManualActionAvailability.noRequest.rawValue
    @Published private(set) var publicStarterEntered = false

    let cellularServiceCatalogReadMethod = "SYNCHRONOUS_PUBLIC_GETTER"
    let defaultCallingRoleStatus: RemoteCellularDefaultCallingRoleStatus = .unknownPublicAPINotExposed

    private let api: any RemoteCellularControlAPI
    private let accountStore: AccountSessionStore
    private let starter: any CellularConversationStarting
    private let lineSelectionStore: RemoteCellularLineSelectionStore
    private let executionModeStore: RemoteCellularExecutionModeStore
    private var mutationStates: [RemoteCellularRequestKey: RemoteCellularMutationState] = [:]
    private var displayedRequestKey: RemoteCellularRequestKey?
    private var displayedRequestCreatedAt: Date?
    private var activeStartKey: RemoteCellularRequestKey?
    private var receiveGeneration: UInt64 = 0
    private var latestReceiveGenerationByKey: [RemoteCellularReceiveGenerationKey: UInt64] = [:]
    private let mutationRetryDelaysNanoseconds: [UInt64]
    private let maximumRetainedRequestStates: Int

    var temporaryRequestStateCount: Int { mutationStates.count + latestReceiveGenerationByKey.count }

    convenience private init() {
        let runtime = NotificationRuntime.shared
        self.init(
            api: runtime.accountAPI,
            accountStore: runtime.accountStore,
            starter: IOSPublicCellularConversationStarter(),
            lineSelectionStore: RemoteCellularLineSelectionStore(),
            executionModeStore: RemoteCellularExecutionModeStore()
        )
    }

    init(
        api: any RemoteCellularControlAPI,
        accountStore: AccountSessionStore,
        starter: any CellularConversationStarting,
        lineSelectionStore: RemoteCellularLineSelectionStore = RemoteCellularLineSelectionStore(),
        executionModeStore: RemoteCellularExecutionModeStore = RemoteCellularExecutionModeStore(),
        mutationRetryDelaysNanoseconds: [UInt64] = [0, 100_000_000, 250_000_000],
        maximumRetainedRequestStates: Int = 64
    ) {
        self.api = api
        self.accountStore = accountStore
        self.starter = starter
        self.lineSelectionStore = lineSelectionStore
        self.executionModeStore = executionModeStore
        self.mutationRetryDelaysNanoseconds = mutationRetryDelaysNanoseconds.isEmpty ? [0] : mutationRetryDelaysNanoseconds
        self.maximumRetainedRequestStates = max(8, maximumRetainedRequestStates)
        executionMode = accountStore.activeAccountID.map(executionModeStore.mode(for:)) ?? .strictExplicitSIM
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
        executionMode = accountStore.activeAccountID.map(executionModeStore.mode(for:)) ?? .strictExplicitSIM
        refreshCellularLines()
    }

    func useStrictExplicitSIMMode() {
        guard let accountID = accountStore.activeAccountID else { return }
        executionModeStore.setMode(.strictExplicitSIM, for: accountID)
        executionMode = .strictExplicitSIM
    }

    func confirmSystemManagedDiagnosticOptIn() {
        guard let accountID = accountStore.activeAccountID else { return }
        executionModeStore.setMode(.systemManagedDiagnostic, for: accountID)
        executionMode = .systemManagedDiagnostic
    }

    func requestExecutionMode(accountID: UUID) -> RemoteCellularExecutionMode {
        executionModeStore.mode(for: accountID)
    }

    func requestAccountLabel(accountID: UUID) -> String {
        let shortID = String(accountID.uuidString.lowercased().prefix(8))
        guard let account = accountStore.accounts.first(where: { $0.accountID == accountID }) else {
            return "Невідомий локальний акаунт [\(shortID)]"
        }
        return "\(account.displayLabel) [\(shortID)]"
    }

    func confirmSystemManagedDiagnosticOptIn(requestID: UUID, accountID: UUID) {
        let key = RemoteCellularRequestKey(requestID: requestID, accountID: accountID)
        switch manualStartAvailability(requestID: requestID, accountID: accountID) {
        case .ready:
            executionModeStore.setMode(.systemManagedDiagnostic, for: accountID)
            if accountStore.activeAccountID == accountID {
                executionMode = .systemManagedDiagnostic
            }
            if displayedRequestKey == key {
                manualActionResult = "SYSTEM_MANAGED_MODE_ENABLED_FOR_REQUEST"
            }
        case let availability:
            manualActionResult = availability.rawValue
        }
    }

    func manualStartAvailability(
        requestID: UUID,
        accountID: UUID,
        now: Date = Date()
    ) -> RemoteCellularManualActionAvailability {
        let key = RemoteCellularRequestKey(requestID: requestID, accountID: accountID)
        guard let current = diagnostic else { return .noRequest }
        guard displayedRequestKey == key,
              current.requestID == requestID,
              current.accountID == accountID else { return .requestReplaced }
        guard current.sameOwnerAuthorized,
              accountStore.accounts.contains(where: { $0.accountID == accountID }) else { return .unauthorized }
        switch current.state {
        case .systemStartAccepted:
            return .completed
        case .publicStartError, .failedSafe:
            return .terminalError
        case .cancelled:
            return .cancelled
        case .expired:
            return .expired
        default:
            break
        }
        guard current.expiresAt.map({ $0 > now }) == true else { return .expired }
        if activeStartKey == key { return .inProgress }
        if isLocallyConsumed(key) { return .terminalError }
        if activeStartKey != nil { return .anotherRequestInProgress }
        guard current.state == .iPhoneActionRequired,
              current.appConfirmationRequired else { return .notAwaitingAction }
        return .ready
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
        guard envelope.event == .silentBackground,
              context != .notificationAction else { return }
        await processReceipt(
            envelope,
            context: context,
            applicationState: applicationState,
            operation: .ordinary
        )
    }

    func receiveNotificationAction(
        _ envelope: RemoteCellularControlPushEnvelope,
        applicationState: RemoteCellularApplicationState,
        executionPermit suppliedPermit: RemoteCellularNotificationActionExecutionPermit? = nil
    ) async {
        guard envelope.event == .notificationAction else { return }
        let executionPermit = suppliedPermit ?? RemoteCellularNotificationActionExecutionPermit()
        await processReceipt(
            envelope,
            context: .notificationAction,
            applicationState: applicationState,
            operation: .notificationAction,
            executionPermit: executionPermit
        )
    }

    private func processReceipt(
        _ envelope: RemoteCellularControlPushEnvelope,
        context: RemoteCellularReceiptContext,
        applicationState: RemoteCellularApplicationState,
        operation: RemoteCellularReceiveOperation,
        executionPermit: RemoteCellularNotificationActionExecutionPermit? = nil
    ) async {
        let key = RemoteCellularRequestKey(requestID: envelope.requestID, accountID: envelope.accountID)
        let automaticBackgroundAttempt = operation == .ordinary && (context == .background || context == .inactive)
        let shouldPresent = operation == .ordinary && !automaticBackgroundAttempt
        pruneTemporaryState()

        guard actionExecutionMayProceed(operation: operation, permit: executionPermit) else {
            closeActionExecution(key: key)
            return
        }

        if activeStartKey == key || isLocallyConsumed(key) {
            if displayedRequestKey == key {
                if activeStartKey == key {
                    manualActionResult = RemoteCellularManualActionAvailability.inProgress.rawValue
                } else if let diagnostic,
                          diagnostic.state == .systemStartAccepted || diagnostic.state == .publicStartError ||
                            diagnostic.state == .cancelled || diagnostic.state == .expired ||
                            diagnostic.state == .failedSafe {
                    manualActionResult = diagnostic.safeResult
                } else {
                    manualActionResult = RemoteCellularManualActionAvailability.terminalError.rawValue
                }
            }
            if operation == .ordinary { presentationRequested = shouldPresent }
            return
        }

        receiveGeneration &+= 1
        let generation = receiveGeneration
        let generationKey = RemoteCellularReceiveGenerationKey(request: key, operation: operation)
        latestReceiveGenerationByKey[generationKey] = generation
        defer {
            if latestReceiveGenerationByKey[generationKey] == generation {
                latestReceiveGenerationByKey.removeValue(forKey: generationKey)
            }
        }
        if displayedRequestKey == nil || displayedRequestKey == key {
            manualActionResult = "RECEIVING_REQUEST"
        }

        guard accountStore.accounts.contains(where: { $0.accountID == envelope.accountID }) else {
            guard displayedRequestKey == nil || displayedRequestKey == key else { return }
            activateDisplayedRequest(key, createdAt: nil)
            setVisibleDiagnostic(Self.safeDiagnostic(
                envelope: envelope,
                context: context,
                applicationState: applicationState,
                state: .failedSafe,
                authorized: false,
                attempted: false,
                result: "LOCAL_ACCOUNT_NOT_FOUND"
            ), for: key, manualResult: "LOCAL_ACCOUNT_NOT_FOUND")
            if operation == .ordinary { presentationRequested = shouldPresent }
            return
        }
        do {
            let receiptMutationKind: MutationKind = operation == .notificationAction
                ? .notificationActionReceipt
                : .ordinaryReceipt
            let receiptMutationID = mutationID(
                for: receiptMutationKind,
                key: key,
                expiresAt: diagnostic?.requestID == key.requestID ? diagnostic?.expiresAt : nil
            )
            guard actionExecutionMayProceed(operation: operation, permit: executionPermit) else {
                closeActionExecution(key: key)
                return
            }
            let control = try await api.receiveRemoteCellularControl(
                accountID: envelope.accountID,
                requestID: envelope.requestID,
                mutationID: receiptMutationID,
                context: context,
                applicationState: applicationState
            )
            guard actionExecutionMayProceed(operation: operation, permit: executionPermit) else {
                closeActionExecution(key: key)
                return
            }
            guard isLatestReceive(generation, key: generationKey) else { return }
            guard control.requestID == envelope.requestID,
                  control.effectiveDeliveryMode == envelope.event.deliveryMode,
                  control.expiresAt > Date(),
                  control.sameOwnerAuthorized,
                  control.sourcePlatform == "watchOS",
                  control.targetPlatform == "iOS" else {
                throw RemoteCellularLocalError.startNotGranted
            }
            if operation == .notificationAction {
                guard control.receiptContext == .notificationAction,
                      control.notificationActionReceivedAt != nil else {
                    throw RemoteCellularLocalError.startNotGranted
                }
            }
            let shouldUpdateDisplay = shouldAcceptReceivedRequest(key, createdAt: control.createdAt)
            if operation == .ordinary {
                guard shouldUpdateDisplay else { return }
            }
            if operation == .ordinary,
               displayedRequestKey == key,
               diagnostic?.receiptContext == .notificationAction {
                return
            }
            let value = RemoteCellularControlDiagnostic(
                requestID: control.requestID,
                accountID: envelope.accountID,
                expiresAt: control.expiresAt,
                state: control.state,
                deliveryMode: control.effectiveDeliveryMode,
                receiptContext: context,
                applicationStateAtReceipt: control.applicationState ?? applicationState,
                sameOwnerAuthorized: true,
                appConfirmationRequired: control.state == .iPhoneActionRequired && !automaticBackgroundAttempt,
                startClaimObtained: Self.hasStartClaim(control.state),
                systemStartAttempted: Self.hasStartAttempt(control.state),
                publicStartReturnedSuccess: Self.publicStartSuccess(control.state),
                safeResult: Self.safeReceiptResult(state: control.state, context: context),
                ordinaryReceivedAt: control.ordinaryReceivedAt,
                notificationActionReceivedAt: control.notificationActionReceivedAt
            )
            let manualResult = value.appConfirmationRequired
                ? RemoteCellularManualActionAvailability.ready.rawValue
                : value.safeResult
            if shouldUpdateDisplay {
                activateDisplayedRequest(key, createdAt: control.createdAt)
                setVisibleDiagnostic(value, for: key, manualResult: manualResult)
            }
            if operation == .ordinary { presentationRequested = shouldPresent }
            if automaticBackgroundAttempt && control.state == .iPhoneBackgroundReceived {
                await attemptStart(value, origin: .automatic)
            } else if operation == .notificationAction && control.state == .iPhoneNotificationActionReceived {
                guard actionExecutionMayProceed(operation: operation, permit: executionPermit) else {
                    closeActionExecution(key: key)
                    return
                }
                await attemptStart(value, origin: .notificationAction, executionPermit: executionPermit)
            }
        } catch {
            guard actionExecutionMayProceed(operation: operation, permit: executionPermit) else {
                closeActionExecution(key: key)
                return
            }
            guard isLatestReceive(generation, key: generationKey) else { return }
            guard displayedRequestKey == nil || displayedRequestKey == key else { return }
            activateDisplayedRequest(key, createdAt: nil)
            let result = Self.safeError(error)
            setVisibleDiagnostic(Self.safeDiagnostic(
                envelope: envelope,
                context: context,
                applicationState: applicationState,
                state: .failedSafe,
                authorized: false,
                attempted: false,
                result: result
            ), for: key, manualResult: result)
            if operation == .ordinary { presentationRequested = shouldPresent }
        }
    }

    func startPendingControl() async {
        guard let current = diagnostic else {
            manualActionResult = RemoteCellularManualActionAvailability.noRequest.rawValue
            return
        }
        await startPendingControl(requestID: current.requestID, accountID: current.accountID)
    }

    func startPendingControl(requestID: UUID, accountID: UUID) async {
        let availability = manualStartAvailability(requestID: requestID, accountID: accountID)
        guard availability == .ready, let current = diagnostic else {
            manualActionResult = availability.rawValue
            if availability == .expired,
               let current = diagnostic,
               current.requestID == requestID,
               current.accountID == accountID {
                expireVisibleRequest(current)
            }
            return
        }
        manualActionResult = "IPHONE_ACTION_ACCEPTED"
        await attemptStart(current, origin: .manual)
    }

    private enum StartOrigin: Equatable { case automatic, manual, notificationAction }

    private func attemptStart(
        _ current: RemoteCellularControlDiagnostic,
        origin: StartOrigin,
        executionPermit: RemoteCellularNotificationActionExecutionPermit? = nil
    ) async {
        let key = RemoteCellularRequestKey(requestID: current.requestID, accountID: current.accountID)
        guard actionStartMayProceed(origin: origin, permit: executionPermit) else {
            closeActionExecution(key: key)
            return
        }
        guard current.deliveryMode != .notificationAction ||
                (origin == .notificationAction && current.receiptContext == .notificationAction && current.state == .iPhoneNotificationActionReceived),
              current.deliveryMode != .silentBackground || origin != .notificationAction else {
            updatePreparationFailure("DELIVERY_MODE_PROVENANCE_MISMATCH", current: current, key: key, origin: origin)
            return
        }
        guard activeStartKey == nil else {
            if origin == .notificationAction, activeStartKey != key {
                markLocallyConsumed(key, expiresAt: current.expiresAt)
            }
            if displayedRequestKey == key {
                manualActionResult = activeStartKey == key
                    ? RemoteCellularManualActionAvailability.inProgress.rawValue
                    : RemoteCellularManualActionAvailability.anotherRequestInProgress.rawValue
            }
            return
        }
        guard !isLocallyConsumed(key) else {
            if displayedRequestKey == key {
                manualActionResult = RemoteCellularManualActionAvailability.terminalError.rawValue
            }
            return
        }
        guard current.expiresAt.map({ $0 > Date() }) == true else {
            expireVisibleRequest(current)
            return
        }
        guard accountStore.accounts.contains(where: { $0.accountID == current.accountID }) else {
            updatePreparationFailure("LOCAL_ACCOUNT_NOT_FOUND", current: current, key: key, origin: origin)
            return
        }

        let modeSnapshot = executionModeStore.mode(for: current.accountID)
        if displayedRequestKey == key { executionModeSnapshot = modeSnapshot }
        let preparedStart: RemoteCellularPreparedStart
        do {
            switch modeSnapshot {
            case .strictExplicitSIM:
                guard let selectedID = lineSelectionStore.selectedServiceID(for: current.accountID) else {
                    throw RemoteCellularLocalError.ownerLineMappingRequired
                }
                preparedStart = try starter.prepareCellularService(id: selectedID)
                guard preparedStart.mode == .strictExplicitSIM,
                      preparedStart.explicitServiceID == selectedID else {
                    throw RemoteCellularLocalError.startModeMismatch
                }
                if displayedRequestKey == key {
                    selectedCellularServiceID = preparedStart.explicitServiceID
                    selectedCellularServiceLabel = preparedStart.explicitServiceLabel
                    storedCellularServiceIDPresent = true
                    storedCellularServiceIDMatchesCatalog = true
                    cellularLineSelectionState = "EXPLICIT_CELLULAR_SERVICE_SELECTED"
                }
            case .systemManagedDiagnostic:
                preparedStart = try starter.prepareSystemManagedStart()
                guard preparedStart.mode == .systemManagedDiagnostic,
                      preparedStart.explicitServiceID == nil else {
                    throw RemoteCellularLocalError.startModeMismatch
                }
            }
        } catch {
            if displayedRequestKey == key {
                explicitCellularServicePassed = false
                systemManagedPublicStartUsed = false
            }
            updatePreparationFailure(Self.safeError(error), current: current, key: key, origin: origin)
            return
        }

        guard actionStartMayProceed(origin: origin, permit: executionPermit) else {
            closeActionExecution(key: key)
            return
        }

        isStarting = true
        activeStartKey = key
        markLocallyConsumed(key, expiresAt: current.expiresAt)
        if displayedRequestKey == key {
            explicitCellularServicePassed = false
            systemManagedPublicStartUsed = false
            manualActionResult = "START_IN_PROGRESS"
        }
        defer {
            if activeStartKey == key { activeStartKey = nil }
            isStarting = activeStartKey != nil
            pruneTemporaryState()
        }

        let claimID = mutationID(for: .claim, key: key, expiresAt: current.expiresAt)
        var transientNumber: String?
        do {
            var grant = try await retryingAcknowledgement(while: {
                self.actionStartMayProceed(origin: origin, permit: executionPermit)
            }) {
                try await self.api.claimRemoteCellularControlStart(
                    accountID: current.accountID,
                    requestID: current.requestID,
                    mutationID: claimID
                )
            }
            guard actionStartMayProceed(origin: origin, permit: executionPermit) else {
                grant.phoneNumber?.removeAll(keepingCapacity: false)
                grant.phoneNumber = nil
                closeActionExecution(key: key)
                return
            }
            if grant.state == .iPhoneStartAuthorized && !grant.startGranted {
                throw RemoteCellularLocalError.claimAcknowledgementUnavailable
            }
            guard grant.requestID == current.requestID,
                  grant.control.effectiveDeliveryMode == current.deliveryMode,
                  grant.expiresAt > Date(),
                  grant.sameOwnerAuthorized,
                  grant.sourcePlatform == "watchOS",
                  grant.targetPlatform == "iOS",
                  grant.startGranted, let grantedNumber = grant.phoneNumber,
                  RemoteCellularControlPolicy.normalizedE164(grantedNumber) != nil else {
                throw RemoteCellularLocalError.startNotGranted
            }
            transientNumber = grantedNumber
            grant.phoneNumber = nil
            setVisibleDiagnostic(Self.replacingDiagnostic(
                current,
                state: .iPhoneStartAuthorized,
                appConfirmationRequired: false,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil,
                safeResult: "IPHONE_START_AUTHORIZED"
            ), for: key, manualResult: "START_CLAIM_OBTAINED")
        } catch {
            transientNumber?.removeAll(keepingCapacity: false)
            transientNumber = nil
            guard actionStartMayProceed(origin: origin, permit: executionPermit) else {
                closeActionExecution(key: key)
                return
            }
            updateClaimFailure(Self.safeError(error), current: current, key: key)
            return
        }

        guard accountStore.accounts.contains(where: { $0.accountID == current.accountID }),
              current.expiresAt.map({ $0 > Date() }) == true else {
            transientNumber?.removeAll(keepingCapacity: false)
            transientNumber = nil
            updateAcknowledgementFailure(
                "REQUEST_INVALID_AFTER_CLAIM",
                current: current,
                key: key,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil
            )
            return
        }

        guard actionStartMayProceed(origin: origin, permit: executionPermit) else {
            transientNumber?.removeAll(keepingCapacity: false)
            transientNumber = nil
            closeActionExecution(key: key)
            return
        }

        let attemptID = mutationID(for: .startAttempt, key: key, expiresAt: current.expiresAt)
        do {
            let attemptedView = try await retryingAcknowledgement(while: {
                self.actionStartMayProceed(origin: origin, permit: executionPermit)
            }) {
                try await self.api.markRemoteCellularControlStartAttempted(
                    accountID: current.accountID,
                    requestID: current.requestID,
                    mutationID: attemptID
                )
            }
            guard actionStartMayProceed(origin: origin, permit: executionPermit) else {
                transientNumber?.removeAll(keepingCapacity: false)
                transientNumber = nil
                closeActionExecution(key: key)
                return
            }
            guard attemptedView.requestID == current.requestID,
                  attemptedView.effectiveDeliveryMode == current.deliveryMode,
                  attemptedView.sameOwnerAuthorized,
                  attemptedView.state == Self.attemptedState(for: current.receiptContext) else {
                throw RemoteCellularLocalError.startAttemptAcknowledgementUnavailable
            }
            setVisibleDiagnostic(Self.replacingDiagnostic(
                current,
                state: attemptedView.state,
                appConfirmationRequired: false,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil,
                safeResult: "SERVER_START_ATTEMPT_ACKNOWLEDGED"
            ), for: key, manualResult: "SERVER_START_ATTEMPT_ACKNOWLEDGED")
        } catch {
            transientNumber?.removeAll(keepingCapacity: false)
            transientNumber = nil
            guard actionStartMayProceed(origin: origin, permit: executionPermit) else {
                closeActionExecution(key: key)
                return
            }
            updateAcknowledgementFailure(
                Self.safeError(error),
                current: current,
                key: key,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil
            )
            return
        }

        guard accountStore.accounts.contains(where: { $0.accountID == current.accountID }),
              current.expiresAt.map({ $0 > Date() }) == true else {
            transientNumber?.removeAll(keepingCapacity: false)
            transientNumber = nil
            updateAcknowledgementFailure(
                "REQUEST_INVALID_BEFORE_PUBLIC_START",
                current: current,
                key: key,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil
            )
            return
        }

        guard var number = transientNumber else {
            updateAcknowledgementFailure(
                RemoteCellularLocalError.claimAcknowledgementUnavailable.rawValue,
                current: current,
                key: key,
                startClaimObtained: true,
                systemStartAttempted: false,
                publicStartReturnedSuccess: nil
            )
            return
        }
        if origin == .notificationAction {
            guard !Self.currentTaskIsCancelled,
                  let executionPermit,
                  executionPermit.authorizePublicStart() else {
                number.removeAll(keepingCapacity: false)
                transientNumber?.removeAll(keepingCapacity: false)
                transientNumber = nil
                closeActionExecution(key: key)
                return
            }
        }
        if displayedRequestKey == key {
            explicitCellularServicePassed = modeSnapshot == .strictExplicitSIM
            systemManagedPublicStartUsed = modeSnapshot == .systemManagedDiagnostic
            publicStarterEntered = true
            setVisibleDiagnostic(Self.replacingDiagnostic(
                current,
                state: Self.attemptedState(for: current.receiptContext),
                appConfirmationRequired: false,
                startClaimObtained: true,
                systemStartAttempted: true,
                publicStartReturnedSuccess: nil,
                safeResult: "PUBLIC_STARTER_ENTERED"
            ), for: key, manualResult: "PUBLIC_STARTER_ENTERED")
        }

        let publicStartError: Error?
        do {
            try await starter.startCellularConversation(to: number, using: preparedStart)
            publicStartError = nil
        } catch {
            publicStartError = error
        }
        number.removeAll(keepingCapacity: false)
        transientNumber?.removeAll(keepingCapacity: false)
        transientNumber = nil

        let completionID = mutationID(for: .completion, key: key, expiresAt: current.expiresAt)
        let result: RemoteCellularStartResult = publicStartError == nil ? .accepted : .error
        let metadata = publicStartError.map(Self.safePublicStartError)
        do {
            if displayedRequestKey == key {
                manualActionResult = "SERVER_RESULT_ACK_PENDING"
            }
            let completedView = try await retryingAcknowledgement {
                try await self.api.completeRemoteCellularControlStart(
                    accountID: current.accountID,
                    requestID: current.requestID,
                    mutationID: completionID,
                    result: result,
                    errorDomain: metadata?.domain,
                    errorCode: metadata?.code
                )
            }
            let expectedState: RemoteCellularControlState = result == .accepted ? .systemStartAccepted : .publicStartError
            guard completedView.requestID == current.requestID,
                  completedView.effectiveDeliveryMode == current.deliveryMode,
                  completedView.sameOwnerAuthorized,
                  completedView.state == expectedState else {
                throw RemoteCellularLocalError.resultAcknowledgementUnavailable
            }
            if result == .accepted {
                setVisibleDiagnostic(Self.replacingDiagnostic(
                    current,
                    state: .systemStartAccepted, receiptContext: current.receiptContext,
                    appConfirmationRequired: false,
                    startClaimObtained: true, systemStartAttempted: true,
                    publicStartReturnedSuccess: true, safeResult: "SYSTEM_START_ACCEPTED"
                ), for: key, manualResult: "SYSTEM_START_ACCEPTED")
            } else if let metadata {
                setVisibleDiagnostic(Self.replacingDiagnostic(
                    current,
                    state: .publicStartError,
                    appConfirmationRequired: false,
                    startClaimObtained: true, systemStartAttempted: true,
                    publicStartReturnedSuccess: false, safeResult: metadata.classification
                ), for: key, manualResult: metadata.classification)
            }
        } catch {
            let suffix = result == .accepted ? "SUCCESS" : "ERROR"
            updateAcknowledgementFailure(
                "SERVER_RESULT_ACK_FAILED_AFTER_PUBLIC_START_\(suffix)",
                current: current,
                key: key,
                startClaimObtained: true,
                systemStartAttempted: true,
                publicStartReturnedSuccess: result == .accepted
            )
        }
    }

    func dismissPresentation() {
        presentationRequested = false
    }

    private func updatePreparationFailure(
        _ result: String,
        current: RemoteCellularControlDiagnostic,
        key: RemoteCellularRequestKey,
        origin: StartOrigin
    ) {
        let remainsManual = origin == .manual && current.state == .iPhoneActionRequired
        let value = Self.replacingDiagnostic(
            current,
            state: remainsManual ? .iPhoneActionRequired : .failedSafe,
            appConfirmationRequired: remainsManual,
            startClaimObtained: false,
            systemStartAttempted: false,
            publicStartReturnedSuccess: nil,
            safeResult: result
        )
        setVisibleDiagnostic(value, for: key, manualResult: result)
    }

    private func updateClaimFailure(
        _ result: String,
        current: RemoteCellularControlDiagnostic,
        key: RemoteCellularRequestKey
    ) {
        let value = Self.replacingDiagnostic(
            current,
            state: .failedSafe,
            appConfirmationRequired: false,
            startClaimObtained: false,
            systemStartAttempted: false,
            publicStartReturnedSuccess: nil,
            safeResult: result
        )
        setVisibleDiagnostic(value, for: key, manualResult: result)
    }

    private func updateAcknowledgementFailure(
        _ result: String,
        current: RemoteCellularControlDiagnostic,
        key: RemoteCellularRequestKey,
        startClaimObtained: Bool,
        systemStartAttempted: Bool,
        publicStartReturnedSuccess: Bool?
    ) {
        let value = Self.replacingDiagnostic(
            current,
            state: .failedSafe,
            appConfirmationRequired: false,
            startClaimObtained: startClaimObtained,
            systemStartAttempted: systemStartAttempted,
            publicStartReturnedSuccess: publicStartReturnedSuccess,
            safeResult: result
        )
        setVisibleDiagnostic(value, for: key, manualResult: result)
    }

    private enum MutationKind {
        case ordinaryReceipt
        case notificationActionReceipt
        case claim
        case startAttempt
        case completion
    }

    private func mutationID(
        for kind: MutationKind,
        key: RemoteCellularRequestKey,
        expiresAt: Date?
    ) -> UUID {
        pruneTemporaryState()
        let now = Date()
        let retainUntil = max(expiresAt ?? now.addingTimeInterval(RemoteCellularControlPolicy.requestTTL), now)
            .addingTimeInterval(60)
        var state = mutationStates[key] ?? RemoteCellularMutationState(
            lastTouched: now,
            retainUntil: retainUntil
        )
        let value: UUID
        switch kind {
        case .ordinaryReceipt:
            value = state.ordinaryReceiptID ?? UUID()
            state.ordinaryReceiptID = value
        case .notificationActionReceipt:
            value = state.notificationActionReceiptID ?? UUID()
            state.notificationActionReceiptID = value
        case .claim:
            value = state.claimID ?? UUID()
            state.claimID = value
        case .startAttempt:
            value = state.startAttemptID ?? UUID()
            state.startAttemptID = value
        case .completion:
            value = state.completionID ?? UUID()
            state.completionID = value
        }
        state.lastTouched = now
        state.retainUntil = max(state.retainUntil, retainUntil)
        mutationStates[key] = state
        pruneTemporaryState()
        return value
    }

    private func markLocallyConsumed(_ key: RemoteCellularRequestKey, expiresAt: Date?) {
        let now = Date()
        let retainUntil = max(expiresAt ?? now.addingTimeInterval(RemoteCellularControlPolicy.requestTTL), now)
            .addingTimeInterval(60)
        var state = mutationStates[key] ?? RemoteCellularMutationState(
            lastTouched: now,
            retainUntil: retainUntil
        )
        state.consumed = true
        state.lastTouched = now
        state.retainUntil = max(state.retainUntil, retainUntil)
        mutationStates[key] = state
        pruneTemporaryState()
    }

    private func isLocallyConsumed(_ key: RemoteCellularRequestKey) -> Bool {
        mutationStates[key]?.consumed == true
    }

    private func pruneTemporaryState(now: Date = Date()) {
        mutationStates = mutationStates.filter { key, value in
            key == activeStartKey || value.retainUntil > now
        }
        guard mutationStates.count > maximumRetainedRequestStates else { return }
        let removable = mutationStates
            .filter { $0.key != activeStartKey && $0.key != displayedRequestKey }
            .sorted { $0.value.lastTouched < $1.value.lastTouched }
        var excess = mutationStates.count - maximumRetainedRequestStates
        for entry in removable where excess > 0 {
            mutationStates.removeValue(forKey: entry.key)
            excess -= 1
        }
        if excess > 0 {
            let remaining = mutationStates
                .filter { $0.key != activeStartKey }
                .sorted { $0.value.lastTouched < $1.value.lastTouched }
            for entry in remaining where excess > 0 {
                mutationStates.removeValue(forKey: entry.key)
                excess -= 1
            }
        }
    }

    private func retryingAcknowledgement<Value>(
        while shouldContinue: (() -> Bool)? = nil,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        var lastError: Error?
        for index in mutationRetryDelaysNanoseconds.indices {
            guard shouldContinue?() != false else {
                throw RemoteCellularLocalError.notificationActionExecutionClosed
            }
            do {
                return try await operation()
            } catch {
                lastError = error
                guard Self.isRetryableAcknowledgementError(error),
                      index + 1 < mutationRetryDelaysNanoseconds.count else {
                    throw error
                }
                let delay = mutationRetryDelaysNanoseconds[index + 1]
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                } else {
                    await Task.yield()
                }
                guard shouldContinue?() != false else {
                    throw RemoteCellularLocalError.notificationActionExecutionClosed
                }
            }
        }
        throw lastError ?? RemoteCellularLocalError.resultAcknowledgementUnavailable
    }

    private static func isRetryableAcknowledgementError(_ error: Error) -> Bool {
        if case AccountAPIError.transport = error { return true }
        if case let AccountAPIError.status(status, _) = error { return status >= 500 && status <= 599 }
        return false
    }

    private func expireVisibleRequest(_ current: RemoteCellularControlDiagnostic) {
        let key = RemoteCellularRequestKey(requestID: current.requestID, accountID: current.accountID)
        let value = Self.replacingDiagnostic(
            current,
            state: .expired,
            appConfirmationRequired: false,
            startClaimObtained: false,
            systemStartAttempted: false,
            publicStartReturnedSuccess: nil,
            safeResult: "EXPIRED"
        )
        setVisibleDiagnostic(value, for: key, manualResult: RemoteCellularManualActionAvailability.expired.rawValue)
    }

    private func isLatestReceive(_ generation: UInt64, key: RemoteCellularReceiveGenerationKey) -> Bool {
        latestReceiveGenerationByKey[key] == generation
    }

    private func actionExecutionMayProceed(
        operation: RemoteCellularReceiveOperation,
        permit: RemoteCellularNotificationActionExecutionPermit?
    ) -> Bool {
        guard operation == .notificationAction else { return true }
        guard let permit else { return false }
        if Self.currentTaskIsCancelled {
            permit.close()
            return false
        }
        return permit.allowsProgress()
    }

    private func actionStartMayProceed(
        origin: StartOrigin,
        permit: RemoteCellularNotificationActionExecutionPermit?
    ) -> Bool {
        guard origin == .notificationAction else { return true }
        guard let permit else { return false }
        if Self.currentTaskIsCancelled {
            permit.close()
            return false
        }
        return permit.allowsProgress()
    }

    private func closeActionExecution(key: RemoteCellularRequestKey) {
        let expiresAt = displayedRequestKey == key ? diagnostic?.expiresAt : nil
        markLocallyConsumed(key, expiresAt: expiresAt)
        guard displayedRequestKey == key,
              let current = diagnostic,
              current.requestID == key.requestID,
              current.accountID == key.accountID else { return }
        setVisibleDiagnostic(Self.replacingDiagnostic(
            current,
            state: .failedSafe,
            appConfirmationRequired: false,
            startClaimObtained: current.startClaimObtained,
            systemStartAttempted: current.systemStartAttempted,
            publicStartReturnedSuccess: current.publicStartReturnedSuccess,
            safeResult: RemoteCellularLocalError.notificationActionExecutionClosed.rawValue
        ), for: key, manualResult: RemoteCellularLocalError.notificationActionExecutionClosed.rawValue)
    }

    private static var currentTaskIsCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private func shouldAcceptReceivedRequest(_ key: RemoteCellularRequestKey, createdAt: Date) -> Bool {
        guard let displayedRequestKey, displayedRequestKey != key,
              let displayedRequestCreatedAt else { return true }
        return createdAt > displayedRequestCreatedAt
    }

    private func activateDisplayedRequest(_ key: RemoteCellularRequestKey, createdAt: Date?) {
        if displayedRequestKey != key {
            displayedRequestKey = key
            diagnostic = nil
            explicitCellularServicePassed = false
            systemManagedPublicStartUsed = false
            executionModeSnapshot = nil
            publicStarterEntered = false
            displayedRequestCreatedAt = createdAt
        } else if let createdAt {
            displayedRequestCreatedAt = max(displayedRequestCreatedAt ?? createdAt, createdAt)
        }
    }

    private func setVisibleDiagnostic(
        _ value: RemoteCellularControlDiagnostic,
        for key: RemoteCellularRequestKey,
        manualResult: String
    ) {
        guard displayedRequestKey == key else { return }
        diagnostic = value
        manualActionResult = manualResult
    }

    private static func replacingDiagnostic(
        _ current: RemoteCellularControlDiagnostic,
        state: RemoteCellularControlState,
        receiptContext: RemoteCellularReceiptContext? = nil,
        appConfirmationRequired: Bool,
        startClaimObtained: Bool,
        systemStartAttempted: Bool,
        publicStartReturnedSuccess: Bool?,
        safeResult: String
    ) -> RemoteCellularControlDiagnostic {
        RemoteCellularControlDiagnostic(
            requestID: current.requestID,
            accountID: current.accountID,
            expiresAt: current.expiresAt,
            state: state,
            deliveryMode: current.deliveryMode,
            receiptContext: receiptContext ?? current.receiptContext,
            applicationStateAtReceipt: current.applicationStateAtReceipt,
            sameOwnerAuthorized: current.sameOwnerAuthorized,
            appConfirmationRequired: appConfirmationRequired,
            startClaimObtained: startClaimObtained,
            systemStartAttempted: systemStartAttempted,
            publicStartReturnedSuccess: publicStartReturnedSuccess,
            safeResult: safeResult,
            ordinaryReceivedAt: current.ordinaryReceivedAt,
            notificationActionReceivedAt: current.notificationActionReceivedAt
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
            deliveryMode: envelope.event.deliveryMode,
            receiptContext: context,
            applicationStateAtReceipt: applicationState,
            sameOwnerAuthorized: authorized,
            appConfirmationRequired: !attempted,
            startClaimObtained: false,
            systemStartAttempted: attempted,
            publicStartReturnedSuccess: nil,
            safeResult: result,
            ordinaryReceivedAt: nil,
            notificationActionReceivedAt: context == .notificationAction ? Date() : nil
        )
    }

    private static func safeReceiptResult(
        state: RemoteCellularControlState,
        context: RemoteCellularReceiptContext
    ) -> String {
        switch state {
        case .iPhoneNotificationActionReceived:
            return "IPHONE_NOTIFICATION_ACTION_RECEIVED"
        case .iPhoneActionRequired:
            return "IPHONE_ACTION_REQUIRED"
        case .iPhoneBackgroundReceived: return "IPHONE_BACKGROUND_RECEIVED"
        case .deliveryPending: return "IPHONE_DELIVERY_PENDING"
        case .iPhoneStartAuthorized: return "IPHONE_START_AUTHORIZED"
        case .iPhoneBackgroundStartAttempted: return "IPHONE_BACKGROUND_START_ATTEMPTED"
        case .iPhoneForegroundStartAttempted: return "IPHONE_FOREGROUND_START_ATTEMPTED"
        case .iPhoneNotificationActionStartAttempted: return "IPHONE_NOTIFICATION_ACTION_START_ATTEMPTED"
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
             .iPhoneForegroundStartAttempted, .iPhoneNotificationActionStartAttempted,
             .systemStartAccepted, .publicStartError:
            return true
        default:
            return false
        }
    }

    private static func hasStartAttempt(_ state: RemoteCellularControlState) -> Bool {
        switch state {
        case .iPhoneBackgroundStartAttempted, .iPhoneForegroundStartAttempted,
             .iPhoneNotificationActionStartAttempted,
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
        if context == .notificationAction { return .iPhoneNotificationActionStartAttempted }
        return context == .background || context == .inactive
            ? .iPhoneBackgroundStartAttempted
            : .iPhoneForegroundStartAttempted
    }

    private static func attemptedResult(for context: RemoteCellularReceiptContext) -> String {
        if context == .notificationAction { return "IPHONE_NOTIFICATION_ACTION_START_ATTEMPTED" }
        return context == .background || context == .inactive
            ? "IPHONE_BACKGROUND_START_ATTEMPTED"
            : "IPHONE_FOREGROUND_START_ATTEMPTED"
    }

    private static func safePublicStartError(_ error: Error) -> (domain: String, code: Int, classification: String) {
        let value = error as NSError
        let domain = "PublicCellularAPI"
        return (domain, value.code, "PUBLIC_START_ERROR_\(domain)_\(value.code)")
    }
}

struct IOSRemoteCellularPendingRequestPanel: View {
    let requestID: UUID
    let accountLabel: String
    let requestMode: RemoteCellularExecutionMode
    let actionResult: String
    let availability: RemoteCellularManualActionAvailability
    let isStarting: Bool
    let onStart: () -> Void
    let onRequestModeOptIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ПОТОЧНИЙ ЗАПИТ")
                .font(.headline)
            Text("Акаунт запиту: \(accountLabel)")
                .font(.caption)
                .lineLimit(2)
            Text("Режим саме запиту: \(requestMode.rawValue)")
                .font(.caption2.monospaced())
                .lineLimit(2)
            Text("Стан дії: \(actionResult)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if availability.allowsStart {
                Button("Запустити виклик НА ЦЬОМУ iPhone", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("remoteCellular.pendingStartButton")
            } else if availability.showsProgress && isStarting {
                ProgressView("Виконується одноразовий запуск")
                    .accessibilityIdentifier("remoteCellular.pendingStartProgress")
            } else if availability == .completed {
                Text("Публічний API прийняв запуск. Це не підтверджує з’єднання оператора.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("remoteCellular.pendingStartCompleted")
            } else if availability == .terminalError || availability == .expired || availability == .cancelled {
                Text("Запит завершено: \(actionResult)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("remoteCellular.pendingStartTerminal")
            }

            if availability.allowsStart && requestMode == .strictExplicitSIM {
                Button("Увімкнути контрольний режим для цього акаунта", action: onRequestModeOptIn)
                    .font(.caption)
                    .accessibilityIdentifier("remoteCellular.requestModeOptInButton")
            }

            Text("Request: \(requestID.uuidString.lowercased())")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityIdentifier("remoteCellular.currentRequestPanel")
    }
}

struct IOSRemoteCellularControlView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator: IOSRemoteCellularControlCoordinator
    @ObservedObject private var accountStore: AccountSessionStore
    @State private var modeConfirmationTarget: ModeConfirmationTarget?

    private enum ModeConfirmationTarget: Equatable {
        case activeAccount
        case request(requestID: UUID, accountID: UUID)
    }

    init(
        coordinator: IOSRemoteCellularControlCoordinator = .shared,
        accountStore: AccountSessionStore = NotificationRuntime.shared.accountStore
    ) {
        self.coordinator = coordinator
        _accountStore = ObservedObject(wrappedValue: accountStore)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                currentRequestPanel
                Divider()
                List {
                    Section("Режим контрольного запуску") {
                        line("Активний акаунт налаштувань", accountStore.activeAccount.map { "\($0.displayLabel) [\(Self.shortID($0.accountID))]" } ?? "none")
                        line("Поточний локальний режим", coordinator.executionMode.rawValue)
                        if coordinator.executionMode == .strictExplicitSIM {
                            Text("Explicit selected SIM: суворий стандартний режим. Запуск можливий лише з реально вибраною системною лінією.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Увімкнути System-managed diagnostic") {
                                modeConfirmationTarget = .activeAccount
                            }
                            .disabled(accountStore.activeAccountID == nil)
                        } else {
                            Text("System-managed diagnostic: застосунок не примушує збережену SIM. iOS визначає лінію та може показати системний вибір або підтвердження; це не гарантовано.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Повернути суворий Explicit selected SIM") {
                                coordinator.useStrictExplicitSIMMode()
                            }
                        }
                    }
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
                        Section("Деталі поточного запиту") {
                            line("Request", value.requestID.uuidString.lowercased())
                            line("Акаунт саме запиту", coordinator.requestAccountLabel(accountID: value.accountID))
                            line("Поточний режим саме запиту", coordinator.requestExecutionMode(accountID: value.accountID).rawValue)
                            line("Delivery mode", value.deliveryMode.rawValue)
                            line("Same-owner Watch", value.sameOwnerAuthorized ? "YES" : "NO")
                            line("Request within TTL now", value.expiresAt.map { $0 > Date() } == true ? "YES" : "NO")
                            line("Received", value.receiptContext.rawValue)
                            line("Application state", value.applicationStateAtReceipt.rawValue)
                            line("Ordinary receipt", value.ordinaryReceivedAt.map(Self.timestamp) ?? "none")
                            line("Notification action", value.notificationActionReceivedAt.map(Self.timestamp) ?? "none")
                            line("Action origin device", "UNKNOWN")
                            line("State", value.state.rawValue)
                            line("App confirmation required", value.appConfirmationRequired ? "YES" : "NO")
                            line("Manual action result", coordinator.manualActionResult)
                            line("Start claim obtained", value.startClaimObtained ? "YES" : "NO")
                            line("iPhone mode snapshot", coordinator.executionModeSnapshot?.rawValue ?? "none")
                            line("Explicit cellular service passed", coordinator.explicitCellularServicePassed ? "YES" : "NO")
                            line("System-managed public start used", coordinator.systemManagedPublicStartUsed ? "YES" : "NO")
                            line("Public starter entered", coordinator.publicStarterEntered ? "YES" : "NO")
                            line("System start attempted", value.systemStartAttempted ? "YES" : "NO")
                            line("Public start returned", value.publicStartReturnedSuccess.map { $0 ? "SUCCESS" : "ERROR" } ?? "NOT_RETURNED")
                            line("Result", value.safeResult)
                            Text("SYSTEM_START_ACCEPTED означає лише прийняття запиту публічним API — не з’єднаний виклик, не відсутність системного вибору SIM і не звук на Watch.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No remote cellular request")
                    }
                }
            }
            .navigationTitle("Remote cellular probe")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { coordinator.activeAccountDidChange() }
            .onChange(of: accountStore.activeAccountID) { _ in coordinator.activeAccountDidChange() }
            .confirmationDialog(
                "Увімкнути System-managed diagnostic?",
                isPresented: modeConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Підтверджую контрольний режим", role: .destructive) {
                    if case let .request(requestID, accountID) = modeConfirmationTarget {
                        coordinator.confirmSystemManagedDiagnosticOptIn(requestID: requestID, accountID: accountID)
                    } else {
                        coordinator.confirmSystemManagedDiagnosticOptIn()
                    }
                    modeConfirmationTarget = nil
                }
                Button("Скасувати", role: .cancel) { modeConfirmationTarget = nil }
            } message: {
                Text(modeConfirmationMessage)
            }
        }
    }

    @ViewBuilder
    private var currentRequestPanel: some View {
        if let value = coordinator.diagnostic {
            let availability = coordinator.manualStartAvailability(
                requestID: value.requestID,
                accountID: value.accountID
            )
            IOSRemoteCellularPendingRequestPanel(
                requestID: value.requestID,
                accountLabel: coordinator.requestAccountLabel(accountID: value.accountID),
                requestMode: coordinator.requestExecutionMode(accountID: value.accountID),
                actionResult: coordinator.manualActionResult,
                availability: availability,
                isStarting: coordinator.isStarting,
                onStart: {
                    let requestID = value.requestID
                    let accountID = value.accountID
                    Task { await coordinator.startPendingControl(requestID: requestID, accountID: accountID) }
                },
                onRequestModeOptIn: {
                    modeConfirmationTarget = .request(requestID: value.requestID, accountID: value.accountID)
                }
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("ПОТОЧНИЙ ЗАПИТ").font(.headline)
                Text("No remote cellular request")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
        }
    }

    private var modeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { modeConfirmationTarget != nil },
            set: { if !$0 { modeConfirmationTarget = nil } }
        )
    }

    private var modeConfirmationMessage: String {
        let accountDescription: String
        if case let .request(_, accountID) = modeConfirmationTarget {
            accountDescription = " Акаунт запиту: \(coordinator.requestAccountLabel(accountID: accountID))."
        } else {
            accountDescription = ""
        }
        return "Цей режим не забезпечує збережену SIM. iOS може показати вибір або підтвердження, але це не гарантовано. Після окремого натискання «Запустити виклик НА ЦЬОМУ iPhone» може початися реальний мобільний виклик. Підтвердження режиму саме по собі не телефонує.\(accountDescription)"
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
