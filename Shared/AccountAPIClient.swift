import Foundation
import Network

actor AccountRefreshCoordinator {
    static let shared = AccountRefreshCoordinator()

    struct RefreshKey: Hashable, Sendable {
        let accountID: UUID
        let deviceID: UUID
    }

    private struct Entry {
        let id: UUID
        let task: Task<AccountTokens, Error>
    }

    private var entries: [RefreshKey: Entry] = [:]

    func refresh(
        key: RefreshKey,
        operation: @escaping @Sendable () async throws -> AccountTokens
    ) async throws -> AccountTokens {
        if let entry = entries[key] { return try await entry.task.value }
        let entry = Entry(id: UUID(), task: Task { try await operation() })
        entries[key] = entry
        defer {
            if entries[key]?.id == entry.id { entries[key] = nil }
        }
        return try await entry.task.value
    }
}

enum AccountTransportPolicy {
    static let requestTimeout: TimeInterval = 10
    static let resourceTimeout: TimeInterval = 10
    static let waitsForConnectivity = false

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = waitsForConnectivity
        return configuration
    }
}

private struct ApplePathObservation: Sendable {
    let pathStart: AppleTransportPathSnapshot
    let firstCallbackMilliseconds: Int?
    let firstCallback: AppleTransportPathSnapshot?
    let pathEnd: AppleTransportPathSnapshot
}

private final class AppleNWPathTracker: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.apple-transport-path")
    private let lock = NSLock()
    private var firstCallbackMilliseconds: Int?
    private var firstCallback: AppleTransportPathSnapshot?
    private var latest = AppleTransportPathSnapshot(status: .unknown, interfaces: [], isExpensive: false, isConstrained: false)

    func start(startedAt: Date) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let value = Self.snapshot(path)
            let elapsed = max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
            self.lock.lock()
            if self.firstCallback == nil {
                self.firstCallback = value
                self.firstCallbackMilliseconds = elapsed
            }
            self.latest = value
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    func finish() -> ApplePathObservation {
        lock.lock()
        let firstMilliseconds = firstCallbackMilliseconds
        let first = firstCallback
        let end = latest
        lock.unlock()
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        return ApplePathObservation(
            pathStart: AppleTransportPathSnapshot(status: .unknown, interfaces: [], isExpensive: false, isConstrained: false),
            firstCallbackMilliseconds: firstMilliseconds,
            firstCallback: first,
            pathEnd: end
        )
    }

    private static func snapshot(_ path: NWPath) -> AppleTransportPathSnapshot {
        let status: AppleTransportPathSnapshot.Status
        switch path.status {
        case .satisfied: status = .satisfied
        case .unsatisfied: status = .unsatisfied
        case .requiresConnection: status = .requiresConnection
        @unknown default: status = .unknown
        }
        var interfaces: Set<AppleTransportPathSnapshot.InterfaceKind> = []
        if path.usesInterfaceType(.wifi) { interfaces.insert(.wifi) }
        if path.usesInterfaceType(.cellular) { interfaces.insert(.cellular) }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.insert(.wiredEthernet) }
        if path.usesInterfaceType(.other) || path.usesInterfaceType(.loopback) { interfaces.insert(.other) }
        return AppleTransportPathSnapshot(status: status, interfaces: interfaces.sorted(), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
}

struct AppleTaskExecutionResult: @unchecked Sendable {
    let data: Data
    let response: URLResponse?
    let error: AccountAPIError?
    let transactions: [AppleTransportTransactionSnapshot]
    let redirectCount: Int
    let lifecycle: AppleTaskLifecycleSnapshot
}

