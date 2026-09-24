import AVFoundation
import CallKit
import LiveCommunicationKit
import SwiftUI
import UIKit

@MainActor
final class IOSCellularAudioProbe: NSObject, ObservableObject {
    static let shared = IOSCellularAudioProbe()

    @Published private(set) var logLines: [String] = []
    @Published private(set) var isAudioProbeRunning = false
    @Published private(set) var cellularServicesSummary = "Not queried"
    @Published private(set) var verdict = CellularAudioGatewayVerdict()

    private let audioSession = AVAudioSession.sharedInstance()
    private let callObserver = CXCallObserver()
    private var notificationTokens: [NSObjectProtocol] = []
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var inputTapInstalled = false
    private var mixerTapInstalled = false
    private var inputFrameCount: UInt64 = 0
    private var inputCallbackCount: UInt64 = 0
    private var mixerFrameCount: UInt64 = 0
    private var mixerCallbackCount: UInt64 = 0
    private var audioInterruptionActive = false
    private var processHeartbeatTask: Task<Void, Never>?

    override private init() {
        super.init()
        callObserver.setDelegate(self, queue: .main)
        installObservers()
        record("probe_initialized sdk=iOS26.5 process_state=\(Self.applicationState(UIApplication.shared.applicationState))")
    }

    func startCellularTest(number: String) async {
        guard let handleValue = Self.validPhoneHandle(number) else {
            record("cellular_action_rejected invalid_number")
            return
        }
        verdict = CellularAudioGatewayVerdict()
        record("cellular_action_requested request_timestamp=\(ISO8601DateFormatter().string(from: Date())) digit_count=\(handleValue.filter(\.isNumber).count)")
        recordApplicationState(prefix: "before_cellular_action")
        startProcessHeartbeat()

        guard #available(iOS 26.0, *) else {
            record("cellular_action_unavailable requires=iOS26.0")
            return
        }

