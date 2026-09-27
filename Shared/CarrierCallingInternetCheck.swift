import Foundation

enum CarrierCallingFirstPartyInternetState: String, Codable, Equatable, Sendable {
    case notChecked = "NOT_CHECKED"
    case checking = "CHECKING"
    case success = "SUCCESS"
    case failureSafe = "FAILURE_SAFE"
}

enum CarrierCallingFirstPartyInternetCheck {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func request(config: AppConfig) -> URLRequest? {
        guard config.configurationError == nil,
              config.apiBaseURL.scheme == "https" else { return nil }
        var request = URLRequest(
            url: config.apiBaseURL.appendingPathComponent("health"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 5
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        return request
    }

    static func run(config: AppConfig = .load()) async -> CarrierCallingFirstPartyInternetState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return await run(config: config) { request in
            try await session.data(for: request)
        }
    }

    static func run(config: AppConfig, loader: Loader) async -> CarrierCallingFirstPartyInternetState {
        guard let request = request(config: config) else { return .failureSafe }
        do {
            let (data, response) = try await loader(request)
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode,
                  (try? JSONDecoder().decode(Health.self, from: data).ok) == true else {
                return .failureSafe
            }
            return .success
        } catch {
            return .failureSafe
        }
    }

    private struct Health: Decodable { let ok: Bool }
}