final class AppleTaskLifecycleDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias TaskCreatedObserver = @Sendable (URLSessionDataTask) -> Void

    private final class Context {
        let task: URLSessionDataTask
        let continuation: CheckedContinuation<AppleTaskExecutionResult, Never>
        let startedAt: Date
        let bodyByteCount: Int
        var data = Data()
        var response: URLResponse?
        var transactions: [AppleTransportTransactionSnapshot] = []
        var redirectCount = 0
        var events: [AppleTaskLifecycleEvent] = []
        var resumeCount = 0
        var afterResumeRecorded = false
        var dataEventRecorded = false

        init(task: URLSessionDataTask, continuation: CheckedContinuation<AppleTaskExecutionResult, Never>, startedAt: Date, bodyByteCount: Int) {
            self.task = task
            self.continuation = continuation
            self.startedAt = startedAt
            self.bodyByteCount = bodyByteCount
        }
    }

    private let condition = NSCondition()
    private var contexts: [Int: Context] = [:]
    private let taskCreatedObserver: TaskCreatedObserver?

    init(taskCreatedObserver: TaskCreatedObserver? = nil) {
        self.taskCreatedObserver = taskCreatedObserver
        super.init()
    }

    var activeTaskCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return contexts.count
    }

    func perform(_ request: URLRequest, session: URLSession, startedAt: Date) async -> AppleTaskExecutionResult {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            let context = Context(
                task: task,
                continuation: continuation,
                startedAt: startedAt,
                bodyByteCount: request.httpBody?.count ?? 0
            )
            condition.lock()
            contexts[task.taskIdentifier] = context
            context.events.append(event(.taskCreated, task: task, context: context))
            condition.unlock()

            taskCreatedObserver?(task)

            condition.lock()
            context.events.append(event(.beforeResume, task: task, context: context))
            condition.unlock()

            task.resume()

            condition.lock()
            context.resumeCount += 1
            context.events.append(event(.afterResume, task: task, context: context))
            context.afterResumeRecorded = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        condition.lock()
        guard let context = contextAfterResume(for: task.taskIdentifier) else {
            condition.unlock()
            return
        }
        context.events.append(event(.waitingForConnectivity, task: task, context: context))
        condition.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        condition.lock()
        if let context = contextAfterResume(for: dataTask.taskIdentifier) {
            context.response = response
            context.events.append(event(.responseReceived, task: dataTask, context: context))
        }
        condition.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        if let context = contextAfterResume(for: dataTask.taskIdentifier) {
            context.data.append(data)
            if !context.dataEventRecorded {
                context.dataEventRecorded = true
                context.events.append(event(.dataReceived, task: dataTask, context: context))
            }
        }
        condition.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        condition.lock()
        if let context = contextAfterResume(for: task.taskIdentifier) {
            context.redirectCount += 1
        }
        condition.unlock()
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        condition.lock()
        guard let context = contextAfterResume(for: task.taskIdentifier) else {
            condition.unlock()
            return
        }
        context.transactions = metrics.transactionMetrics.map { transaction in
            Self.transactionSnapshot(transaction, relativeTo: context.startedAt)
        }
        context.events.append(event(
            .metricsCollected,
            task: task,
            context: context,
            transactionCount: context.transactions.count
        ))
        condition.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        guard let context = contextAfterResume(for: task.taskIdentifier) else {
            condition.unlock()
            return
        }
        let safeError = error.map(AccountAPIError.wrappingTransport)
        let errorParts = Self.errorParts(safeError)
        context.events.append(event(
            .taskCompleted,
            task: task,
            context: context,
            errorDomain: errorParts.0,
            errorCode: errorParts.1
        ))
        let lifecycle = AppleTaskLifecycleSnapshot(
            taskIdentifier: task.taskIdentifier,
            resumeCount: context.resumeCount,
            events: context.events,
            request: Self.requestSnapshot(task: task, bodyByteCount: context.bodyByteCount)
        )
        let result = AppleTaskExecutionResult(
            data: context.data,
            response: context.response,
            error: safeError,
            transactions: context.transactions,
            redirectCount: context.redirectCount,
            lifecycle: lifecycle
        )
        contexts[task.taskIdentifier] = nil
        let continuation = context.continuation
        condition.unlock()
        continuation.resume(returning: result)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let safeError = error.map(AccountAPIError.wrappingTransport)
        let errorParts = Self.errorParts(safeError)
        condition.lock()
        for context in contexts.values {
            context.events.append(event(
                .sessionInvalidated,
                task: context.task,
                context: context,
                errorDomain: errorParts.0,
                errorCode: errorParts.1
            ))
        }
        condition.unlock()
    }

    private func contextAfterResume(for taskIdentifier: Int) -> Context? {
        while let context = contexts[taskIdentifier], !context.afterResumeRecorded {
            condition.wait()
        }
        return contexts[taskIdentifier]
    }

    private func event(
        _ kind: AppleTaskLifecycleEventKind,
        task: URLSessionTask,
        context: Context,
        transactionCount: Int? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) -> AppleTaskLifecycleEvent {
        AppleTaskLifecycleEvent(
            kind: kind,
            elapsedMilliseconds: max(0, Int((Date().timeIntervalSince(context.startedAt) * 1_000).rounded())),
            taskIdentifier: task.taskIdentifier,
            state: AppleTaskLifecycleState.capture(task.state),
            transactionCount: transactionCount,
            errorDomain: errorDomain,
            errorCode: errorCode
        )
    }

    private static func requestSnapshot(task: URLSessionTask, bodyByteCount: Int) -> AppleTaskRequestSnapshot {
        let original = task.originalRequest
        let current = task.currentRequest
        return AppleTaskRequestSnapshot(
            originalRequestPresent: original != nil,
            currentRequestPresent: current != nil,
            originalPath: safePath(original),
            currentPath: safePath(current),
            originalMethod: safeMethod(original?.httpMethod),
            currentMethod: safeMethod(current?.httpMethod),
            bodyByteCount: bodyByteCount,
            earliestBeginDatePresent: task.earliestBeginDate != nil,
            priority: task.priority,
            countOfBytesExpectedToSend: task.countOfBytesExpectedToSend,
            countOfBytesSent: task.countOfBytesSent,
            countOfBytesExpectedToReceive: task.countOfBytesExpectedToReceive,
            countOfBytesReceived: task.countOfBytesReceived
        )
    }

    private static func safePath(_ request: URLRequest?) -> String? {
        guard let path = request?.url?.path else { return nil }
        return path == "/wifi-secure-call/v3/auth/apple" ? path : "other"
    }

    private static func safeMethod(_ value: String?) -> String? {
        guard let value, value.range(of: #"^[A-Z]{1,10}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func errorParts(_ error: AccountAPIError?) -> (String?, Int?) {
        guard let error, case .transport(let domain, let code) = error else { return (nil, nil) }
        return (domain, code)
    }

    private static func transactionSnapshot(_ transaction: URLSessionTaskTransactionMetrics, relativeTo startedAt: Date) -> AppleTransportTransactionSnapshot {
        AppleTransportTransactionSnapshot(
            fetchStartMilliseconds: milliseconds(transaction.fetchStartDate, relativeTo: startedAt),
            domainLookup: .capture(start: transaction.domainLookupStartDate, end: transaction.domainLookupEndDate, relativeTo: startedAt),
            connect: .capture(start: transaction.connectStartDate, end: transaction.connectEndDate, relativeTo: startedAt),
            secureConnection: .capture(start: transaction.secureConnectionStartDate, end: transaction.secureConnectionEndDate, relativeTo: startedAt),
            request: .capture(start: transaction.requestStartDate, end: transaction.requestEndDate, relativeTo: startedAt),
            response: .capture(start: transaction.responseStartDate, end: transaction.responseEndDate, relativeTo: startedAt),
            networkProtocolName: safeProtocol(transaction.networkProtocolName),
            isProxyConnection: transaction.isProxyConnection,
            isReusedConnection: transaction.isReusedConnection,
            resourceFetchType: safeFetchType(transaction.resourceFetchType)
        )
    }

    private static func milliseconds(_ date: Date?, relativeTo origin: Date) -> Int? {
        date.map { max(0, Int(($0.timeIntervalSince(origin) * 1_000).rounded())) }
    }

    private static func safeProtocol(_ value: String?) -> String? {
        guard let value, value.count <= 24,
              value.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func safeFetchType(_ value: URLSessionTaskMetrics.ResourceFetchType) -> String {
        switch value {
        case .networkLoad: return "networkLoad"
        case .serverPush: return "serverPush"
        case .localCache: return "localCache"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

actor AccountAPIClient {
    private let baseURL: URL
    private let v3BaseURL: URL
    private let session: URLSession
    private let appleTaskDelegate: AppleTaskLifecycleDelegate?
    private let tokenStore: SecureTokenStore
    private let deviceID: UUID
    private let beforeRefresh: (@Sendable (UUID, String) async -> Void)?

    init(
        config: AppConfig,
        tokenStore: SecureTokenStore,
        session: URLSession? = nil,
        appleTaskDelegate: AppleTaskLifecycleDelegate? = nil,
        deviceID: UUID = InstallationIdentity.shared.id,
        beforeRefresh: (@Sendable (UUID, String) async -> Void)? = nil
    ) {
        let root = config.apiBaseURL.deletingLastPathComponent()
        self.baseURL = root.appendingPathComponent("v2", isDirectory: true)
        self.v3BaseURL = root.appendingPathComponent("v3", isDirectory: true)
        self.tokenStore = tokenStore
        self.deviceID = deviceID
        self.beforeRefresh = beforeRefresh
        if let session {
            self.session = session
            self.appleTaskDelegate = appleTaskDelegate
        } else {
            let delegate = AppleTaskLifecycleDelegate()
            self.appleTaskDelegate = delegate
            self.session = URLSession(
                configuration: AccountTransportPolicy.configuration(),
                delegate: delegate,
                delegateQueue: nil
            )
        }
    }

    func signInWithApple(identityToken: String, authorizationCode: String, nonce: String, displayName: String, email: String, requestID: UUID = UUID()) async throws -> AccountSessionResponse {
        try await request("auth/apple", body: AppleSignInRequest(requestID: requestID, deviceID: deviceID, platform: "iOS", identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce, displayName: displayName, email: email), root: v3BaseURL)
    }

    func signInWithAppleDiagnosed(identityToken: String, authorizationCode: String, nonce: String, displayName: String, email: String, requestID: UUID = UUID()) async throws -> AppleSignInDiagnosticResult {
        try await diagnosticAppleSignIn(AppleSignInRequest(requestID: requestID, deviceID: deviceID, platform: "iOS", identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce, displayName: displayName, email: email))
    }

    func userProfile(accountID: UUID) async throws -> UserProfile {
        try await authorizedV3("me", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func updateUsername(_ username: String, accountID: UUID) async throws -> UserProfile {
        try await authorizedV3("me/username", method: "PUT", accountID: accountID, body: UsernameUpdateRequest(username: username))
    }

    func startPhoneBinding(_ phoneNumber: String, accountID: UUID, requestID: UUID = UUID()) async throws -> PhoneStartResponse {
        try await authorizedV3("phones/start", accountID: accountID, body: PhoneStartRequest(requestID: requestID, phoneNumber: phoneNumber))
    }

    func verifyPhoneBinding(verificationID: UUID, code: String, accountID: UUID) async throws -> UserProfile {
        try await authorizedV3("phones/verify", accountID: accountID, body: PhoneBindingVerifyRequest(verificationID: verificationID, code: code))
    }

    func removePhoneBinding(_ bindingID: UUID, accountID: UUID) async throws {
        let _: EmptyAccountResponse = try await authorizedV3("phones/\(bindingID.uuidString.lowercased())", method: "DELETE", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func startPhone(_ phoneNumber: String, requestID: UUID = UUID()) async throws -> PhoneStartResponse {
        try await request("auth/phone/start", body: PhoneStartRequest(requestID: requestID, phoneNumber: phoneNumber))
    }

    func verifyPhone(verificationID: UUID, code: String, requestID: UUID = UUID()) async throws -> AccountSessionResponse {
        try await request("auth/phone/verify", body: PhoneVerifyRequest(requestID: requestID, verificationID: verificationID, code: code, deviceID: deviceID, platform: "iOS"))
    }

    func watchLinkStart(requestID: UUID = UUID()) async throws -> WatchLinkStartResponse {
        try await request("watch-link/start", body: WatchLinkStartRequest(requestID: requestID, deviceID: deviceID, platform: "watchOS"))
    }

    func watchLinkStatus(linkID: UUID, secret: String) async throws -> WatchLinkStatusResponse {
        try await request("watch-link/status", body: WatchLinkStatusRequest(linkID: linkID, linkSecret: secret))
    }

    func claimWatch(code: String, accountID: UUID, requestID: UUID = UUID()) async throws {
        let _: EmptyAccountResponse = try await authorized("watch-link/claim", accountID: accountID, body: WatchLinkClaimRequest(requestID: requestID, code: code))
    }

    func me(accountID: UUID) async throws -> AccountMeResponse {
        try await authorized("me", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func logout(accountID: UUID) async throws {
        let _: EmptyAccountResponse = try await authorized("auth/logout", accountID: accountID, body: EmptyAccountRequest())
        try tokenStore.delete(accountID: accountID)
    }

    func deleteAccount(accountID: UUID) async throws {
        let _: EmptyAccountResponse = try await authorized("account", method: "DELETE", accountID: accountID, body: AccountDeleteRequest(confirm: "DELETE"))
        try tokenStore.delete(accountID: accountID)
    }

    func registerDevice(accountID: UUID, token: Data, pushType: DevicePushType, capabilities: DeviceCapabilities, installationGeneration: UInt64 = InstallationIdentity.shared.generation, environment: APNSEnvironment = .production) async throws {
        let _: EmptyAccountResponse = try await authorized("devices/register", accountID: accountID, body: AccountDeviceRegistrationRequest(
            requestID: UUID(), deviceID: deviceID, platform: Self.platform, pushType: pushType,
            token: token.hexString, invalidatedToken: nil, installationGeneration: installationGeneration,
            environment: environment, capabilities: capabilities
        ))
    }

    func invalidateDevice(accountID: UUID, pushType: DevicePushType, expectedToken: Data?, capabilities: DeviceCapabilities, installationGeneration: UInt64 = InstallationIdentity.shared.generation, environment: APNSEnvironment = .production) async throws {
        let _: EmptyAccountResponse = try await authorized("devices/register", accountID: accountID, body: AccountDeviceRegistrationRequest(
            requestID: UUID(), deviceID: deviceID, platform: Self.platform, pushType: pushType,
            token: "", invalidatedToken: expectedToken?.hexString, installationGeneration: installationGeneration,
            environment: environment, capabilities: capabilities
        ))
    }

    func devices(accountID: UUID) async throws -> [AccountDeviceSummary] {
        try await authorized("devices", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func createCall(accountID: UUID, callID: UUID, requestID: UUID, targetDeviceID: UUID) async throws -> AccountCallResponse {
        try await authorized("calls", accountID: accountID, body: AccountCallCreateRequest(requestID: requestID, callID: callID, targetDeviceID: targetDeviceID))
    }

    func call(accountID: UUID, callID: UUID) async throws -> AccountCallResponse {
        try await authorized("calls/\(callID.uuidString.lowercased())", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func mutateCall(accountID: UUID, action: CallMutation, callID: UUID, requestID: UUID) async throws -> AccountCallResponse {
        try await authorized("calls/\(callID.uuidString.lowercased())/\(action.rawValue)", accountID: accountID, body: AccountCallMutationRequest(requestID: requestID))
    }

    private func authorizedV3<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", accountID: UUID, body: B?) async throws -> T {
        var tokens = try tokenStore.tokens(for: accountID) ?? { throw AccountAPIError.missingSession }()
        if tokens.accessExpiresAt <= Date() { tokens = try await refresh(accountID: accountID, expectedRefreshToken: tokens.refreshToken) }
        do { return try await request(path, method: method, body: body, bearer: tokens.accessToken, root: v3BaseURL) }
        catch let error as AccountAPIError {
            guard case .status(401, _) = error else { throw error }
            tokens = try await refresh(accountID: accountID, expectedRefreshToken: tokens.refreshToken)
            return try await request(path, method: method, body: body, bearer: tokens.accessToken, root: v3BaseURL)
        }
    }

    private func authorized<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", accountID: UUID, body: B?) async throws -> T {
        var tokens = try tokenStore.tokens(for: accountID) ?? { throw AccountAPIError.missingSession }()
        if tokens.accessExpiresAt <= Date() {
            await beforeRefresh?(accountID, tokens.refreshToken)
            tokens = try await refresh(accountID: accountID, expectedRefreshToken: tokens.refreshToken)
        }

        for attempt in 0...2 {
            do {
                return try await request(path, method: method, body: body, bearer: tokens.accessToken)
            } catch let error as AccountAPIError {
                guard case .status(401, _) = error else { throw error }
                guard attempt < 2 else { throw error }
                guard let latest = try tokenStore.tokens(for: accountID) else {
                    throw AccountAPIError.missingSession
                }

                if latest.accessToken != tokens.accessToken || latest.refreshToken != tokens.refreshToken {
                    if latest.accessExpiresAt > Date() {
                        tokens = latest
                    } else {
                        await beforeRefresh?(accountID, latest.refreshToken)
                        tokens = try await refresh(accountID: accountID, expectedRefreshToken: latest.refreshToken)
                    }
                } else {
                    await beforeRefresh?(accountID, tokens.refreshToken)
                    tokens = try await refresh(accountID: accountID, expectedRefreshToken: tokens.refreshToken)
                }
            }
        }
        throw AccountAPIError.invalidResponse
    }

    private func refresh(accountID: UUID, expectedRefreshToken: String) async throws -> AccountTokens {
        let key = AccountRefreshCoordinator.RefreshKey(accountID: accountID, deviceID: deviceID)
        return try await AccountRefreshCoordinator.shared.refresh(key: key) { [self] in
            try await performRefresh(accountID: accountID, expectedRefreshToken: expectedRefreshToken)
        }
    }

    private func performRefresh(accountID: UUID, expectedRefreshToken: String) async throws -> AccountTokens {
        guard let current = try tokenStore.tokens(for: accountID) else { throw AccountAPIError.missingSession }
        if current.refreshToken != expectedRefreshToken, current.accessExpiresAt > Date() {
            return current
        }
        let attemptedRefreshToken = current.refreshToken
        do {
            let response: AccountSessionResponse = try await request("auth/refresh", body: AccountRefreshRequest(refreshToken: attemptedRefreshToken, deviceID: deviceID))
            try tokenStore.save(response.tokens, for: accountID)
            return response.tokens
        } catch {
            if case let AccountAPIError.status(status, _) = error, status == 401 || status == 403 {
                _ = try? tokenStore.deleteIfRefreshTokenMatches(accountID: accountID, refreshToken: attemptedRefreshToken)
            }
            throw error
        }
    }

    private func diagnosticAppleSignIn(_ body: AppleSignInRequest) async throws -> AppleSignInDiagnosticResult {
        var value = URLRequest(url: v3BaseURL.appendingPathComponent("auth/apple"))
        value.httpMethod = "POST"
        value.timeoutInterval = AccountTransportPolicy.requestTimeout
        value.httpBody = try JSONEncoder.account.encode(body)
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let startedAt = Date()
        let pathTracker = AppleNWPathTracker()
        pathTracker.start(startedAt: startedAt)

        if let appleTaskDelegate {
            let result = await appleTaskDelegate.perform(value, session: session, startedAt: startedAt)
            let path = pathTracker.finish()
            let report = appleDiagnosticReport(result: result, path: path, startedAt: startedAt)
            if let error = result.error {
                throw AppleSignInDiagnosticFailure(underlying: error, report: report)
            }
            return try decodeAppleSignIn(data: result.data, response: result.response, report: report)
        }

        // Injected test sessions without our retained delegate keep their existing behavior.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: value)
        } catch {
            let underlying = AccountAPIError.wrappingTransport(error)
            let path = pathTracker.finish()
            let report = appleDiagnosticReport(result: nil, path: path, startedAt: startedAt, error: underlying)
            throw AppleSignInDiagnosticFailure(underlying: underlying, report: report)
        }
        let path = pathTracker.finish()
        let report = appleDiagnosticReport(result: nil, path: path, startedAt: startedAt)
        return try decodeAppleSignIn(data: data, response: response, report: report)
    }

    private func decodeAppleSignIn(data: Data, response: URLResponse?, report: AppleTransportDiagnosticReport) throws -> AppleSignInDiagnosticResult {
        guard let http = response as? HTTPURLResponse else {
            throw AppleSignInDiagnosticFailure(underlying: .invalidResponse, report: report)
        }
        guard 200..<300 ~= http.statusCode else {
            throw AppleSignInDiagnosticFailure(
                underlying: .status(http.statusCode, try? JSONDecoder.account.decode(AccountAPIErrorResponse.self, from: data)),
                report: report
            )
        }
        guard let decoded = try? JSONDecoder.account.decode(AccountSessionResponse.self, from: data) else {
            throw AppleSignInDiagnosticFailure(underlying: .decoding, report: report)
        }
        return AppleSignInDiagnosticResult(response: decoded, report: report)
    }

    private func appleDiagnosticReport(
        result: AppleTaskExecutionResult?,
        path: ApplePathObservation,
        startedAt: Date,
        error: AccountAPIError? = nil
    ) -> AppleTransportDiagnosticReport {
        let effectiveError = result?.error ?? error
        let errorComponents: (String?, Int?)
        if let effectiveError, case .transport(let domain, let code) = effectiveError {
            errorComponents = (domain, code)
        } else {
            errorComponents = (nil, nil)
        }
        return AppleTransportDiagnosticReport(
            pathStart: path.pathStart,
            pathEnd: path.pathEnd,
            transactions: result?.transactions ?? [],
            redirectCount: result?.redirectCount ?? 0,
            totalMilliseconds: max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())),
            errorDomain: errorComponents.0,
            errorCode: errorComponents.1,
            pathFirstCallbackMilliseconds: path.firstCallbackMilliseconds,
            pathFirstCallback: path.firstCallback,
            taskLifecycle: result?.lifecycle
        )
    }

    private func request<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", body: B?, bearer: String? = nil, root: URL? = nil) async throws -> T {
        var value = URLRequest(url: (root ?? baseURL).appendingPathComponent(path))
        value.httpMethod = method
        value.timeoutInterval = AccountTransportPolicy.requestTimeout
        if let body { value.httpBody = try JSONEncoder.account.encode(body) }
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { value.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: value)
        } catch {
            throw AccountAPIError.wrappingTransport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw AccountAPIError.invalidResponse }
        guard 200..<300 ~= http.statusCode else { throw AccountAPIError.status(http.statusCode, try? JSONDecoder.account.decode(AccountAPIErrorResponse.self, from: data)) }
        if T.self == EmptyAccountResponse.self, data.isEmpty { return EmptyAccountResponse() as! T }
        guard let decoded = try? JSONDecoder.account.decode(T.self, from: data) else { throw AccountAPIError.decoding }
        return decoded
    }

    private static var platform: String {
        #if os(watchOS)
        "watchOS"
        #else
        "iOS"
        #endif
    }
}

private struct EmptyAccountRequest: Codable {}
private struct EmptyAccountResponse: Codable {}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
