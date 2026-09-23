import Foundation

actor AccountAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: SecureTokenStore
    private let deviceID: UUID
    private var refreshTasks: [UUID: Task<AccountTokens, Error>] = [:]

    init(config: AppConfig, tokenStore: SecureTokenStore, session: URLSession? = nil, deviceID: UUID = InstallationIdentity.shared.id) {
        let root = config.apiBaseURL.deletingLastPathComponent()
        self.baseURL = root.appendingPathComponent("v2", isDirectory: true)
        self.tokenStore = tokenStore
        self.deviceID = deviceID
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
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

    private func authorized<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", accountID: UUID, body: B?) async throws -> T {
        var tokens = try tokenStore.tokens(for: accountID) ?? { throw AccountAPIError.missingSession }()
        if tokens.accessExpiresAt <= Date() { tokens = try await refresh(accountID: accountID) }
        do { return try await request(path, method: method, body: body, bearer: tokens.accessToken) }
        catch AccountAPIError.status(401, _) {
            let refreshed = try await refresh(accountID: accountID)
            return try await request(path, method: method, body: body, bearer: refreshed.accessToken)
        }
    }

    private func refresh(accountID: UUID) async throws -> AccountTokens {
        if let task = refreshTasks[accountID] { return try await task.value }
        let task = Task<AccountTokens, Error> {
            guard let current = try tokenStore.tokens(for: accountID) else { throw AccountAPIError.missingSession }
            let response: AccountSessionResponse = try await request("auth/refresh", body: AccountRefreshRequest(refreshToken: current.refreshToken, deviceID: deviceID))
            try tokenStore.save(response.tokens, for: accountID)
            return response.tokens
        }
        refreshTasks[accountID] = task
        do {
            let value = try await task.value
            refreshTasks[accountID] = nil
            return value
        } catch {
            refreshTasks[accountID] = nil
            if case let AccountAPIError.status(status, _) = error, status == 401 || status == 403 {
                try? tokenStore.delete(accountID: accountID)
            }
            throw error
        }
    }

    private func request<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", body: B?, bearer: String? = nil) async throws -> T {
        var value = URLRequest(url: baseURL.appendingPathComponent(path))
        value.httpMethod = method
        value.timeoutInterval = 10
        if let body { value.httpBody = try JSONEncoder.account.encode(body) }
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { value.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: value)
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
