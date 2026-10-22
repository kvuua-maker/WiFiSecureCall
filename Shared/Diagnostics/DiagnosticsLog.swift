import AVFoundation
import Foundation
import Security
import Network
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// The diagnostic feed.
///
/// Everything that can go wrong in a call goes wrong somewhere specific, and by
/// the time the user reports "it did not ring" the app has already forgotten
/// why. This records what happened, in categories, and ships it in batches.
///
/// Rules that shaped it:
///
///   * it must never block or crash the product, so every write is queued and
///     every failure here is swallowed;
///   * it must never carry personal data, so callers pass counts, formats and
///     identifiers, never numbers, names or tokens;
///   * it must survive being offline, so records queue in memory and flush when a
///     batch can be sent.
enum DiagCategory: String {
    case lifecycle = "LIFECYCLE"
    case network = "NETWORK"
    case auth = "AUTH"
    case server = "SERVER"
    case push = "PUSH"
    case callKit = "CALLKIT"
    case signaling = "SIGNALING"
    case media = "MEDIA"
    case modeB = "MODEB"
    case watchConnectivity = "WATCHCONNECTIVITY"
    case state = "STATE"
    case permissions = "PERMISSIONS"
    case resources = "RESOURCES"
    case ui = "UI"
}

enum DiagStatus: String {
    case info
    case success
    case error
    case skipped
}

final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.diagnostics", qos: .utility)
    private var buffer: [[String: Any]] = []
    private var flushing = false
    private var timer: DispatchSourceTimer?
    private let capacity = 1_000
    private let batchSize = 20
    /// Cached on the main actor so the send queue never blocks on it.
    private let tokenBox = TokenBox()

    /// Records a step. `details` is free text and must not contain a phone number,
    /// a name, a token or any audio.
    func log(_ category: DiagCategory, _ step: String, _ status: DiagStatus = .info, details: String = "", error: Error? = nil) {
        var record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "category": category.rawValue,
            "step": step,
            "status": status.rawValue
        ]
        if !details.isEmpty { record["details"] = details }
        if let error { record["error"] = (error as NSError).description }
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(record)
            // A burst larger than the buffer must not grow without bound: the
            // oldest records are the ones already superseded by later failures.
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
        }
    }

    /// Starts the five second flush, the network watcher and the token refresh.
    /// Safe to call twice.
    func start() {
        Task { @MainActor in
            self.tokenBox.value = Self.token()
        }
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.flushLocked() }
            timer.resume()
            self.timer = timer
        }
        NetworkWatcher.shared.start()
    }

    // MARK: - Sending

    private func flushLocked() {
        guard !buffer.isEmpty, !flushing else { return }
        let batch = Array(buffer.prefix(batchSize))
        buffer.removeFirst(batch.count)
        guard let url = Self.endpoint() else {
            buffer.insert(contentsOf: batch, at: 0)
            if buffer.count > capacity { buffer.removeLast(buffer.count - capacity) }
            return
        }
        // Before sign-in there is no bearer token; the endpoint accepts a batch on
        // the device id alone so the launch sequence is visible too.
        let token = tokenBox.value
        flushing = true

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "device": InstallationIdentity.shared.id.uuidString,
            "records": batch
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] _, _, error in
            guard let self else { return }
            self.queue.async {
                self.flushing = false
                if error != nil, !batch.isEmpty {
                    // Requeue at the front so a failed batch is retried before newer
                    // records, and drop from the tail if the buffer filled meanwhile.
                    self.buffer.insert(contentsOf: batch, at: 0)
                    if self.buffer.count > self.capacity {
                        self.buffer.removeLast(self.buffer.count - self.capacity)
                    }
                }
                if !self.buffer.isEmpty {
                    self.queue.asyncAfter(deadline: .now() + 5) { self.flushLocked() }
                }
            }
        }.resume()
    }

    // MARK: - Endpoint and credentials

    static func endpoint(config: AppConfig = .load()) -> URL? {
        guard var components = URLComponents(url: config.apiBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        // The API root is /v1; diagnostics live under /v2 with the account routes.
        // Hard-coding the suffix here is what silently sent every batch to
        // /v1/diagnostics/log, which does not exist.
        var path = components.path
        if path.hasSuffix("/v1") {
            path = String(path.dropLast(3)) + "/v2"
        } else if !path.hasSuffix("/v2") {
            path += "/v2"
        }
        components.path = path
        return components.url?.appendingPathComponent("diagnostics/log")
    }

    @MainActor
    static func token() -> String? {
        let store = AccountSessionStore.shared
        guard let accountID = store.activeAccountID,
              let tokens = try? store.tokenStore.tokens(for: accountID) else { return nil }
        return tokens.accessToken
    }


}