        let manager = TelephonyConversationManager.sharedInstance
        let services = manager.cellularServices
        cellularServicesSummary = "\(services.count) service(s)"
        record("cellular_services count=\(services.count)")
        for (index, service) in services.enumerated() {
            record("cellular_service index=\(index) id=\(service.id.uuidString.prefix(8)) label=\(Self.sanitized(service.label))")
        }
        let handle = Handle(type: .phoneNumber, value: handleValue)
        let action = StartCellularConversationAction(handle)
        do {
            try await manager.startCellularConversation(action)
            record("cellular_action_completed result=accepted_by_system call_connected_not_yet_proven=true")
            recordVerdict(reason: "cellular_action_accepted")
            recordApplicationState(prefix: "after_cellular_action")
        } catch {
            let value = error as NSError
            record("cellular_action_failed domain=\(value.domain) code=\(value.code) description=\(Self.sanitized(value.localizedDescription, redacting: handleValue))")
            recordApplicationState(prefix: "after_cellular_error")
        }
    }

    func startAudioProbe() async {
        guard !isAudioProbeRunning else {
            record("audio_probe_already_running")
            return
        }

        recordAudioSnapshot(prefix: "audio_before_activation")
        let permission = await requestRecordPermission()
        record("microphone_permission granted=\(permission)")

        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
            record("audio_session_set_active result=success")
        } catch {
            recordError("audio_session_set_active", error)
            recordAudioSnapshot(prefix: "audio_after_activation_failure")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000
        guard let toneFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            record("audio_probe_failed stage=tone_format")
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        if permission, inputFormat.channelCount > 0, inputFormat.sampleRate > 0 {
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?.pointee else { return }
                var sumSquares: Float = 0
                let count = Int(buffer.frameLength)
                for index in 0..<count {
                    let sample = channel[index]
                    sumSquares += sample * sample
                }
                let rms = count > 0 ? sqrt(sumSquares / Float(count)) : 0
                Task { @MainActor [weak self] in
                    self?.recordInputFrames(UInt64(buffer.frameLength), rms: rms)
                }
            }
            inputTapInstalled = true
            record("input_tap_installed source=app_audio_input_not_remote_audio format=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch")
        } else {
            record("input_tap_not_installed permission=\(permission) sample_rate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
        }

        let mixer = engine.mainMixerNode
        let mixerFormat = mixer.outputFormat(forBus: 0)
        if mixerFormat.channelCount > 0, mixerFormat.sampleRate > 0 {
            mixer.installTap(onBus: 0, bufferSize: 1024, format: mixerFormat) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?.pointee else { return }
                var sumSquares: Float = 0
                let count = Int(buffer.frameLength)
                for index in 0..<count {
                    let sample = channel[index]
                    sumSquares += sample * sample
                }
                let rms = count > 0 ? sqrt(sumSquares / Float(count)) : 0
                Task { @MainActor [weak self] in
                    self?.recordMixerFrames(UInt64(buffer.frameLength), rms: rms)
                }
            }
            mixerTapInstalled = true
            record("app_mixer_tap_installed source=app_owned_main_mixer format=\(Int(mixerFormat.sampleRate))Hz/\(mixerFormat.channelCount)ch cellular_downlink_not_implied=true")
        } else {
            record("app_mixer_tap_not_installed sample_rate=\(mixerFormat.sampleRate) channels=\(mixerFormat.channelCount)")
        }

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.player = player
            isAudioProbeRunning = true
            inputFrameCount = 0
            inputCallbackCount = 0
            mixerFrameCount = 0
            mixerCallbackCount = 0
            record("audio_engine_started result=success")
            record("NO_PUBLIC_CELLULAR_DOWNLINK_AUDIO_ENDPOINT app_input_is_microphone_or_selected_input app_mixer_contains_app_graph_only")
            recordVerdict(reason: "audio_probe_started")
            recordAudioSnapshot(prefix: "audio_probe_active")
        } catch {
            if inputTapInstalled {
                input.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            if mixerTapInstalled {
                mixer.removeTap(onBus: 0)
                mixerTapInstalled = false
            }
            recordError("audio_engine_start", error)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func confirmCellularMicrophoneMuted() {
        guard verdict.cellularCallConnected else {
            record("cellular_mic_mute_confirmation_rejected reason=call_not_connected")
            return
        }
        var next = verdict
        next.userConfirmedCellularMicMuted = true
        verdict = next
        record("user_confirmed_cellular_mic_muted=true source=user_confirmation")
        recordVerdict(reason: "cellular_mic_muted_confirmed")
    }

    func runUplinkTone() {
        guard verdict.cellularCallConnected else {
            record("uplink_tone_rejected reason=call_not_connected")
            return
        }
        guard verdict.userConfirmedCellularMicMuted else {
            record("uplink_tone_rejected reason=cellular_mic_mute_not_confirmed")
            return
        }
        guard let engine, let player, engine.isRunning else {
            record("uplink_tone_rejected reason=audio_probe_not_running")
            return
        }
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
            record("app_input_tap_removed_for_uplink_control additional_app_microphone_measurement=false")
        }
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let toneFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channels: 1) else {
            record("uplink_tone_rejected reason=invalid_output_format")
            return
        }
        var next = verdict
        next.uplinkToneWasRun = true
        next.remoteHeardTone = nil
        verdict = next
        recordAudioSnapshot(prefix: "uplink_tone_preflight")
        record("tone_generated frequency_hz=1000 duration_ms=2000 verdict=control_signal_only")
        scheduleControlledTone(player: player, format: toneFormat)
        recordVerdict(reason: "uplink_tone_started")
    }

    func reportRemoteHeardTone(_ heard: Bool) {
        guard verdict.uplinkToneWasRun else {
            record("uplink_result_rejected reason=tone_not_run")
            return
        }
        var next = verdict
        next.remoteHeardTone = heard
        verdict = next
        if verdict.uplinkStrongEvidence {
            record("STRONG_DIGITAL_UPLINK_EVIDENCE user_reported_remote_heard_exact_tone=true cellular_mic_muted_user_confirmed=true api_level_route_not_proven=true")
        } else {
            record("UPLINK_NOT_PROVEN user_reported_remote_heard_exact_tone=\(heard) cellular_mic_muted_user_confirmed=\(verdict.userConfirmedCellularMicMuted)")
        }
        recordVerdict(reason: "uplink_result_recorded")
    }

    func copyLog() {
        UIPasteboard.general.string = logLines.joined(separator: "\n")
        record("diagnostic_log_copied line_count=\(logLines.count)")
    }

    func stop() {
        processHeartbeatTask?.cancel()
        processHeartbeatTask = nil
        if let engine {
            if inputTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                inputTapInstalled = false
            }
            if mixerTapInstalled {
                engine.mainMixerNode.removeTap(onBus: 0)
                mixerTapInstalled = false
            }
            player?.stop()
            engine.stop()
        }
        engine = nil
        player = nil
        isAudioProbeRunning = false
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            record("audio_probe_stopped set_active_false=success input_frames=\(inputFrameCount) input_callbacks=\(inputCallbackCount) mixer_frames=\(mixerFrameCount) mixer_callbacks=\(mixerCallbackCount)")
        } catch {
            recordError("audio_probe_stop", error)
        }
        recordAudioSnapshot(prefix: "audio_after_stop")
    }

    private func scheduleControlledTone(player: AVAudioPlayerNode, format: AVAudioFormat) {
        let duration = 2.0
        let frequency = 1_000.0
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?.pointee else {
            record("tone_generation_failed")
            return
        }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let time = Double(frame) / format.sampleRate
            channel[frame] = Float(sin(2 * Double.pi * frequency * time) * 0.18)
        }
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in self?.record("controlled_tone_finished duration_ms=2000 frequency_hz=1000") }
        }
        player.play()
        let outputs = audioSession.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        record("controlled_tone_started duration_ms=2000 frequency_hz=1000 path=app_output app_output_route=[\(outputs)] physical_remote_hearing_is_evidence_only=true")
    }

    private func recordInputFrames(_ frames: UInt64, rms: Float) {
        inputFrameCount += frames
        inputCallbackCount += 1
        if inputCallbackCount == 1 || inputCallbackCount.isMultiple(of: 50) {
            record("input_frames source=microphone_or_selected_input callbacks=\(inputCallbackCount) frames=\(inputFrameCount) rms=\(String(format: "%.6f", rms)) remote_audio_not_proven")
        }
    }

    private func recordMixerFrames(_ frames: UInt64, rms: Float) {
        mixerFrameCount += frames
        mixerCallbackCount += 1
        if mixerCallbackCount == 1 || mixerCallbackCount.isMultiple(of: 50) {
            record("app_mixer_frames source=app_owned_main_mixer callbacks=\(mixerCallbackCount) frames=\(mixerFrameCount) rms=\(String(format: "%.6f", rms)) cellular_remote_audio_not_proven=true")
        }
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in self?.recordAudioNotification("audio_interruption", note) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.recordAudioNotification("audio_route_changed", note)
                self?.recordAudioSnapshot(prefix: "audio_after_route_change")
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: audioSession, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in self?.recordAudioNotification("media_services_lost", note) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: audioSession, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in self?.recordAudioNotification("media_services_reset", note) }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.record("process_lifecycle will_resign_active") }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.record("process_lifecycle did_enter_background") }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.record("process_lifecycle will_enter_foreground") }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.record("process_lifecycle did_become_active") }
        })
    }

    private func startProcessHeartbeat() {
        processHeartbeatTask?.cancel()
        processHeartbeatTask = Task { [weak self] in
            for index in 1...15 {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.record("process_heartbeat index=\(index) state=\(Self.applicationState(UIApplication.shared.applicationState))")
            }
        }
    }

    private func recordAudioNotification(_ event: String, _ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let interruptionType = info[AVAudioSessionInterruptionTypeKey].map { String(describing: $0) } ?? "none"
        let interruptionOptions = info[AVAudioSessionInterruptionOptionKey].map { String(describing: $0) } ?? "none"
        let routeReason = info[AVAudioSessionRouteChangeReasonKey].map { String(describing: $0) } ?? "none"
        if event == "audio_interruption",
           let rawValue = (info[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
           let type = AVAudioSession.InterruptionType(rawValue: rawValue) {
            audioInterruptionActive = type == .began
        }
        record("\(event) interruption_type=\(interruptionType) interruption_options=\(interruptionOptions) route_reason=\(routeReason)")
    }

    private func recordApplicationState(prefix: String) {
        record("\(prefix) process_state=\(Self.applicationState(UIApplication.shared.applicationState))")
    }

    private func recordAudioSnapshot(prefix: String) {
        let route = audioSession.currentRoute
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let available = audioSession.availableInputs?.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",") ?? "none"
        record("\(prefix) category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) sample_rate=\(audioSession.sampleRate) io_buffer=\(audioSession.ioBufferDuration) inputs=[\(inputs)] outputs=[\(outputs)] available_inputs=[\(available)] interruption_active=\(audioInterruptionActive)")
    }

    private func recordVerdict(reason: String) {
        record("gateway_verdict reason=\(reason) CELLULAR_CALL_CONNECTED=\(verdict.cellularCallConnected) UPLINK_STRONG_EVIDENCE=\(verdict.uplinkStrongEvidence) DOWNLINK_DIGITAL_STREAM_PROVEN=\(verdict.downlinkDigitalStreamProven) FULL_GATEWAY_PASS=\(verdict.fullGatewayPass)")
    }

    private func recordError(_ stage: String, _ error: Error) {
        let value = error as NSError
        record("\(stage) result=failure domain=\(value.domain) code=\(value.code) description=\(Self.sanitized(value.localizedDescription))")
    }

    private func record(_ value: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("\(timestamp) \(value)")
        if logLines.count > 250 { logLines.removeFirst(logLines.count - 250) }
    }

    private static func validPhoneHandle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.first == "+" ? trimmed.dropFirst() : trimmed[...]
        guard (3...15).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return trimmed
    }

    private static func applicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func sanitized(_ value: String, redacting secret: String? = nil) -> String {
        let redacted = secret.map { value.replacingOccurrences(of: $0, with: "<redacted>") } ?? value
        return redacted.replacingOccurrences(of: "\n", with: " ").prefix(240).description
    }
}

