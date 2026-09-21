import Foundation

enum APIClientError: Error { case invalidResponse, status(Int, ServerErrorResponse?), decoding }

struct APIClient: Sendable {
    let config: AppConfig
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(config: AppConfig, session: URLSession? = nil) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = CallTimeouts.httpRequest
        configuration.timeoutIntervalForResource = CallTimeouts.httpRequest
        configuration.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: configuration)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: value) ?? ISO8601DateFormatter.whole.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid RFC3339 timestamp")
        }
        self.decoder = decoder
    }

    func health() async throws -> HealthResponse { try await request("health", method: "GET", body: Optional<Data>.none) }

    func registerDevice(token: Data, pushType: DevicePushType = .alert, capabilities: DeviceCapabilities? = nil) async throws {
        let value = token.map { String(format: "%02x", $0) }.joined()
        let body = DeviceRegistrationRequest(
            requestID: UUID(),
            role: config.role,
            token: value,
            platform: config.role == .A ? "watchOS" : "iOS",
            pushType: pushType,
            installationID: InstallationIdentity.shared.id,
            installationGeneration: InstallationIdentity.shared.generation,
            environment: .production,
            capabilities: capabilities
        )
        let _: EmptyResponse = try await request("devices/register", body: try encoder.encode(body))
    }

    func invalidateDevice(pushType: DevicePushType, expectedToken: Data?) async {
        let invalidatedToken = expectedToken?.map { String(format: "%02x", $0) }.joined()
        let body = DeviceRegistrationRequest(
            requestID: UUID(),
            role: config.role,
            token: "",
            invalidatedToken: invalidatedToken,
            platform: config.role == .A ? "watchOS" : "iOS",
            pushType: pushType,
            installationID: InstallationIdentity.shared.id,
            installationGeneration: InstallationIdentity.shared.generation,
            environment: .production,
            capabilities: nil
        )
        guard let data = try? encoder.encode(body) else { return }
        let _: EmptyResponse? = try? await request("devices/register", body: data)
    }

    func reportNotificationDiagnostic(event: String, status: String, tokenPrefix: String? = nil, tokenLength: Int? = nil) async {
        let body = NotificationDiagnosticRequest(
            requestID: UUID(),
            role: config.role,
            platform: config.role == .A ? "watchOS" : "iOS",
            event: event,
            status: status,
            tokenPrefix: tokenPrefix,
            tokenLength: tokenLength,
            stage: nil,
            errorDomain: nil,
            errorCode: nil,
            callID: nil
        )
        guard let data = try? encoder.encode(body) else { return }
        let _: EmptyResponse? = try? await request("devices/diagnostics", body: data)
    }


    func reportCallKitError(stage: String, callID: UUID, error: Error) async {
        let value = error as NSError
        let body = NotificationDiagnosticRequest(
            requestID: UUID(),
            role: config.role,
            platform: config.role == .A ? "watchOS" : "iOS",
            event: "callkit_error",
            status: "failed",
            tokenPrefix: nil,
            tokenLength: nil,
            stage: stage,
            errorDomain: value.domain,
            errorCode: value.code,
            callID: callID
        )
        guard let data = try? encoder.encode(body) else { return }
        let _: EmptyResponse? = try? await request("devices/diagnostics", body: data)
    }

    func reportRuntimeDiagnostic(
        event: String,
        status: String,
        callID: UUID?,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) async {
        let body = NotificationDiagnosticRequest(
            requestID: UUID(),
            role: config.role,
            platform: config.role == .A ? "watchOS" : "iOS",
            event: event,
            status: status,
            tokenPrefix: nil,
            tokenLength: nil,
            stage: nil,
            errorDomain: errorDomain,
            errorCode: errorCode,
            callID: callID
        )
        guard let data = try? encoder.encode(body) else { return }
        let _: EmptyResponse? = try? await request("devices/diagnostics", body: data)
    }

    func create(callID: UUID, requestID: UUID) async throws -> CallResponse {
        try await request("calls", body: try encoder.encode(CreateCallRequest(requestID: requestID, callID: callID)))
    }

    func call(_ id: UUID) async throws -> CallResponse { try await request("calls/\(id.uuidString.lowercased())", method: "GET", body: Optional<Data>.none) }

    func mutate(_ action: CallMutation, callID: UUID, requestID: UUID) async throws -> CallResponse {
        try await request("calls/\(callID.uuidString.lowercased())/\(action.rawValue)", body: try encoder.encode(CallMutationRequest(requestID: requestID)))
    }

    private func request<T: Decodable>(_ path: String, method: String = "POST", body: Data?) async throws -> T {
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = CallTimeouts.httpRequest
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw APIClientError.status(http.statusCode, try? decoder.decode(ServerErrorResponse.self, from: data))
        }
        if T.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! T }
        guard let decoded = try? decoder.decode(T.self, from: data) else { throw APIClientError.decoding }
        return decoded
    }
}

private extension ISO8601DateFormatter {
    static let whole: ISO8601DateFormatter = { let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime]; return value }()
    static let fractional: ISO8601DateFormatter = { let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value }()
}

final class InstallationIdentity: @unchecked Sendable {
    static let shared = InstallationIdentity()
    let id: UUID
    let generation: UInt64

    private init(defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: "WiFiSecureCall.installationID"), let stored = UUID(uuidString: raw) { id = stored }
        else { let created = UUID(); id = created; defaults.set(created.uuidString, forKey: "WiFiSecureCall.installationID") }
        let storedGeneration = UInt64(max(0, defaults.integer(forKey: "WiFiSecureCall.installationGeneration")))
        generation = storedGeneration == 0 ? 1 : storedGeneration
        if storedGeneration == 0 { defaults.set(1, forKey: "WiFiSecureCall.installationGeneration") }
    }
}

private struct EmptyResponse: Codable {}
