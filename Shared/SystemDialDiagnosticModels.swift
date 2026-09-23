import Combine
import Foundation
import Network
import os

enum SystemDialClassification {
    static let preparing = "PREPARING"
    static let ready = "READY"
    static let watchNetworkUnavailable = "WATCH_NETWORK_UNAVAILABLE"
    static let wcNotActivated = "WC_NOT_ACTIVATED"
    static let iPhoneNeedsUnlock = "IPHONE_NEEDS_UNLOCK"
    static let iPhoneAppUnreachable = "IPHONE_APP_UNREACHABLE"
    static let iPhoneReady = "IPHONE_READY"
    static let telHandoffRequested = "TEL_HANDOFF_REQUESTED"
    static let systemCallObserved = "SYSTEM_CALL_OBSERVED"
    static let systemCallConnected = "SYSTEM_CALL_CONNECTED"
    static let systemCallEnded = "SYSTEM_CALL_ENDED"
    static let noSystemCallEvidence = "NO_SYSTEM_CALL_EVIDENCE"
    static let unknownAfterTelHandoff = "UNKNOWN_AFTER_TEL_HANDOFF"

    static let knownValues = [
        preparing, ready, watchNetworkUnavailable, wcNotActivated,
        iPhoneNeedsUnlock, iPhoneAppUnreachable, iPhoneReady,
        telHandoffRequested, systemCallObserved, systemCallConnected,
        systemCallEnded, noSystemCallEvidence, unknownAfterTelHandoff
    ]

    static func preflight(
        networkStatus: String,
        wcSupported: Bool,
        activationState: String,
        reachable: Bool,
        needsUnlock: Bool?,
        replied: Bool
    ) -> String {
        if networkStatus != "satisfied" { return watchNetworkUnavailable }
        if !wcSupported || activationState != "activated" { return wcNotActivated }
        if needsUnlock == true { return iPhoneNeedsUnlock }
        if replied { return iPhoneReady }
        if !reachable { return iPhoneAppUnreachable }
        return iPhoneAppUnreachable
    }

    static func afterHandoff(outgoing: Date?, connected: Date?, ended: Date?, resultReceived: Bool) -> String {
        if ended != nil { return systemCallEnded }
        if connected != nil { return systemCallConnected }
        if outgoing != nil { return systemCallObserved }
        return resultReceived ? noSystemCallEvidence : unknownAfterTelHandoff
    }

    static func displayText(for value: String) -> String {
        switch value {
        case preparing: return "Перевіряю зв’язок з iPhone…"
        case ready: return "iPhone відповідає, передаю дзвінок системі"
        case watchNetworkUnavailable: return "Watch не має мережевого з’єднання"
        case wcNotActivated: return "Зв’язок Watch↔iPhone ще не активований"
        case iPhoneNeedsUnlock: return "Після перезапуску iPhone треба один раз розблокувати"
        case iPhoneAppUnreachable: return "Програма на iPhone зараз недоступна для прямого зв’язку"
        case iPhoneReady: return "Програма на iPhone відповіла"
        case telHandoffRequested: return "Номер передано системному Телефону"
        case systemCallObserved: return "iPhone бачить системний вихідний дзвінок"
        case systemCallConnected: return "Системний дзвінок з’єднався"
        case systemCallEnded: return "Системний дзвінок завершився"
        case noSystemCallEvidence: return "Номер передано системі, але програма не отримала підтвердження стану дзвінка"
        default: return "Збій стався після передачі керування системі; точна внутрішня причина Apple недоступна програмі"
        }
    }
}