extension IOSCellularAudioProbe: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.record("cx_call_changed outgoing=\(call.isOutgoing) connected=\(call.hasConnected) ended=\(call.hasEnded) on_hold=\(call.isOnHold) process_state=\(Self.applicationState(UIApplication.shared.applicationState))")
            if call.isOutgoing, call.hasConnected {
                var next = self.verdict
                next.cellularCallConnected = true
                self.verdict = next
                self.record("cellular_call_connected evidence=CXCallObserver.hasConnected")
            }
            self.recordVerdict(reason: "cx_call_state_changed")
            self.recordAudioSnapshot(prefix: "audio_at_call_change")
        }
    }
}

struct IOSCellularAudioProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var probe = IOSCellularAudioProbe.shared
    @State private var number = ""

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        TextField("Phone number", text: $number)
                            .keyboardType(.phonePad)
                            .textFieldStyle(.roundedBorder)

                        Button("START CELLULAR TEST") {
                            Task { await probe.startCellularTest(number: number) }
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Cellular services: \(probe.cellularServicesSummary)")
                            .font(.caption)
                        Text(probe.verdict.cellularCallConnected ? "CELLULAR CALL: CONNECTED" : "CELLULAR CALL: NOT CONNECTED")
                            .font(.caption.bold())

                        Button("START AUDIO PROBE") {
                            Task { await probe.startAudioProbe() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(probe.isAudioProbeRunning)

                        Text("Спочатку вимкніть мікрофон саме системного cellular-дзвінка (Mute), потім поверніться сюди і натисніть CONFIRM CELLULAR MIC MUTED.")
                            .font(.caption)

                        Button("CONFIRM CELLULAR MIC MUTED") {
                            probe.confirmCellularMicrophoneMuted()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!probe.verdict.cellularCallConnected)

                        Button("RUN UPLINK TONE") {
                            probe.runUplinkTone()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!probe.verdict.cellularCallConnected || !probe.verdict.userConfirmedCellularMicMuted || !probe.isAudioProbeRunning || probe.verdict.uplinkToneWasRun)

                        HStack {
                            Button("REMOTE HEARD TONE") { probe.reportRemoteHeardTone(true) }
                            Button("REMOTE DID NOT HEAR TONE") { probe.reportRemoteHeardTone(false) }
                        }
                        .font(.caption)
                        .disabled(!probe.verdict.uplinkToneWasRun)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("CELLULAR_CALL_CONNECTED: \(probe.verdict.cellularCallConnected ? "YES" : "NO")")
                            Text("UPLINK_STRONG_EVIDENCE: \(probe.verdict.uplinkStrongEvidence ? "YES" : "NO")")
                            Text("DOWNLINK_DIGITAL_STREAM_PROVEN: \(probe.verdict.downlinkDigitalStreamProven ? "YES" : "NO")")
                            Text("FULL_GATEWAY_PASS: \(probe.verdict.fullGatewayPass ? "YES" : "NO")")
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            Button("COPY LOG") { probe.copyLog() }
                            Button("STOP", role: .destructive) { probe.stop() }
                        }

                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(probe.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: probe.logLines.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            .navigationTitle("Cellular Audio Probe")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
