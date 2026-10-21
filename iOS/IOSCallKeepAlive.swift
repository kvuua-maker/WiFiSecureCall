import AVFoundation
import Foundation
import UIKit

/// Keeps the iPhone side of the bridge alive for as long as a call is up.
///
/// This is deliberately scoped to a call. Apple grants no way to keep a
/// third-party app running around the clock: a background task is a few minutes,
/// and a silent audio stream used only to stay resident is rejected under
/// guideline 2.5.4 and is killed anyway once the session stops producing sound.
/// What is allowed, and what this class does, is:
///
///   * hold a background task while the call is being set up and torn down,
///   * keep the audio session active so the call itself keeps the app running,
///   * ping the watch every few seconds so a link that dies is noticed now rather
///     than at the next dial,
///   * give up cleanly at the end instead of pretending to be alive.
///
/// Between calls the app is woken by a VoIP push, which is the supported
/// mechanism and the reason incoming calls still arrive after hours of sleep.
@MainActor
final class IOSCallKeepAlive {
    static let shared = IOSCallKeepAlive()

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var heartbeat: Task<Void, Never>?
    private var isInCall = false
    /// Each renewal buys a few more minutes. Capped so a bug cannot turn into an
    /// endless background loop, which is what App Review looks for.
    private var renewals = 0
    private let maximumRenewals = 2

    private init() {}

    func callDidStart() {
        guard !isInCall else { return }
        isInCall = true
        renewals = 0
        beginBackgroundTask()
        startHeartbeat()
        // The call owns the audio session; re-asserting the category here means a
        // call that began from a push does not depend on the UI having run.
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func callDidEnd() {
        guard isInCall else { return }
        isInCall = false
        stopHeartbeat()
        endBackgroundTask()
        renewals = 0
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "wifi-secure-call.active-call") { [weak self] in
            Task { @MainActor in self?.backgroundTaskExpired() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func backgroundTaskExpired() {
        endBackgroundTask()
        guard isInCall, renewals < maximumRenewals else { return }
        renewals += 1
        // Renewing is not a way to run forever: it covers the gap between the
        // call's audio session being set up and the system deciding the app is an
        // audio app, which is a transitional state, not a steady one.
        beginBackgroundTask()
    }

    // MARK: - Heartbeat

    /// A ping every ten seconds while a call is up.
    ///
    /// The watch is awake during a call too (it is rendering or driving audio), so
    /// this measures the link honestly. It is not a way to wake a sleeping device:
    /// a ping is not delivered to a suspended app.
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.isInCall else { return }
                    IOSWatchCallBridge.shared.send(WatchBridgeMessage(kind: .ping))
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }
}