struct SystemDialUserSummary: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case neutral
        case success
        case warning
        case failure
    }

    let code: String
    let title: String
    let detail: String?
    let severity: Severity

    static func make(from attempt: SystemDialAttempt) -> SystemDialUserSummary {
        make(classification: attempt.classification)
    }

    static func make(classification: String) -> SystemDialUserSummary {
        switch classification {
        case SystemDialClassification.preparing:
            return .init(code: "D23-05", title: "Перевіряю iPhone…", detail: nil, severity: .neutral)
        case SystemDialClassification.ready, SystemDialClassification.iPhoneReady:
            return .init(code: "D23-05", title: "iPhone відповідає", detail: nil, severity: .success)
        case SystemDialClassification.watchNetworkUnavailable:
            return .init(code: "D23-01", title: "Немає мережі", detail: nil, severity: .failure)
        case SystemDialClassification.wcNotActivated:
            return .init(code: "D23-02", title: "Немає зв’язку з iPhone", detail: nil, severity: .warning)
        case SystemDialClassification.iPhoneNeedsUnlock:
            return .init(code: "D23-03", title: "Розблокуй iPhone", detail: nil, severity: .warning)
        case SystemDialClassification.iPhoneAppUnreachable:
            return .init(code: "D23-04", title: "iPhone недоступний", detail: nil, severity: .warning)
        case SystemDialClassification.telHandoffRequested:
            return .init(code: "D23-06", title: "Передано в Телефон", detail: nil, severity: .neutral)
        case SystemDialClassification.systemCallObserved:
            return .init(code: "D23-07", title: "Дзвінок почався", detail: nil, severity: .success)
        case SystemDialClassification.systemCallConnected:
            return .init(code: "D23-08", title: "З’єднано", detail: nil, severity: .success)
        case SystemDialClassification.systemCallEnded:
            return .init(code: "D23-09", title: "Дзвінок завершено", detail: nil, severity: .success)
        case SystemDialClassification.noSystemCallEvidence:
            return .init(
                code: "D23-10",
                title: "Система не підтвердила дзвінок",
                detail: "Деталі є на iPhone",
                severity: .warning
            )
        default:
            return .init(
                code: "D23-10",
                title: "Збій після передачі",
                detail: "Деталі є на iPhone",
                severity: .warning
            )
        }
    }
}

struct SystemDialEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let source: String
    let event: String
    let status: String
    let detail: String?
    let attemptID: UUID

    init(timestamp: Date = Date(), source: String, event: String, status: String, detail: String? = nil, attemptID: UUID) {
        id = UUID()
        self.timestamp = timestamp
        self.source = source
        self.event = event
        self.status = status
        self.detail = detail
        self.attemptID = attemptID
    }
}

struct SystemDialPingResult: Codable, Equatable, Sendable {
    let index: Int
    let nonce: UUID
    let sentAt: Date
    let finishedAt: Date
    let rttMilliseconds: Double
    let status: String
    let detail: String?
}

struct SystemDialIPhoneSnapshot: Codable, Equatable, Sendable {
    let receivedAt: Date
    let repliedAt: Date
    let applicationState: String
    let wcActivationState: String
    let isPaired: Bool
    let isWatchAppInstalled: Bool
    let networkStatus: String
    let networkInterfaces: [String]
}

struct SystemDialAttempt: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { attemptID }
    let attemptID: UUID
    let startedAt: Date
    var finishedAt: Date?
    let numberDigitCount: Int
    var watchNetworkStatus: String
    var watchNetworkInterfaces: [String]
    var wcSupported: Bool
    var wcActivationState: String
    var wcReachableBeforePing: Bool
    var iPhoneNeedsUnlockAfterReboot: Bool?
    var pingResults: [SystemDialPingResult]
    var iPhoneSnapshot: SystemDialIPhoneSnapshot?
    var telHandoffRequestedAt: Date?
    var watchResignedActiveAt: Date?
    var watchReturnedActiveAt: Date?
    var iPhoneObservedOutgoingCallAt: Date?
    var iPhoneObservedConnectedCallAt: Date?
    var iPhoneObservedEndedCallAt: Date?
    var classification: String
    var events: [SystemDialEvent]

    static func make(
        attemptID: UUID = UUID(),
        startedAt: Date = Date(),
        numberDigitCount: Int,
        network: SystemDialNetworkSnapshot = .unknown,
        wcSupported: Bool = false,
        wcActivationState: String = "notActivated",
        wcReachableBeforePing: Bool = false,
        iPhoneNeedsUnlockAfterReboot: Bool? = nil,
        classification: String = SystemDialClassification.preparing
    ) -> SystemDialAttempt {
        SystemDialAttempt(
            attemptID: attemptID,
            startedAt: startedAt,
            finishedAt: nil,
            numberDigitCount: numberDigitCount,
            watchNetworkStatus: network.status,
            watchNetworkInterfaces: network.interfaces,
            wcSupported: wcSupported,
            wcActivationState: wcActivationState,
            wcReachableBeforePing: wcReachableBeforePing,
            iPhoneNeedsUnlockAfterReboot: iPhoneNeedsUnlockAfterReboot,
            pingResults: [],
            iPhoneSnapshot: nil,
            telHandoffRequestedAt: nil,
            watchResignedActiveAt: nil,
            watchReturnedActiveAt: nil,
            iPhoneObservedOutgoingCallAt: nil,
            iPhoneObservedConnectedCallAt: nil,
            iPhoneObservedEndedCallAt: nil,
            classification: classification,
            events: []
        )
    }
}

