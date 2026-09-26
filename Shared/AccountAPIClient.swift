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

enum AppleAuthTransportPolicy {
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 20
    static let waitsForConnectivity = true

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = waitsForConnectivity
        return configuration
    }
}

private struct AppleDiagnosticRawResult: @unchecked Sendable {
    let data: Data
    let response: URLResponse?
    let error: NSError?
    let metrics: URLSessionTaskMetrics?
    let redirectCount: Int
}

private final class AppleDiagnosticSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var metrics: URLSessionTaskMetrics?
    private var redirectCount = 0
    private var continuation: CheckedContinuation<AppleDiagnosticRawResult, Never>?

    func perform(_ request: URLRequest, session: URLSession) async -> AppleDiagnosticRawResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        self.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirectCount += 1
        lock.unlock()
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        self.metrics = metrics
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result = AppleDiagnosticRawResult(data: data, response: response, error: error as NSError?, metrics: metrics, redirectCount: redirectCount)
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

private final class AppleNWPathTracker: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.apple-transport-path")
    private let lock = NSLock()
    private var latest = AppleTransportPathSnapshot(status: .unknown, interfaces: [], isExpensive: false, isConstrained: false)

    func start() -> AppleTransportPathSnapshot {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let value = Self.snapshot(path)
            self.lock.lock()
            self.latest = value
            self.lock.unlock()
        }
        monitor.start(queue: queue)
        let value = Self.snapshot(monitor.currentPath)
        lock.lock()
        latest = value
        lock.unlock()
        return value
    }

    func current() -> AppleTransportPathSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
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

private enum AppleDiagnosticTransport {
    static func perform(_ request: URLRequest, configuration override: URLSessionConfiguration? = nil) async -> (AppleDiagnosticRawResult, AppleTransportDiagnosticReport) {
        let pathTracker = AppleNWPathTracker()
        let pathStart = pathTracker.start()
        let startedAt = Date()
        let configuration = override ?? AppleAuthTransportPolicy.configuration()
        let delegate = AppleDiagnosticSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let result = await delegate.perform(request, session: session)
        let completedAt = Date()
        let pathEnd = pathTracker.current()
        pathTracker.cancel()
        session.finishTasksAndInvalidate()
        return (result, report(result: result, pathStart: pathStart, pathEnd: pathEnd, startedAt: startedAt, completedAt: completedAt))
    }

    private static func report(result: AppleDiagnosticRawResult, pathStart: AppleTransportPathSnapshot, pathEnd: AppleTransportPathSnapshot, startedAt: Date, completedAt: Date) -> AppleTransportDiagnosticReport {
        let transactions = result.metrics?.transactionMetrics.map { transaction in
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
        } ?? []
        let safeError: AccountAPIError? = result.error.map { AccountAPIError.wrappingTransport($0) }
        let errorComponents: (String?, Int?)
        if let safeError, case .transport(let domain, let code) = safeError {
            errorComponents = (domain, code)
        } else {
            errorComponents = (nil, nil)
        }
        return AppleTransportDiagnosticReport(
            pathStart: pathStart,
            pathEnd: pathEnd,
            transactions: transactions,
            redirectCount: result.redirectCount,
            totalMilliseconds: max(0, Int((completedAt.timeIntervalSince(startedAt) * 1_000).rounded())),
            errorDomain: errorComponents.0,
            errorCode: errorComponents.1
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
    private let tokenStore: SecureTokenStore
    private let deviceID: UUID
    private let beforeRefresh: (@Sendable (UUID, String) async -> Void)?
    private let appleDiagnosticConfiguration: URLSessionConfiguration?

    init(
        config: AppConfig,
        tokenStore: SecureTokenStore,
        session: URLSession? = nil,
        deviceID: UUID = InstallationIdentity.shared.id,
        beforeRefresh: (@Sendable (UUID, String) async -> Void)? = nil,
        appleDiagnosticConfiguration: URLSessionConfiguration? = nil
    ) {
        let root = config.apiBaseURL.deletingLastPathComponent()
        self.baseURL = root.appendingPathComponent("v2", isDirectory: true)
        self.v3BaseURL = root.appendingPathComponent("v3", isDirectory: true)
        self.tokenStore = tokenStore
        self.deviceID = deviceID
        self.beforeRefresh = beforeRefresh
        self.appleDiagnosticConfiguration = appleDiagnosticConfiguration
        if let session { self.session = session }
        else {
            self.session = URLSession(configuration: AccountTransportPolicy.configuration())
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
        value.timeoutInterval = AppleAuthTransportPolicy.requestTimeout
        value.httpBody = try JSONEncoder.account.encode(body)
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (result, report) = await AppleDiagnosticTransport.perform(value, configuration: appleDiagnosticConfiguration)
        if let error = result.error {
            throw AppleSignInDiagnosticFailure(underlying: AccountAPIError.wrappingTransport(error), report: report)
        }
        guard let http = result.response as? HTTPURLResponse else {
            throw AppleSignInDiagnosticFailure(underlying: .invalidResponse, report: report)
        }
        guard 200..<300 ~= http.statusCode else {
            throw AppleSignInDiagnosticFailure(
                underlying: .status(http.statusCode, try? JSONDecoder.account.decode(AccountAPIErrorResponse.self, from: result.data)),
                report: report
            )
        }
        guard let response = try? JSONDecoder.account.decode(AccountSessionResponse.self, from: result.data) else {
            throw AppleSignInDiagnosticFailure(underlying: .decoding, report: report)
        }
        return AppleSignInDiagnosticResult(response: response, report: report)
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
