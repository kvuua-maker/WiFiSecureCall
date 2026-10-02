import Foundation

struct DiagnosticEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let platform: String
    let role: DeviceRole
    let callID: UUID?
    let category: String
    let value: String

    init(id: UUID = UUID(), timestamp: Date, platform: String, role: DeviceRole, callID: UUID?, category: String, value: String) {
        self.id = id
        self.timestamp = timestamp
        self.platform = platform
        self.role = role
        self.callID = callID
        self.category = category
        self.value = value
    }
}

@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    @Published private(set) var events: [DiagnosticEvent] = []
    private let capacity = 600
    private let persistedCapacity = 400
    private let retention: TimeInterval = 7 * 24 * 60 * 60
    private let defaults: UserDefaults
    private let storageKey = "WiFiSecureCall.safeCallDiagnostics.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let cutoff = Date().addingTimeInterval(-retention)
        events = (defaults.data(forKey: storageKey)).flatMap { try? JSONDecoder().decode([DiagnosticEvent].self, from: $0) }?.filter { $0.timestamp >= cutoff }.compactMap(Self.safeEvent) ?? []
        persistSafeEvents()
    }

    func record(role: DeviceRole, callID: UUID? = nil, category: String, value: String) {
        #if os(watchOS)
        let platform = "watchOS"
        #else
        let platform = "iOS"
        #endif
        if category == "playback_frame_scheduled" || category == "playback_frame_rendered",
           events.contains(where: { $0.callID == callID && $0.category == category && $0.value == value }) { return }
        events.append(.init(timestamp: Date(), platform: platform, role: role, callID: callID, category: category, value: value))
        while events.count > capacity {
            if let progress = events.firstIndex(where: { $0.category == "audio_flow_progress" || $0.category == "playback_render_progress" }) {
                events.remove(at: progress)
            } else {
                events.removeFirst()
            }
        }
        persistSafeEvents()
    }

    private static let permittedCategories: Set<String> = [
        "state", "network_audio", "media_peer_ready", "media_connect_started", "media_connect_succeeded",
        "media_connect_failed", "media_disconnected", "first_mic_callback",
        "first_mic_nonzero_signal", "first_network_pcm_generated",
        "first_network_pcm_nonzero", "first_network_audio_frame_generated",
        "first_network_audio_frame_sent", "first_network_audio_nonzero_sent",
        "first_network_audio_frame_send_failure", "first_remote_audio_frame_received",
        "first_remote_audio_nonzero", "first_playback_buffer_scheduled",
        "first_playback_buffer_rendered", "first_playback_nonzero_input",
        "playback_render_progress", "playback_overflow", "encrypted_audio_authentication_drop",
        "audio_operational", "audio_flow_watchdog", "audio_flow_progress", "audio_watchdog_recovery_started",
        "audio_watchdog_recovery_succeeded", "audio_watchdog_terminal_failure",
        "audio_recovery", "capture_watchdog_failed", "first_capture_conversion_failure",
        "first_playback_failure", "audio_engine_start_failure", "audio_route_changed",
        "audio_interruption", "audio_send_backpressure_drop", "audio_configuration_change",
        "audio_route_change", "audio_graph_generation", "audio_recovery_started",
        "audio_graph_restarted", "audio_recovery_validating", "audio_recovery_confirmed",
        "audio_recovery_validation_timeout", "audio_recovery_exhausted",
        "playback_frame_scheduled", "playback_frame_rendered", "playback_failure",
        "playback_graph_unavailable", "media_disconnect_reason", "media_reconnect_started",
        "media_reconnect_succeeded", "media_reconnect_exhausted", "call_failed_reason",
        "callkit_end_received", "system_end_reconcile_started", "system_end_reconcile_server_state",
        "system_end_preserved_after_accept", "terminal_mutation", "provider_reset",
        "callkit_did_deactivate", "callkit_did_activate", "outgoing_connected_reported",
        "callkit_reactivation_wait_started", "callkit_reactivated", "callkit_continuation_started",
        "callkit_continuation_activated", "callkit_reactivation_failed"
    ]

    private static let metricKeys: Set<String> = [
        "bytes", "rms", "peak", "nonzero", "sequence", "count", "frames",
        "frameLength", "sampleRate", "channelCount", "depth",
        "sent", "received", "scheduled", "rendered", "relayed", "dropped", "generation", "attempt",
        "reason", "code"
    ]

    private static func safeEvent(_ event: DiagnosticEvent) -> DiagnosticEvent? {
        guard event.callID != nil, permittedCategories.contains(event.category) else { return nil }
        let numeric = event.value.split(separator: " ").compactMap { field -> String? in
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, metricKeys.contains(String(parts[0])),
                  parts[1].count <= 20, Double(parts[1]) != nil else { return nil }
            return "\(parts[0])=\(parts[1])"
        }
        let states = ["idle", "outgoingRinging", "incomingRinging", "connecting",
                      "active", "reconnecting", "ending", "ended", "failed"]
        let safeState = event.category == "state"
            ? states.first(where: { event.value.hasPrefix($0) }) : nil
        let callFailures = Set(["permissionDenied", "serverUnavailable", "callExpired", "callRejected",
                                "callCancelled", "callKitRejected", "audioActivationTimeout", "callKitReactivationFailed", "audioFailed",
                                "mediaConnectionFailed", "networkLost", "invalidServerState", "notificationUnavailable",
                                "accountSessionInvalid", "accountMutationInProgress", "targetUnavailable",
                                "targetAmbiguous", "answeredElsewhere"])
        let mediaReasons = Set(["remoteClosed", "authFailed", "protocolViolation", "serverRestart",
                                "transientNetwork", "sendFailed", "peerUnavailable", "localClose"])
        let safeWords = event.value.split(separator: " ").compactMap { field -> String? in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let allowed: [String: Set<String>] = [
                "origin": ["system", "appRequested"],
                "state": ["ringing", "accepted", "terminal", "transient"],
                "mutation": ["end", "cancel", "reject"],
                "reason": ["explicit_user_end", "system_end", "provider_reset", "audio_recovery_exhausted", "media_reconnect_exhausted", "accepted_verification_failed", "local_failure", "networkLost"]
            ]
            guard allowed[parts[0]]?.contains(parts[1]) == true else { return nil }
            return field.description
        }
        let safeReason: String?
        if event.category == "call_failed_reason", callFailures.contains(event.value) { safeReason = event.value }
        else if event.category == "media_disconnect_reason",
                let value = event.value.split(separator: "=").last.map(String.init), mediaReasons.contains(value) { safeReason = value }
        else { safeReason = nil }
        let safeFields = Array((safeWords + numeric).prefix(8))
        let detail = safeState ?? safeReason ?? (safeFields.isEmpty ? "подія" : safeFields.joined(separator: " "))
        return DiagnosticEvent(id: event.id, timestamp: event.timestamp, platform: event.platform,
                               role: event.role, callID: event.callID, category: event.category, value: detail)
    }

    private func persistSafeEvents() {
        let cutoff = Date().addingTimeInterval(-retention)
        let safe = events.filter { $0.timestamp >= cutoff }.compactMap(Self.safeEvent).suffix(persistedCapacity)
        defaults.set(try? JSONEncoder().encode(Array(safe)), forKey: storageKey)
    }

    func lastCallReport() -> String {
        guard let callID = events.reversed().compactMap(\.callID).first else {
            return "Діагностика останнього дзвінка відсутня."
        }
        let formatter = ISO8601DateFormatter()
        let rows = events.filter { $0.callID == callID }.compactMap(Self.safeEvent)
        return (["WiFi Secure Call — діагностика останнього дзвінка", "callID: \(callID.uuidString)"] + rows.map {
            "\(formatter.string(from: $0.timestamp)) \($0.platform)/\($0.role.rawValue) \($0.category): \($0.value)"
        }).joined(separator: "\n")
    }
}
