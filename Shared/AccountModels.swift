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
    case dns = "APPLE_VERIFY_DNS"
    case tls = "APPLE_VERIFY_TLS"
    case timeout = "APPLE_VERIFY_TIMEOUT"
    case connection = "APPLE_VERIFY_CONNECTION"
    case networkLost = "APPLE_VERIFY_NETWORK_LOST"
    case offline = "APPLE_VERIFY_OFFLINE"
    case cancelled = "APPLE_VERIFY_CANCELLED"
    case otherTransport = "APPLE_VERIFY_OTHER_TRANSPORT"

    static func classify(_ error: Error) -> Self {
        let apiError: AccountAPIError
        if let diagnosticError = error as? AppleSignInDiagnosticFailure {
            apiError = diagnosticError.underlying
        } else if let accountError = error as? AccountAPIError {
            apiError = accountError
        } else {
            return .serverRequest
        }
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
        let apiError = (error as? AppleSignInDiagnosticFailure)?.underlying ?? (error as? AccountAPIError)
        guard let apiError,
              case .transport(let domain, let code) = apiError,
              transportDiagnostic(domain: domain, code: code) == .otherTransport else { return nil }
        return "\(domain) \(code)"
    }

    static func transportReport(_ error: Error) -> AppleTransportDiagnosticReport? {
        (error as? AppleSignInDiagnosticFailure)?.report
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

struct AppleTransportPathSnapshot: Equatable, Sendable {
    enum Status: String, Sendable { case satisfied, unsatisfied, requiresConnection, unknown }
    enum InterfaceKind: String, Comparable, Sendable {
        case wifi, cellular, wiredEthernet, other
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let status: Status
    let interfaces: [InterfaceKind]
    let isExpensive: Bool
    let isConstrained: Bool

    var safeDescription: String {
        let interfaceText = interfaces.isEmpty ? "none" : interfaces.sorted().map(\.rawValue).joined(separator: "+")
        return "status=\(status.rawValue),interfaces=\(interfaceText),expensive=\(isExpensive),constrained=\(isConstrained)"
    }
}

struct AppleTransportPhaseSnapshot: Equatable, Sendable {
    let startMilliseconds: Int?
    let durationMilliseconds: Int?

    static func capture(start: Date?, end: Date?, relativeTo origin: Date) -> Self {
        let startMilliseconds = start.map { max(0, Int(($0.timeIntervalSince(origin) * 1_000).rounded())) }
        let durationMilliseconds: Int?
        if let start, let end {
            durationMilliseconds = max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
        } else {
            durationMilliseconds = nil
        }
        return Self(startMilliseconds: startMilliseconds, durationMilliseconds: durationMilliseconds)
    }

    var safeDescription: String {
        "start=\(startMilliseconds.map(String.init) ?? "missing"),duration=\(durationMilliseconds.map(String.init) ?? "missing")"
    }
}

struct AppleTransportTransactionSnapshot: Equatable, Sendable {
    let fetchStartMilliseconds: Int?
    let domainLookup: AppleTransportPhaseSnapshot
    let connect: AppleTransportPhaseSnapshot
    let secureConnection: AppleTransportPhaseSnapshot
    let request: AppleTransportPhaseSnapshot
    let response: AppleTransportPhaseSnapshot
    let networkProtocolName: String?
    let isProxyConnection: Bool
    let isReusedConnection: Bool
    let resourceFetchType: String

    var safeDescription: String {
        [
            "fetchStart=\(fetchStartMilliseconds.map(String.init) ?? "missing")",
            "dns={\(domainLookup.safeDescription)}",
            "connect={\(connect.safeDescription)}",
            "tls={\(secureConnection.safeDescription)}",
            "request={\(request.safeDescription)}",
            "response={\(response.safeDescription)}",
            "protocol=\(networkProtocolName ?? "missing")",
            "proxy=\(isProxyConnection)",
            "reused=\(isReusedConnection)",
            "fetchType=\(resourceFetchType)",
        ].joined(separator: ",")
    }
}

enum AppleTaskLifecycleState: String, Equatable, Sendable {
    case running, suspended, canceling, completed

    static func capture(_ state: URLSessionTask.State) -> Self {
        switch state {
        case .running: return .running
        case .suspended: return .suspended
        case .canceling: return .canceling
        case .completed: return .completed
        @unknown default: return .completed
        }
    }
}

enum AppleTaskLifecycleEventKind: String, Equatable, Sendable {
    case taskCreated = "task_created"
    case beforeResume = "before_resume"
    case afterResume = "after_resume"
    case waitingForConnectivity = "waiting_for_connectivity"
    case metricsCollected = "metrics_collected"
    case responseReceived = "response_received"
    case dataReceived = "data_received"
    case taskCompleted = "task_completed"
    case sessionInvalidated = "session_invalidated"
}

struct AppleTaskLifecycleEvent: Equatable, Sendable {
    let kind: AppleTaskLifecycleEventKind
    let elapsedMilliseconds: Int
    let taskIdentifier: Int
    let state: AppleTaskLifecycleState
    let transactionCount: Int?
    let errorDomain: String?
    let errorCode: Int?

    var safeDescription: String {
        var values = [
            kind.rawValue,
            "ms=\(elapsedMilliseconds)",
            "taskID=\(taskIdentifier)",
            "state=\(state.rawValue)",
        ]
        if let transactionCount { values.append("transactions=\(transactionCount)") }
        if let errorDomain { values.append("error=\(errorDomain)/\(errorCode ?? 0)") }
        return values.joined(separator: ",")
    }
}

struct AppleTaskRequestSnapshot: Equatable, Sendable {
    let originalRequestPresent: Bool
    let currentRequestPresent: Bool
    let originalPath: String?
    let currentPath: String?
    let originalMethod: String?
    let currentMethod: String?
    let bodyByteCount: Int
    let earliestBeginDatePresent: Bool
    let priority: Float
    let countOfBytesExpectedToSend: Int64
    let countOfBytesSent: Int64
    let countOfBytesExpectedToReceive: Int64
    let countOfBytesReceived: Int64

    var safeDescription: String {
        [
            "original=\(originalRequestPresent),path=\(originalPath ?? "missing"),method=\(originalMethod ?? "missing")",
            "current=\(currentRequestPresent),path=\(currentPath ?? "missing"),method=\(currentMethod ?? "missing")",
            "bodyBytes=\(bodyByteCount)",
            "earliestBeginDate=\(earliestBeginDatePresent)",
            "priority=\(String(format: "%.2f", priority))",
            "expectedSend=\(countOfBytesExpectedToSend)",
            "sent=\(countOfBytesSent)",
            "expectedReceive=\(countOfBytesExpectedToReceive)",
            "received=\(countOfBytesReceived)",
        ].joined(separator: "\n")
    }
}

struct AppleTaskLifecycleSnapshot: Equatable, Sendable {
    let taskIdentifier: Int
    let resumeCount: Int
    let events: [AppleTaskLifecycleEvent]
    let request: AppleTaskRequestSnapshot

    private func first(_ kind: AppleTaskLifecycleEventKind) -> AppleTaskLifecycleEvent? {
        events.first { $0.kind == kind }
    }

    private func compact(_ event: AppleTaskLifecycleEvent?) -> String {
        guard let event else { return "missing" }
        return "\(event.elapsedMilliseconds)ms,state=\(event.state.rawValue)"
    }

    var safeDescription: String {
        let waiting = first(.waitingForConnectivity).map { "\($0.elapsedMilliseconds)ms,state=\($0.state.rawValue)" } ?? "none"
        let metrics = first(.metricsCollected).map { "\($0.elapsedMilliseconds)ms,transactions=\($0.transactionCount ?? 0)" } ?? "missing"
        let completed = first(.taskCompleted)
        let error = completed?.errorDomain.map { "\($0)/\(completed?.errorCode ?? 0)" } ?? "none"
        var lines = [
            "TaskLifecycle:",
            "taskID=\(taskIdentifier)",
            "created=\(compact(first(.taskCreated)))",
            "beforeResume=\(compact(first(.beforeResume)))",
            "afterResume=\(compact(first(.afterResume)))",
            "waiting=\(waiting)",
            "metrics=\(metrics)",
            "completed=\(compact(completed))",
            "resumeCount=\(resumeCount)",
            "error=\(error)",
            "Request:",
            request.safeDescription,
        ]
        let remaining = events.filter { ![.taskCreated, .beforeResume, .afterResume, .waitingForConnectivity, .metricsCollected, .taskCompleted].contains($0.kind) }
        if !remaining.isEmpty {
            lines.append("events=\(remaining.map(\.safeDescription).joined(separator: ";"))")
        }
        return lines.joined(separator: "\n")
    }
}

struct AppleTransportDiagnosticReport: Equatable, Sendable {
    let pathStart: AppleTransportPathSnapshot
    let pathEnd: AppleTransportPathSnapshot
    let transactions: [AppleTransportTransactionSnapshot]
    let redirectCount: Int
    let totalMilliseconds: Int
    let errorDomain: String?
    let errorCode: Int?
    let pathFirstCallbackMilliseconds: Int?
    let pathFirstCallback: AppleTransportPathSnapshot?
    let taskLifecycle: AppleTaskLifecycleSnapshot?

    init(
        pathStart: AppleTransportPathSnapshot,
        pathEnd: AppleTransportPathSnapshot,
        transactions: [AppleTransportTransactionSnapshot],
        redirectCount: Int,
        totalMilliseconds: Int,
        errorDomain: String?,
        errorCode: Int?,
        pathFirstCallbackMilliseconds: Int? = nil,
        pathFirstCallback: AppleTransportPathSnapshot? = nil,
        taskLifecycle: AppleTaskLifecycleSnapshot? = nil
    ) {
        self.pathStart = pathStart
        self.pathEnd = pathEnd
        self.transactions = transactions
        self.redirectCount = redirectCount
        self.totalMilliseconds = totalMilliseconds
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.pathFirstCallbackMilliseconds = pathFirstCallbackMilliseconds
        self.pathFirstCallback = pathFirstCallback
        self.taskLifecycle = taskLifecycle
    }

    var safeDescription: String {
        if let taskLifecycle {
            var lines = [
                taskLifecycle.safeDescription,
                "Path:",
                "firstCallback=\(pathFirstCallbackMilliseconds.map { "\($0)ms" } ?? "missing")\(pathFirstCallback.map { ",\($0.safeDescription)" } ?? "")",
                "end=\(pathEnd.safeDescription)",
                "totalMs=\(totalMilliseconds)",
                "redirects=\(redirectCount)",
                "Transactions:",
                "count=\(transactions.count)",
            ]
            lines.append(contentsOf: transactions.enumerated().map { "transaction[\($0.offset)]=\($0.element.safeDescription)" })
            return lines.joined(separator: "\n")
        }
        var lines = [
            "pathStart=\(pathStart.safeDescription)",
            "pathEnd=\(pathEnd.safeDescription)",
            "transactions=\(transactions.count)",
            "redirects=\(redirectCount)",
            "totalMs=\(totalMilliseconds)",
            "error=\(errorDomain.map { "\($0)/\(errorCode ?? 0)" } ?? "none")",
        ]
        lines.append(contentsOf: transactions.enumerated().map { "transaction[\($0.offset)]=\($0.element.safeDescription)" })
        return lines.joined(separator: "\n")
    }
}

struct AppleSignInDiagnosticResult: Sendable {
    let response: AccountSessionResponse
    let report: AppleTransportDiagnosticReport
}

struct AppleSignInDiagnosticFailure: Error, Sendable {
    let underlying: AccountAPIError
    let report: AppleTransportDiagnosticReport
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
enum AccountAPIError: Error, Sendable {
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