/// A tiny lock box for the bearer token, so the send queue reads a value instead
/// of hopping to the main actor (which is busy exactly when a call is running).
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Records network state changes once rather than in every call site.
final class NetworkWatcher: @unchecked Sendable {
    static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.network")
    private var started = false
    private var last: NWPath.Status?
    private var lastKind: String?

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.monitor.pathUpdateHandler = { path in
                let kind: String
                if path.usesInterfaceType(.wifi) { kind = "wifi" }
                else if path.usesInterfaceType(.cellular) { kind = "cellular" }
                else if path.usesInterfaceType(.wiredEthernet) { kind = "wired" }
                else { kind = "other" }
                let previousStatus = self.last
                let previousKind = self.lastKind
                self.last = path.status
                self.lastKind = kind
                if previousKind != kind {
                    DiagnosticsLog.shared.log(.network, "network_type_changed", .info, details: "kind=\(kind) satisfied=\(path.status == .satisfied)")
                }
                if previousStatus != path.status {
                    DiagnosticsLog.shared.log(
                        .network,
                        path.status == .satisfied ? "became_reachable" : "became_unreachable",
                        .info,
                        details: "kind=\(kind)"
                    )
                }
            }
            self.monitor.start(queue: self.queue)
        }
    }
}

/// Process-level facts that explain a failure better than the failure itself.
enum DiagnosticsEnvironment {
    @MainActor
    static func recordLaunch() {
        DiagnosticsLog.shared.log(.lifecycle, "app_launched", .info, details: "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")

        #if os(iOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery = Int((device.batteryLevel * 100).rounded())
        DiagnosticsLog.shared.log(.resources, "battery_level", .info, details: "percent=\(battery)")
        if battery >= 0 && battery <= 20 {
            DiagnosticsLog.shared.log(.resources, "low_battery_warning", .info, details: "percent=\(battery)")
        }
        let thermal = String(describing: ProcessInfo.processInfo.thermalState)
        DiagnosticsLog.shared.log(.resources, "thermal_state_changed", .info, details: thermal)
        #endif

        DiagnosticsLog.shared.log(.auth, "entitlements", .info, details: entitlementSummary())
        DiagnosticsLog.shared.log(.permissions, "microphone_status", .info, details: microphoneStatus())
        DiagnosticsLog.shared.log(.permissions, "notification_status", .info, details: notificationStatus())
    }

    /// The entitlement string is the only proof of what the signed bundle may do.
    /// A missing aps-environment produces a runtime error code 3000 and a silent
    /// failure to ring, which is exactly what happened before this existed.
    static func entitlementSummary() -> String {
        let keys = ["aps-environment", "com.apple.developer.applesignin"]
        guard let task = SecTaskCreateFromSelf(nil) else { return "task_unavailable" }
        var parts: [String] = []
        for key in keys {
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
            parts.append("\(key)=\(value == nil ? "absent" : "present")")
        }
        return parts.joined(separator: " ")
    }

    static func microphoneStatus() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    static func notificationStatus() -> String {
        var value = "unknown"
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: value = "authorized"
            case .denied: value = "denied"
            case .notDetermined: value = "not_determined"
            @unknown default: value = "unknown"
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.5)
        return value
    }
}
