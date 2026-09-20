import Foundation

enum APIClientError: Error { case invalidResponse, status(Int), decoding }

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
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; self.decoder = decoder
    }

    func health() async throws -> HealthResponse { try await request("health", method: "GET", body: Optional<Data>.none) }

    func registerDevice(token: Data) async throws {
        let value = token.map { String(format: "%02x", $0) }.joined()
        let body = DeviceRegistrationRequest(requestID: UUID(), role: config.role, token: value, platform: config.role == .A ? "watchOS" : "iOS")
        let _: EmptyResponse = try await request("devices/register", body: try encoder.encode(body))
    }

    func reportNotificationDiagnostic(event: String, status: String, tokenPrefix: String? = nil, tokenLength: Int? = nil) async {
        let body = NotificationDiagnosticRequest(
            requestID: UUID(),
            role: config.role,
            platform: config.role == .A ? "watchOS" : "iOS",
            event: event,
            status: status,
            tokenPrefix: tokenPrefix,
            tokenLength: tokenLength
        )
        guard let data = try? encoder.encode(body) else { return }
        let _: EmptyResponse? = try? await request("devices/diagnostics", body: data)
    }

    func create(callID: UUID, requestID: UUID) async throws -> CallResponse {
        try await request("calls", body: try encoder.encode(CreateCallRequest(requestID: requestID, callID: callID)))
    }

    func call(_ id: UUID) async throws -> CallResponse { try await request("calls/\(id.uuidString.lowercased())", method: "GET", body: Optional<Data>.none) }

    func mutate(_ action: String, callID: UUID, requestID: UUID = UUID()) async throws -> CallResponse {
        try await request("calls/\(callID.uuidString.lowercased())/\(action)", body: try encoder.encode(CallMutationRequest(requestID: requestID)))
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
        guard 200..<300 ~= http.statusCode else { throw APIClientError.status(http.statusCode) }
        if T.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! T }
        guard let decoded = try? decoder.decode(T.self, from: data) else { throw APIClientError.decoding }
        return decoded
    }
}

private struct EmptyResponse: Codable {}