enum SystemDialLifecycleRecorder {
    @discardableResult
    static func recordFirstResign(in attempt: inout SystemDialAttempt, at timestamp: Date = Date()) -> Bool {
        guard attempt.telHandoffRequestedAt != nil,
              attempt.watchResignedActiveAt == nil,
              !attempt.events.contains(where: { $0.event == "watch_resigned_active" }) else { return false }
        attempt.watchResignedActiveAt = timestamp
        attempt.events.append(.init(timestamp: timestamp, source: "watch", event: "watch_resigned_active", status: "observed", attemptID: attempt.attemptID))
        return true
    }

    @discardableResult
    static func recordFirstReturn(in attempt: inout SystemDialAttempt, at timestamp: Date = Date()) -> Bool {
        guard attempt.telHandoffRequestedAt != nil,
              attempt.watchReturnedActiveAt == nil,
              !attempt.events.contains(where: { $0.event == "watch_returned_active" }) else { return false }
        attempt.watchReturnedActiveAt = timestamp
        attempt.events.append(.init(timestamp: timestamp, source: "watch", event: "watch_returned_active", status: "observed", attemptID: attempt.attemptID))
        return true
    }
}

struct SystemDialNetworkSnapshot: Codable, Equatable, Sendable {
    let status: String
    let interfaces: [String]

    static let unknown = SystemDialNetworkSnapshot(status: "requiresConnection", interfaces: [])
}

final class SystemDialNetworkMonitor: @unchecked Sendable {
    static let shared = SystemDialNetworkMonitor()

    private let lock = NSLock()
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.systemDial.network")
    private var snapshot = SystemDialNetworkSnapshot.unknown

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.setSnapshot(Self.snapshot(from: path))
        }
        monitor.start(queue: queue)
    }

    var current: SystemDialNetworkSnapshot { lock.withLock { snapshot } }

    private func setSnapshot(_ value: SystemDialNetworkSnapshot) {
        lock.withLock { snapshot = value }
    }

    private static func snapshot(from path: NWPath) -> SystemDialNetworkSnapshot {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wiredEthernet") }
        if path.usesInterfaceType(.other) { interfaces.append("other") }
        return .init(status: status, interfaces: interfaces)
    }
}

actor SystemDialPersistenceWorker {
    typealias Writer = @Sendable (Data, URL) throws -> Void

    private let writer: Writer
    private(set) var persistedRevision: UInt64 = 0

    init(writer: @escaping Writer = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.writer = writer
    }

    @discardableResult
    func persist(snapshot: [SystemDialAttempt], revision: UInt64, fileURL: URL) throws -> UInt64 {
        guard revision > persistedRevision else { return persistedRevision }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try writer(data, fileURL)
        persistedRevision = revision
        return revision
    }
}

@MainActor
final class SystemDialDiagnosticStore: ObservableObject {
    static let shared = SystemDialDiagnosticStore()
    static let maximumAttempts = 20
    static let maximumEventsPerAttempt = 50
    private static let logger = Logger(subsystem: "com.vkapps.wifisecurecall", category: "systemDial")

    @Published private(set) var attempts: [SystemDialAttempt]
    private(set) var revision: UInt64 = 0
    private let fileURL: URL
    private let persistenceWorker: SystemDialPersistenceWorker

