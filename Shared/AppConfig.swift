import Foundation

struct AppConfig: Sendable {
    let apiBaseURL: URL
    let mediaURL: URL
    let role: DeviceRole
    let bearerToken: String

    var isProductionSafe: Bool {
        apiBaseURL.scheme == "https" && mediaURL.scheme == "wss" &&
        bearerToken.count >= 32 && !bearerToken.contains(where: { $0.isWhitespace })
    }

    static func load(bundle: Bundle = .main) -> AppConfig {
        func value(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty, !value.contains("$(") else { return nil }
            return value
        }
        if let apiValue = value("API_BASE_URL"), let mediaValue = value("MEDIA_BASE_URL"),
           let api = URL(string: apiValue), let media = URL(string: mediaValue),
           let roleValue = value("DEVICE_ROLE"), let role = DeviceRole(rawValue: roleValue),
           let token = value("BEARER_TOKEN") {
            let config = AppConfig(apiBaseURL: api, mediaURL: media, role: role, bearerToken: token)
            if config.isProductionSafe { return config }
        }
        return AppConfig(
            apiBaseURL: URL(string: "https://invalid.invalid/v1")!,
            mediaURL: URL(string: "wss://invalid.invalid/media")!,
            role: .B,
            bearerToken: "invalid"
        )
    }
}

enum CallTimeouts {
    static let ring: TimeInterval = 30
    static let httpRequest: TimeInterval = 8
    static let audioActivation: TimeInterval = 5
    static let initialMedia: TimeInterval = 5
    static let reconnectTotal: TimeInterval = 10
}
