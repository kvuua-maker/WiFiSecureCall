import CryptoKit
import Foundation
import Security



enum AppleSignInNonceContract {
    enum GenerationError: Error { case entropyUnavailable }

    static func makeRawNonce(byteCount: Int = 32) throws -> String {
        precondition(byteCount > 0)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GenerationError.entropyUnavailable
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // One transformation only: Apple receives lowercase hex SHA-256(rawNonce).
    static func requestNonce(forRawNonce rawNonce: String) -> String {
        SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // Our server receives the original value and hashes it once for comparison.
    static func serverNonce(forRawNonce rawNonce: String) -> String { rawNonce }
}

enum AppleVerificationDiagnostic: String, Codable, Sendable {
    case jwtFormat = "APPLE_VERIFY_JWT_FORMAT"
    case header = "APPLE_VERIFY_HEADER"
    case keyFetch = "APPLE_VERIFY_KEY_FETCH"
    case signature = "APPLE_VERIFY_SIGNATURE"
    case issuer = "APPLE_VERIFY_ISSUER"
    case audience = "APPLE_VERIFY_AUDIENCE"
    case expired = "APPLE_VERIFY_EXPIRED"
    case nonce = "APPLE_VERIFY_NONCE"
    case serverRequest = "APPLE_VERIFY_SERVER_REQUEST"
    case serverResponse = "APPLE_VERIFY_SERVER_RESPONSE"

    static func classify(_ error: Error) -> Self {
        guard let apiError = error as? AccountAPIError else { return .serverRequest }
        switch apiError {
        case .status(_, let response):
            if let response, let diagnostic = Self(rawValue: response.error) { return diagnostic }
            return .serverResponse
        case .invalidResponse, .decoding:
            return .serverResponse
        case .invalidConfiguration, .missingSession:
            return .serverRequest
        }
    }
}

enum E164Phone {
    static func canonicalized(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    }

    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil
    }
}

struct VerifiedPhone: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let maskedNumber: String
}

struct UserProfile: Codable, Equatable, Sendable {
    let userID: UUID
    let username: String
    let displayName: String?
    let email: String?
    let verifiedPhones: [String]
    let publicIdentity: String
}

struct AccountSummary: Codable, Identifiable, Equatable, Sendable {
    let accountID: UUID
    let userID: UUID?
    let phoneNumber: String?
    let displayLabel: String
    var id: UUID { accountID }

    init(accountID: UUID, phoneNumber: String) {
        self.accountID = accountID
        self.userID = nil
        self.phoneNumber = phoneNumber
        self.displayLabel = phoneNumber
    }

    init(accountID: UUID, userID: UUID?, phoneNumber: String?, displayLabel: String) {
        self.accountID = accountID
        self.userID = userID
        self.phoneNumber = phoneNumber
        self.displayLabel = displayLabel.isEmpty ? (phoneNumber ?? "Secure account") : displayLabel
    }

    private enum CodingKeys: String, CodingKey { case accountID, userID, phoneNumber, displayLabel }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(UUID.self, forKey: .accountID)
        userID = try values.decodeIfPresent(UUID.self, forKey: .userID)
        phoneNumber = try values.decodeIfPresent(String.self, forKey: .phoneNumber)
        displayLabel = try values.decodeIfPresent(String.self, forKey: .displayLabel) ?? phoneNumber ?? "Secure account"
    }
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
    let user: UserProfile?
    init(account: AccountSummary, deviceID: UUID, accessToken: String, accessExpiresAt: Date, refreshToken: String, refreshExpiresAt: Date, user: UserProfile? = nil) {
        self.account = account; self.deviceID = deviceID; self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken; self.refreshExpiresAt = refreshExpiresAt; self.user = user
    }
    var tokens: AccountTokens { AccountTokens(accessToken: accessToken, accessExpiresAt: accessExpiresAt, refreshToken: refreshToken, refreshExpiresAt: refreshExpiresAt) }
}

struct PhoneStartResponse: Codable, Sendable { let verificationID: UUID; let expiresAt: Date; let resendAfter: Date }
struct PhoneStartRequest: Codable, Sendable { let requestID: UUID; let phoneNumber: String }
struct PhoneVerifyRequest: Codable, Sendable { let requestID: UUID; let verificationID: UUID; let code: String; let deviceID: UUID; let platform: String }
struct AccountRefreshRequest: Codable, Sendable { let refreshToken: String; let deviceID: UUID }
struct AccountDeleteRequest: Codable, Sendable { let confirm: String }
struct AppleSignInRequest: Codable, Sendable {
    let requestID: UUID
    let deviceID: UUID
    let platform: String
    let identityToken: String
    let authorizationCode: String
    let nonce: String
    let displayName: String
    let email: String
}
struct UsernameUpdateRequest: Codable, Sendable { let username: String }
struct PhoneBindingVerifyRequest: Codable, Sendable { let verificationID: UUID; let code: String }

struct AccountDeviceRegistrationRequest: Codable, Sendable {
    let requestID: UUID
    let deviceID: UUID
    let platform: String
    let pushType: DevicePushType
    let token: String
    let invalidatedToken: String?
    let installationGeneration: UInt64
    let environment: APNSEnvironment
    let capabilities: DeviceCapabilities
}

struct AccountDeviceSummary: Codable, Equatable, Sendable, Identifiable {
    let deviceID: UUID
    let platform: String
    let callReady: Bool
    let lastSeenAt: Date
    var id: UUID { deviceID }
}

struct AccountCallCreateRequest: Codable, Sendable {
    let requestID: UUID
    let callID: UUID
    let targetDeviceID: UUID
}

struct AccountCallMutationRequest: Codable, Sendable { let requestID: UUID }

struct AccountCallResponse: Codable, Equatable, Sendable {
    let callID: UUID
    let localSide: CallPartySide
    let state: ServerCallState
    let expiresAt: Date
    let mediaToken: String?
    let ringExpiresAt: Date?
    let acceptedAt: Date?
    let terminalAt: Date?
    let terminalReason: String?
    let deliveryStatus: String?
    let peerReady: Bool?
    let createdNew: Bool?
    let mutationApplied: Bool?
}

struct AccountMeResponse: Codable, Sendable {
    let accountID: UUID
    let phoneNumber: String?
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
    let displayLabel: String?
    let userID: UUID?
    let accessToken: String?
    let accessExpiresAt: Date?
    let refreshToken: String?
    let refreshExpiresAt: Date?
    init(status: String, accountID: UUID?, phoneNumber: String?, displayLabel: String? = nil, userID: UUID? = nil, accessToken: String?, accessExpiresAt: Date?, refreshToken: String?, refreshExpiresAt: Date?) {
        self.status = status; self.accountID = accountID; self.phoneNumber = phoneNumber; self.displayLabel = displayLabel; self.userID = userID
        self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt; self.refreshToken = refreshToken; self.refreshExpiresAt = refreshExpiresAt
    }
}

struct AccountAPIErrorResponse: Codable, Error, Sendable { let error: String; let retryAt: Date? }
enum AccountAPIError: Error { case invalidConfiguration, invalidResponse, status(Int, AccountAPIErrorResponse?), missingSession, decoding }
