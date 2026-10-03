import Foundation

enum AppConfigError: String, Error, Equatable, Sendable, LocalizedError {
    case missingAPIURL = "CONFIG_MISSING_API_URL"
    case invalidAPIURL = "CONFIG_INVALID_API_URL"
    case missingMediaURL = "CONFIG_MISSING_MEDIA_URL"
    case invalidMediaURL = "CONFIG_INVALID_MEDIA_URL"
    case missingDeviceRole = "CONFIG_MISSING_DEVICE_ROLE"
    case invalidDeviceRole = "CONFIG_INVALID_DEVICE_ROLE"
    case missingBearerToken = "CONFIG_MISSING_BEARER_TOKEN"
    case invalidBearerToken = "CONFIG_INVALID_BEARER_TOKEN"

    var errorDescription: String? { rawValue }
}

struct AppConfig: Sendable {
    let apiBaseURL: URL
    let mediaURL: URL
    let role: DeviceRole
    let bearerToken: String
    let configurationError: AppConfigError?

    init(
        apiBaseURL: URL,
        mediaURL: URL,
        role: DeviceRole,
        bearerToken: String,
        configurationError: AppConfigError? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.mediaURL = mediaURL
        self.role = role
        self.bearerToken = bearerToken
        self.configurationError = configurationError
    }

    var isProductionSafe: Bool {
        configurationError == nil &&
        apiBaseURL.scheme == "https" && apiBaseURL.host != nil &&
        mediaURL.scheme == "wss" && mediaURL.host != nil &&
        bearerToken.count >= 32 && !bearerToken.contains(where: { $0.isWhitespace })
    }

    static func load(bundle: Bundle = .main) -> AppConfig {
        resolve(values: [
            "API_BASE_URL": bundle.object(forInfoDictionaryKey: "API_BASE_URL") as? String ?? "",
            "MEDIA_BASE_URL": bundle.object(forInfoDictionaryKey: "MEDIA_BASE_URL") as? String ?? "",
            "DEVICE_ROLE": bundle.object(forInfoDictionaryKey: "DEVICE_ROLE") as? String ?? "",
            "BEARER_TOKEN": bundle.object(forInfoDictionaryKey: "BEARER_TOKEN") as? String ?? "",
        ])
    }

    static func resolve(values: [String: String]) -> AppConfig {
        guard let apiValue = requiredValue("API_BASE_URL", in: values) else {
            return failed(.missingAPIURL)
        }
        guard let api = URL(string: apiValue), api.scheme == "https", api.host != nil else {
            return failed(.invalidAPIURL)
        }
        guard let mediaValue = requiredValue("MEDIA_BASE_URL", in: values) else {
            return failed(.missingMediaURL)
        }
        guard let media = URL(string: mediaValue), media.scheme == "wss", media.host != nil else {
            return failed(.invalidMediaURL)
        }
        guard let roleValue = requiredValue("DEVICE_ROLE", in: values) else {
            return failed(.missingDeviceRole)
        }
        guard let role = DeviceRole(rawValue: roleValue) else {
            return failed(.invalidDeviceRole)
        }
        guard let token = requiredValue("BEARER_TOKEN", in: values) else {
            return failed(.missingBearerToken)
        }
        guard token.count >= 32, !token.contains(where: { $0.isWhitespace }) else {
            return failed(.invalidBearerToken)
        }
        return AppConfig(apiBaseURL: api, mediaURL: media, role: role, bearerToken: token)
    }

    private static func requiredValue(_ key: String, in values: [String: String]) -> String? {
        guard let value = values[key], !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func failed(_ error: AppConfigError) -> AppConfig {
        AppConfig(
            apiBaseURL: URL(string: "wifisecurecall-config-error://blocked/api")!,
            mediaURL: URL(string: "wifisecurecall-config-error://blocked/media")!,
            role: .B,
            bearerToken: "",
            configurationError: error
        )
    }
}

enum CallTimeouts {
    static let ring: TimeInterval = 30
    static let httpRequest: TimeInterval = 8
    static let audioActivation: TimeInterval = 5
    static let initialMedia: TimeInterval = 5
    static let reconnectTotal: TimeInterval = 10

    /// watchOS grants the audio-streaming networking exception (TN3135) only while a call audio
    /// session is running, and the low-level media path is observed to be withdrawn and restored
    /// periodically. Media reconnects on watchOS therefore get a wider recovery window than on iOS
    /// so an expected path revocation does not terminate an otherwise healthy call.
    static var mediaReconnectTotal: TimeInterval {
        #if os(watchOS)
        return 45
        #else
        return reconnectTotal
        #endif
    }
}
