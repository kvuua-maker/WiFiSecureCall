import Foundation

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

actor AccountAPIClient {
    private let baseURL: URL
    private let v3BaseURL: URL
    private let session: URLSession
    private let tokenStore: SecureTokenStore
    private let deviceID: UUID
    private let devicePlatform: String
    private let configurationError: AppConfigError?
    private let beforeRefresh: (@Sendable (UUID, String) async -> Void)?

    init(
        config: AppConfig,
        tokenStore: SecureTokenStore,
        session: URLSession? = nil,
        deviceID: UUID = InstallationIdentity.shared.id,
        platform: String? = nil,
        beforeRefresh: (@Sendable (UUID, String) async -> Void)? = nil
    ) {
        let root = config.apiBaseURL.deletingLastPathComponent()
        self.baseURL = root.appendingPathComponent("v2", isDirectory: true)
        self.v3BaseURL = root.appendingPathComponent("v3", isDirectory: true)
        self.tokenStore = tokenStore
        self.deviceID = deviceID
        self.devicePlatform = platform ?? Self.currentPlatform
        self.configurationError = config.configurationError
        self.beforeRefresh = beforeRefresh
        self.session = session ?? URLSession(configuration: AccountTransportPolicy.configuration())
    }

    func signInWithApple(identityToken: String, authorizationCode: String, nonce: String, displayName: String, email: String, requestID: UUID = UUID()) async throws -> AccountSessionResponse {
        try await request("auth/apple", body: AppleSignInRequest(requestID: requestID, deviceID: deviceID, platform: "iOS", identityToken: identityToken, authorizationCode: authorizationCode, nonce: nonce, displayName: displayName, email: email), root: v3BaseURL)
    }

    func signInWithAppleFromWatch(
        credential: AppleNativeCredentialInput,
        expectedState: String,
        rawNonce: String,
        requestID: UUID = UUID()
    ) async throws -> AccountSessionResponse {
        let value = try AppleCredentialContract.validate(credential, expectedState: expectedState, rawNonce: rawNonce)
        return try await submitAppleSignIn(
            identityToken: value.identityToken,
            authorizationCode: value.authorizationCode,
            nonce: value.rawNonce,
            displayName: value.displayName,
            email: value.email,
            platform: "watchOS",
            requestID: requestID
        )
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
            requestID: UUID(), deviceID: deviceID, platform: devicePlatform, pushType: pushType,
            token: token.hexString, invalidatedToken: nil, installationGeneration: installationGeneration,
            environment: environment, capabilities: capabilities
        ))
    }

    func invalidateDevice(accountID: UUID, pushType: DevicePushType, expectedToken: Data?, capabilities: DeviceCapabilities, installationGeneration: UInt64 = InstallationIdentity.shared.generation, environment: APNSEnvironment = .production) async throws {
        let _: EmptyAccountResponse = try await authorized("devices/register", accountID: accountID, body: AccountDeviceRegistrationRequest(
            requestID: UUID(), deviceID: deviceID, platform: devicePlatform, pushType: pushType,
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

    func resolveRecipient(_ recipient: String, accountID: UUID) async throws -> ResolvedRecipient {
        try await authorizedV3("recipients/resolve", accountID: accountID, body: RecipientResolveRequest(recipient: recipient))
    }

    func createUserCall(accountID: UUID, callID: UUID, requestID: UUID, targetUserID: UUID, callerKeyPackage: E2EECallKeyPackage? = nil) async throws -> CrossUserCallResponse {
        try await authorizedV3("calls", accountID: accountID, body: CrossUserCallCreateRequest(requestID: requestID, callID: callID, targetUserID: targetUserID, callerKeyPackage: callerKeyPackage))
    }

    func userCall(accountID: UUID, callID: UUID) async throws -> CrossUserCallResponse {
        try await authorizedV3("calls/\(callID.uuidString.lowercased())", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func mutateUserCall(accountID: UUID, action: CallMutation, callID: UUID, requestID: UUID, calleeKeyPackage: E2EECallKeyPackage? = nil) async throws -> CrossUserCallResponse {
        try await authorizedV3("calls/\(callID.uuidString.lowercased())/\(action.rawValue)", accountID: accountID, body: CrossUserCallMutationRequest(requestID: requestID, calleeKeyPackage: calleeKeyPackage))
    }

    func registerDeviceKey(accountID: UUID, request: E2EEDeviceRegistrationRequest) async throws -> E2EEPublicDeviceBundle {
        try await authorizedV3("device-keys", accountID: accountID, body: request)
    }

    func deviceKeys(accountID: UUID, userID: UUID) async throws -> [E2EEPublicDeviceBundle] {
        try await authorizedV3("users/\(userID.uuidString.lowercased())/device-keys", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func createSecureConversation(accountID: UUID, requestID: UUID, targetUserID: UUID) async throws -> SecureConversation {
        try await authorizedV3("conversations", accountID: accountID, body: CreateSecureConversationRequest(requestID: requestID, targetUserID: targetUserID))
    }

    func secureConversations(accountID: UUID) async throws -> [SecureConversation] {
        try await authorizedV3("conversations", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none)
    }

    func secureMessages(accountID: UUID, conversationID: UUID, cursor: String?, limit: Int) async throws -> SecureMessagePage {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await authorizedV3("conversations/\(conversationID.uuidString.lowercased())/messages", method: "GET", accountID: accountID, body: Optional<EmptyAccountRequest>.none, queryItems: query)
    }

    func sendSecureMessage(accountID: UUID, conversationID: UUID, input: SecureMessageInput) async throws -> SecureMessageRecord {
        try await authorizedV3("conversations/\(conversationID.uuidString.lowercased())/messages", accountID: accountID, body: input)
    }

    func markSecureMessage(accountID: UUID, conversationID: UUID, messageID: UUID, action: String) async throws -> SecureMessageRecord {
        try await authorizedV3("conversations/\(conversationID.uuidString.lowercased())/messages/\(messageID.uuidString.lowercased())/\(action)", accountID: accountID, body: SecureMessageReceiptRequest(requestID: UUID()))
    }

    func createRemoteCellularControl(accountID: UUID, requestID: UUID, phoneNumber: String) async throws -> RemoteCellularControlView {
        try await authorizedV3(
            "cellular-controls",
            accountID: accountID,
            body: RemoteCellularControlCreateRequest(requestID: requestID, phoneNumber: phoneNumber)
        )
    }

    func createRemoteCellularNotificationActionControl(accountID: UUID, requestID: UUID, phoneNumber: String) async throws -> RemoteCellularControlView {
        try await authorizedV3(
            "cellular-controls/notification-action",
            accountID: accountID,
            body: RemoteCellularControlCreateRequest(requestID: requestID, phoneNumber: phoneNumber)
        )
    }

    func remoteCellularControl(accountID: UUID, requestID: UUID) async throws -> RemoteCellularControlView {
        try await authorizedV3(
            "cellular-controls/\(requestID.uuidString.lowercased())",
            method: "GET",
            accountID: accountID,
            body: Optional<EmptyAccountRequest>.none
        )
    }

    func receiveRemoteCellularControl(
        accountID: UUID,
        requestID: UUID,
        mutationID: UUID = UUID(),
        context: RemoteCellularReceiptContext,
        applicationState: RemoteCellularApplicationState
    ) async throws -> RemoteCellularControlView {
        try await authorizedV3(
            "cellular-controls/\(requestID.uuidString.lowercased())/receive",
            accountID: accountID,
            body: RemoteCellularControlReceiptRequest(
                requestID: mutationID,
                receiptContext: context,
                applicationState: applicationState
            )
        )
    }

    func claimRemoteCellularControlStart(accountID: UUID, requestID: UUID, mutationID: UUID = UUID()) async throws -> RemoteCellularControlStartGrant {
        try await authorizedV3(
            "cellular-controls/\(requestID.uuidString.lowercased())/start",
            accountID: accountID,
            body: RemoteCellularControlMutationRequest(requestID: mutationID)
        )
    }

    func markRemoteCellularControlStartAttempted(accountID: UUID, requestID: UUID, mutationID: UUID = UUID()) async throws -> RemoteCellularControlView {
        try await remoteCellularMutation(accountID: accountID, controlID: requestID, action: "start-attempted", mutationID: mutationID)
    }

    func completeRemoteCellularControlStart(
        accountID: UUID,
        requestID: UUID,
        mutationID: UUID = UUID(),
        result: RemoteCellularStartResult,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) async throws -> RemoteCellularControlView {
        try await authorizedV3(
            "cellular-controls/\(requestID.uuidString.lowercased())/start-result",
            accountID: accountID,
            body: RemoteCellularControlStartResultRequest(
                requestID: mutationID,
                result: result,
                safeErrorDomain: errorDomain,
                safeErrorCode: errorCode
            )
        )
    }

    func cancelRemoteCellularControl(accountID: UUID, requestID: UUID, mutationID: UUID = UUID()) async throws -> RemoteCellularControlView {
        try await remoteCellularMutation(accountID: accountID, controlID: requestID, action: "cancel", mutationID: mutationID)
    }

    private func remoteCellularMutation(accountID: UUID, controlID: UUID, action: String, mutationID: UUID) async throws -> RemoteCellularControlView {
        try await authorizedV3(
            "cellular-controls/\(controlID.uuidString.lowercased())/\(action)",
            accountID: accountID,
            body: RemoteCellularControlMutationRequest(requestID: mutationID)
        )
    }

    private func authorizedV3<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", accountID: UUID, body: B?, queryItems: [URLQueryItem] = []) async throws -> T {
        var tokens = try tokenStore.tokens(for: accountID) ?? { throw AccountAPIError.missingSession }()
        if tokens.accessExpiresAt <= Date() { tokens = try await refresh(accountID: accountID, expectedRefreshToken: tokens.refreshToken) }
        do { return try await request(path, method: method, body: body, bearer: tokens.accessToken, root: v3BaseURL, queryItems: queryItems) }
        catch let error as AccountAPIError {
            guard case .status(401, _) = error else { throw error }
            tokens = try await refresh(accountID: accountID, expectedRefreshToken: tokens.refreshToken)
            return try await request(path, method: method, body: body, bearer: tokens.accessToken, root: v3BaseURL, queryItems: queryItems)
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

    private func request<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", body: B?, bearer: String? = nil, root: URL? = nil, queryItems: [URLQueryItem] = []) async throws -> T {
        if let configurationError { throw configurationError }
        let base = (root ?? baseURL).appendingPathComponent(path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw AccountAPIError.invalidConfiguration }
        var value = URLRequest(url: url)
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

    private func submitAppleSignIn(
        identityToken: String,
        authorizationCode: String,
        nonce: String,
        displayName: String,
        email: String,
        platform: String,
        requestID: UUID
    ) async throws -> AccountSessionResponse {
        try await request(
            "auth/apple",
            body: AppleSignInRequest(
                requestID: requestID,
                deviceID: deviceID,
                platform: platform,
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce,
                displayName: displayName,
                email: email
            ),
            root: v3BaseURL
        )
    }

    private static var currentPlatform: String {
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

extension AccountAPIClient: RemoteCellularControlAPI {}
