import Foundation

enum E164Phone {
    static func canonicalized(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    }

    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil
    }
}

struct AccountSummary: Codable, Identifiable, Equatable, Sendable {
    let accountID: UUID
    let phoneNumber: String
    var id: UUID { accountID }
}

struct AccountTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
    let refreshExpiresAt: Date
}

struct AccountSessionResponse: Codable, Sendable {
    let account: AccountSummary
    let deviceID: UUID
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
    let refreshExpiresAt: Date
    var tokens: AccountTokens { AccountTokens(accessToken: accessToken, accessExpiresAt: accessExpiresAt, refreshToken: refreshToken, refreshExpiresAt: refreshExpiresAt) }
}

struct PhoneStartResponse: Codable, Sendable { let verificationID: UUID; let expiresAt: Date; let resendAfter: Date }
struct PhoneStartRequest: Codable, Sendable { let requestID: UUID; let phoneNumber: String }
struct PhoneVerifyRequest: Codable, Sendable { let requestID: UUID; let verificationID: UUID; let code: String; let deviceID: UUID; let platform: String }
struct AccountRefreshRequest: Codable, Sendable { let refreshToken: String; let deviceID: UUID }
struct AccountDeleteRequest: Codable, Sendable { let confirm: String }

struct AccountMeResponse: Codable, Sendable {
    let accountID: UUID
    let phoneNumber: String
    let deviceID: UUID
    let platform: String
}

struct WatchLinkStartRequest: Codable, Sendable { let requestID: UUID; let deviceID: UUID; let platform: String }
struct WatchLinkStartResponse: Codable, Sendable { let linkID: UUID; let linkSecret: String; let code: String; let expiresAt: Date }
struct WatchLinkClaimRequest: Codable, Sendable { let requestID: UUID; let code: String }
struct WatchLinkStatusRequest: Codable, Sendable { let linkID: UUID; let linkSecret: String }
struct WatchLinkStatusResponse: Codable, Sendable {
    let status: String
    let accountID: UUID?
    let phoneNumber: String?
    let accessToken: String?
    let accessExpiresAt: Date?
    let refreshToken: String?
    let refreshExpiresAt: Date?
}

struct AccountAPIErrorResponse: Codable, Error, Sendable { let error: String; let retryAt: Date? }
enum AccountAPIError: Error { case invalidConfiguration, invalidResponse, status(Int, AccountAPIErrorResponse?), missingSession, decoding }
