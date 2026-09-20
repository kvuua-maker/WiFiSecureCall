import Foundation

struct AppConfig: Sendable {
    let apiBaseURL: URL
    let mediaURL: URL
    let role: DeviceRole
    let bearerToken: String

    static func load(bundle: Bundle = .main) -> AppConfig {
        func required(_ key: String) -> String {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty, !value.contains("$(") else {
                preconditionFailure("Missing client configuration: \(key)")
            }
            return value
        }
        guard let api = URL(string: required("API_BASE_URL")),
              let media = URL(string: required("MEDIA_BASE_URL")),
              let role = DeviceRole(rawValue: required("DEVICE_ROLE")) else {
            preconditionFailure("Invalid client configuration")
        }
        return AppConfig(apiBaseURL: api, mediaURL: media, role: role, bearerToken: required("BEARER_TOKEN"))
    }
}

enum CallTimeouts {
    static let ring: TimeInterval = 30
    static let httpConnect: TimeInterval = 5
    static let httpRequest: TimeInterval = 8
    static let audioActivation: TimeInterval = 5
    static let initialMedia: TimeInterval = 5
    static let reconnectTotal: TimeInterval = 10
}

