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

struct AppleSignInAttempt: Equatable, Sendable {
    let rawNonce: String
    let requestNonce: String
    let state: String

    static func make() throws -> Self {
        let rawNonce = try AppleSignInNonceContract.makeRawNonce()
        var state = try AppleSignInNonceContract.makeRawNonce()
        while state == rawNonce {
            state = try AppleSignInNonceContract.makeRawNonce()
        }
        return Self(
            rawNonce: rawNonce,
            requestNonce: AppleSignInNonceContract.requestNonce(forRawNonce: rawNonce),
            state: state
        )
    }
}

struct AppleNativeCredentialInput: Sendable {
    let state: String?
    let identityToken: Data?
    let authorizationCode: Data?
    let displayName: String
    let email: String
}

struct ValidatedAppleCredential: Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
    let displayName: String
    let email: String
}

enum AppleCredentialValidationError: String, Error, Equatable, Sendable {
    case stateMismatch = "APPLE_STATE_MISMATCH"
    case missingIdentityToken = "APPLE_IDENTITY_TOKEN_MISSING"
    case missingAuthorizationCode = "APPLE_AUTHORIZATION_CODE_MISSING"
    case missingNonce = "APPLE_NONCE_MISSING"
}

enum AppleCredentialContract {
    static func validate(
        _ credential: AppleNativeCredentialInput,
        expectedState: String,
        rawNonce: String
    ) throws -> ValidatedAppleCredential {
        guard !rawNonce.isEmpty else { throw AppleCredentialValidationError.missingNonce }
        guard credential.state == expectedState else { throw AppleCredentialValidationError.stateMismatch }
        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8),
              !identityToken.isEmpty else {
            throw AppleCredentialValidationError.missingIdentityToken
        }
        guard let authorizationCodeData = credential.authorizationCode,
              let authorizationCode = String(data: authorizationCodeData, encoding: .utf8),
              !authorizationCode.isEmpty else {
            throw AppleCredentialValidationError.missingAuthorizationCode
        }
        return ValidatedAppleCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: AppleSignInNonceContract.serverNonce(forRawNonce: rawNonce),
            displayName: credential.displayName,
            email: credential.email
        )
    }
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
    case dns = "APPLE_VERIFY_DNS"
    case tls = "APPLE_VERIFY_TLS"
    case timeout = "APPLE_VERIFY_TIMEOUT"
    case connection = "APPLE_VERIFY_CONNECTION"
    case networkLost = "APPLE_VERIFY_NETWORK_LOST"
    case offline = "APPLE_VERIFY_OFFLINE"
    case cancelled = "APPLE_VERIFY_CANCELLED"
    case otherTransport = "APPLE_VERIFY_OTHER_TRANSPORT"

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
        case .transport(let domain, let code):
            return transportDiagnostic(domain: domain, code: code)
        }
    }

    static func safeTransportDetail(_ error: Error) -> String? {
        guard let apiError = error as? AccountAPIError,
              case .transport(let domain, let code) = apiError,
              transportDiagnostic(domain: domain, code: code) == .otherTransport else { return nil }
        return "\(domain) \(code)"
    }

    private static func transportDiagnostic(domain: String, code: Int) -> Self {
        guard domain == NSURLErrorDomain else { return .otherTransport }
        switch URLError.Code(rawValue: code) {
        case .cannotFindHost, .dnsLookupFailed:
            return .dns
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .tls
        case .timedOut:
            return .timeout
        case .cannotConnectToHost, .cannotLoadFromNetwork, .resourceUnavailable:
            return .connection
        case .networkConnectionLost:
            return .networkLost
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return .offline
        case .cancelled:
            return .cancelled
        default:
            return .otherTransport
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

struct RecipientResolveRequest: Codable, Sendable { let recipient: String }

struct ResolvedRecipient: Codable, Equatable, Sendable {
    let userID: UUID
    let username: String
    let displayName: String?
    let publicIdentity: String
    let phoneNumber: String?
}

struct CrossUserCallCreateRequest: Codable, Sendable {
    let requestID: UUID
    let callID: UUID
    let targetUserID: UUID
}

enum RemoteCellularControlState: String, Codable, Equatable, Sendable {
    case deliveryPending = "iphone_delivery_pending"
    case iPhoneActionRequired = "iphone_action_required"
    case iPhoneStartAuthorized = "iphone_start_authorized"
    case startRequested = "iphone_start_requested"
    case cancelled
    case expired
    case failedSafe = "failed_safe"
}

struct RemoteCellularControlCreateRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let phoneNumber: String
}

struct RemoteCellularControlMutationRequest: Codable, Equatable, Sendable {
    let requestID: UUID
}

struct RemoteCellularControlView: Codable, Equatable, Sendable {
    let requestID: UUID
    let state: RemoteCellularControlState
    let createdAt: Date
    let expiresAt: Date
    let deliveryStatus: String?
    let sourcePlatform: String
    let targetPlatform: String
    let sameOwnerAuthorized: Bool
    let mutationApplied: Bool?
}

struct RemoteCellularControlStartGrant: Codable, Sendable {
    let requestID: UUID
    let state: RemoteCellularControlState
    let createdAt: Date
    let expiresAt: Date
    let deliveryStatus: String?
    let sourcePlatform: String
    let targetPlatform: String
    let sameOwnerAuthorized: Bool
    let mutationApplied: Bool?
    let terminalReason: String?
    let phoneNumber: String?

    var control: RemoteCellularControlView {
        RemoteCellularControlView(
            requestID: requestID, state: state, createdAt: createdAt, expiresAt: expiresAt,
            deliveryStatus: deliveryStatus, sourcePlatform: sourcePlatform,
            targetPlatform: targetPlatform, sameOwnerAuthorized: sameOwnerAuthorized,
            mutationApplied: mutationApplied
        )
    }

    var startGranted: Bool {
        state == .iPhoneStartAuthorized && mutationApplied == true && phoneNumber != nil
    }

    init(control: RemoteCellularControlView, startGranted: Bool, phoneNumber: String?) {
        requestID = control.requestID
        state = control.state
        createdAt = control.createdAt
        expiresAt = control.expiresAt
        deliveryStatus = control.deliveryStatus
        sourcePlatform = control.sourcePlatform
        targetPlatform = control.targetPlatform
        sameOwnerAuthorized = control.sameOwnerAuthorized
        mutationApplied = startGranted
        terminalReason = nil
        self.phoneNumber = phoneNumber
    }
}

struct RemoteCellularControlPushEnvelope: Equatable, Sendable {
    let requestID: UUID
    let accountID: UUID

    static func parse(_ payload: [AnyHashable: Any]) -> Self? {
        guard payload["event"] as? String == "remote_cellular_control",
              let requestValue = payload["requestID"] as? String,
              let accountValue = payload["accountID"] as? String,
              let requestID = UUID(uuidString: requestValue),
              let accountID = UUID(uuidString: accountValue) else { return nil }
        return Self(requestID: requestID, accountID: accountID)
    }
}

enum RemoteCellularControlPolicy {
    static let requestTTL: TimeInterval = 120

    static func normalizedE164(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}

enum RemoteCellularReceiptContext: String, Codable, Equatable, Sendable {
    case foreground
    case background
    case openedFromNotification = "opened_from_notification"
}

struct RemoteCellularControlDiagnostic: Codable, Equatable, Sendable {
    let requestID: UUID
    let accountID: UUID
    let expiresAt: Date?
    let state: RemoteCellularControlState
    let receiptContext: RemoteCellularReceiptContext
    let sameOwnerAuthorized: Bool
    let userActionRequired: Bool
    let systemStartAttempted: Bool
    let safeResult: String
}

protocol RemoteCellularControlAPI: Sendable {
    func createRemoteCellularControl(accountID: UUID, requestID: UUID, phoneNumber: String) async throws -> RemoteCellularControlView
    func remoteCellularControl(accountID: UUID, requestID: UUID) async throws -> RemoteCellularControlView
    func receiveRemoteCellularControl(accountID: UUID, requestID: UUID, mutationID: UUID) async throws -> RemoteCellularControlView
    func claimRemoteCellularControlStart(accountID: UUID, requestID: UUID, mutationID: UUID) async throws -> RemoteCellularControlStartGrant
    func markRemoteCellularControlStartRequested(accountID: UUID, requestID: UUID, mutationID: UUID) async throws -> RemoteCellularControlView
    func cancelRemoteCellularControl(accountID: UUID, requestID: UUID, mutationID: UUID) async throws -> RemoteCellularControlView
}

enum CrossUserLegState: String, Codable, Sendable {
    case ringing
    case accepted
    case rejected
    case answeredElsewhere = "answered_elsewhere"
    case unavailable
    case cancelled
    case expired
    case ended
}

struct CrossUserCallerIdentity: Codable, Equatable, Sendable {
    let username: String
    let displayName: String?
    let publicIdentity: String

    var callKitName: String {
        if let displayName, !displayName.isEmpty { return "\(displayName) (@\(username))" }
        return "@\(username)"
    }
}

struct CrossUserCallResponse: Codable, Equatable, Sendable {
    let callID: UUID
    let localSide: CallPartySide
    let state: ServerCallState
    let legState: CrossUserLegState?
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
    let caller: CrossUserCallerIdentity?
}

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
enum AccountAPIError: Error {
    case invalidConfiguration
    case invalidResponse
    case status(Int, AccountAPIErrorResponse?)
    case missingSession
    case decoding
    case transport(domain: String, code: Int)

    static func wrappingTransport(_ error: Error) -> Self {
        let value = error as NSError
        let safeDomain = value.domain.range(of: #"^[A-Za-z0-9._-]{1,80}$"#, options: .regularExpression) == nil
            ? "TransportError"
            : value.domain
        return .transport(domain: safeDomain, code: value.code)
    }
}