    init(fileURL: URL? = nil, persistenceWorker: SystemDialPersistenceWorker = SystemDialPersistenceWorker()) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.persistenceWorker = persistenceWorker
        attempts = Self.load(from: self.fileURL)
        if normalizeIfNeeded() { commit() }
    }

    func attempt(id: UUID) -> SystemDialAttempt? { attempts.first { $0.attemptID == id } }

    func upsert(_ attempt: SystemDialAttempt) {
        var value = attempt
        if value.events.count > Self.maximumEventsPerAttempt {
            value.events.removeFirst(value.events.count - Self.maximumEventsPerAttempt)
        }
        attempts.removeAll { $0.attemptID == value.attemptID }
        attempts.insert(value, at: 0)
        trim()
        commit()
    }

    @discardableResult
    func update(id: UUID, _ change: (inout SystemDialAttempt) -> Void) -> Bool {
        guard let index = attempts.firstIndex(where: { $0.attemptID == id }) else { return false }
        var value = attempts[index]
        change(&value)
        if value.events.count > Self.maximumEventsPerAttempt {
            value.events.removeFirst(value.events.count - Self.maximumEventsPerAttempt)
        }
        guard value != attempts[index] else { return false }
        attempts.remove(at: index)
        attempts.insert(value, at: 0)
        trim()
        commit()
        return true
    }

    func record(id: UUID, source: String, event: String, status: String, detail: String? = nil, at timestamp: Date = Date()) {
        updateAndRecord(id: id, source: source, event: event, status: status, detail: detail, at: timestamp) { _ in }
    }

    @discardableResult
    func updateAndRecord(
        id: UUID,
        source: String,
        event: String,
        status: String,
        detail: String? = nil,
        at timestamp: Date = Date(),
        _ change: (inout SystemDialAttempt) -> Void
    ) -> Bool {
        let item = SystemDialEvent(timestamp: timestamp, source: source, event: event, status: status, detail: detail, attemptID: id)
        let changed = update(id: id) {
            change(&$0)
            $0.events.append(item)
        }
        Self.logger.info("attempt=\(id.uuidString, privacy: .public) event=\(event, privacy: .public) status=\(status, privacy: .public)")
        return changed
    }

    func flush() async {
        let snapshot = attempts
        let targetRevision = revision
        do {
            _ = try await persistenceWorker.persist(snapshot: snapshot, revision: targetRevision, fileURL: fileURL)
        } catch {
            Self.logger.error("diagnostic_store_write_failed")
        }
    }

    private func trim() {
        if attempts.count > Self.maximumAttempts { attempts.removeLast(attempts.count - Self.maximumAttempts) }
    }

    private func normalizeIfNeeded() -> Bool {
        var changed = false
        for index in attempts.indices where attempts[index].events.count > Self.maximumEventsPerAttempt {
            attempts[index].events.removeFirst(attempts[index].events.count - Self.maximumEventsPerAttempt)
            changed = true
        }
        if attempts.count > Self.maximumAttempts {
            attempts.removeLast(attempts.count - Self.maximumAttempts)
            changed = true
        }
        return changed
    }

    private func commit() {
        revision &+= 1
        let snapshot = attempts
        let committedRevision = revision
        let worker = persistenceWorker
        let destination = fileURL
        Task {
            do {
                _ = try await worker.persist(snapshot: snapshot, revision: committedRevision, fileURL: destination)
            } catch {
                Self.logger.error("diagnostic_store_write_failed")
            }
        }
    }

    private static func load(from fileURL: URL) -> [SystemDialAttempt] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SystemDialAttempt].self, from: data)) ?? []
    }

    private static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SystemDialDiagnostics.json", isDirectory: false)
    }
}

enum SystemDialMessageValidator {
    static func matches(_ message: [String: Any], attemptID: UUID, nonce: UUID) -> Bool {
        message["attemptID"] as? String == attemptID.uuidString && message["nonce"] as? String == nonce.uuidString
    }
}

final class SystemDialOneShotCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let handler: (Result<Value, Error>) -> Void

    init(handler: @escaping (Result<Value, Error>) -> Void) { self.handler = handler }

    @discardableResult
    func complete(_ result: Result<Value, Error>) -> Bool {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldComplete { handler(result) }
        return shouldComplete
    }
}

final class SystemDialAttemptAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func begin() -> Bool {
        lock.withLock {
            guard !active else { return false }
            active = true
            return true
        }
    }

    func end() { lock.withLock { active = false } }
}

enum SystemDialPreflightPolicy {
    static func shouldRequestTelHandoff(numberIsValid: Bool, preflightSucceeded: Bool) -> Bool {
        numberIsValid
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
