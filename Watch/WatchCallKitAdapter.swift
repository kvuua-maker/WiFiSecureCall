import AVFoundation
import CallKit
import Foundation

@MainActor
final class WatchCallKitAdapter: NSObject, CallKitHandling, CXProviderDelegate {
    let diagnosticInstanceID = UUID()
    var onLifecycleDiagnostic: ((String, UUID?) -> Void)?
    var onPrepareAudio: (() throws -> Void)?
    var onActionFailed: ((UUID, String, Error) -> Void)?
    var onStartRequested: ((UUID, Date) async throws -> Void)?
    var onAnswerRequested: ((UUID, Date) async throws -> Void)?
    var onEndRequested: ((UUID, Date, CallEndRequestOrigin) async throws -> CallEndDisposition)?
    var onMutedRequested: ((UUID, Bool) throws -> Void)?
    var onActionTimedOut: ((UUID, String) -> Void)?
    var onAudioActivated: ((UUID) -> Void)?
    var onAudioDeactivated: ((UUID?) -> Void)?
    var onProviderReset: ((UUID?) -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController(queue: .main)
    private var currentCallUUID: UUID?
    private var pendingAudioCallUUID: UUID?
    private var activatedAudioCallUUID: UUID?
    private var appRequestedEndCallUUIDs: Set<UUID> = []

    override init() {
        provider = CXProvider(configuration: Self.configuration())
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func startOutgoing(id: UUID) async throws {
        provider.configuration = Self.configuration(); currentCallUUID = id
        onLifecycleDiagnostic?("start_transaction_submitted", id)
        do {
            try await controller.request(CXTransaction(action: CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Wi-Fi call"))))
            onLifecycleDiagnostic?("start_transaction_accepted", id)
        }
        catch { clear(id); throw error }
    }
    func reportIncoming(id: UUID) async throws { try await reportIncoming(id: id, callerName: nil) }
    func reportIncoming(id: UUID, callerName: String?) async throws {
        provider.configuration = Self.configuration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.reportNewIncomingCall(with: id, update: Self.callUpdate(callerName: callerName)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
        currentCallUUID = id
    }
    func requestAnswer(id: UUID) async throws { try await controller.request(CXTransaction(action: CXAnswerCallAction(call: id))) }
    func requestEnd(id: UUID) async throws {
        if appRequestedEndCallUUIDs.count >= 4 { appRequestedEndCallUUIDs.removeAll(keepingCapacity: true) }
        appRequestedEndCallUUIDs.insert(id)
        do { try await controller.request(CXTransaction(action: CXEndCallAction(call: id))) }
        catch { appRequestedEndCallUUIDs.remove(id); throw error }
    }
    func requestSetMuted(id: UUID, muted: Bool) async throws { try await controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) }
    func reportOutgoingStartedConnecting(id: UUID) { provider.reportOutgoingCall(with: id, startedConnectingAt: Date()) }
    func reportOutgoingConnected(id: UUID) { provider.reportOutgoingCall(with: id, connectedAt: Date()) }
    func reportEnded(id: UUID, reason: CallEndReason) { provider.reportCall(with: id, endedAt: Date(), reason: Self.cxReason(reason)); clear(id) }
    private static func configuration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration(localizedName: "WiFi Secure Call")
        configuration.supportsVideo = false; configuration.maximumCallGroups = 1; configuration.maximumCallsPerCallGroup = 1; configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true
        return configuration
    }
    private static func callUpdate(callerName: String? = nil) -> CXCallUpdate {
        let update = CXCallUpdate(); update.localizedCallerName = callerName ?? "Incoming Wi-Fi call"; update.remoteHandle = CXHandle(type: .generic, value: "Wi-Fi call"); update.hasVideo = false
        update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false; update.supportsDTMF = false
        return update
    }
    private static func cxReason(_ reason: CallEndReason) -> CXCallEndedReason {
        switch reason { case .remoteEnded: return .remoteEnded; case .failed: return .failed; case .unanswered: return .unanswered; case .declined: return .declinedElsewhere; case .localEnded: return .remoteEnded }
    }
    private func clear(_ id: UUID) { if currentCallUUID == id { currentCallUUID = nil }; if pendingAudioCallUUID == id { pendingAudioCallUUID = nil }; if activatedAudioCallUUID == id { activatedAudioCallUUID = nil }; appRequestedEndCallUUIDs.remove(id) }
    private func perform(_ action: CXCallAction, stage: String, operation: @escaping (UUID, Date) async throws -> Void) async { do { try await operation(action.callUUID, action.timeoutDate); guard !action.isComplete else { return }; action.fulfill(); if stage == "start" { onLifecycleDiagnostic?("start_action_fulfilled", action.callUUID) } } catch { if !action.isComplete { action.fail() }; onActionFailed?(action.callUUID, stage, error) } }

    nonisolated func providerDidReset(_ provider: CXProvider) { Task { @MainActor in let id = currentCallUUID ?? activatedAudioCallUUID ?? pendingAudioCallUUID; onLifecycleDiagnostic?("provider_reset", id); currentCallUUID = nil; pendingAudioCallUUID = nil; activatedAudioCallUUID = nil; appRequestedEndCallUUIDs.removeAll(keepingCapacity: true); onProviderReset?(id) } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) { Task { @MainActor in await self.perform(action, stage: "start") { [self] id, deadline in self.onLifecycleDiagnostic?("provider_perform_start_received", id); try self.onPrepareAudio?(); guard let handler = self.onStartRequested else { throw CallKitCoordinatorError.missingCoordinator }; self.pendingAudioCallUUID = id; self.currentCallUUID = id; try await handler(id, deadline) } } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { Task { @MainActor in await self.perform(action, stage: "answer") { [self] id, deadline in try self.onPrepareAudio?(); guard let handler = self.onAnswerRequested else { throw CallKitCoordinatorError.missingCoordinator }; self.pendingAudioCallUUID = id; self.currentCallUUID = id; try await handler(id, deadline) } } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) { Task { @MainActor in
        let origin: CallEndRequestOrigin = self.appRequestedEndCallUUIDs.remove(action.callUUID) == nil ? .system : .appRequested
        do {
            guard let handler = self.onEndRequested else { throw CallKitCoordinatorError.missingCoordinator }
            let disposition = try await handler(action.callUUID, action.timeoutDate, origin)
            guard !action.isComplete else { return }
            if disposition == .preserveCall { action.fail() } else { action.fulfill() }
        } catch {
            if !action.isComplete { action.fail() }
            self.onActionFailed?(action.callUUID, "end", error)
        }
    } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) { Task { @MainActor in do { guard let handler = onMutedRequested else { throw CallKitCoordinatorError.missingCoordinator }; try handler(action.callUUID, action.isMuted); if !action.isComplete { action.fulfill() } } catch { if !action.isComplete { action.fail() }; onActionFailed?(action.callUUID, "mute", error) } } }
    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) { Task { @MainActor in let id = (action as? CXCallAction)?.callUUID ?? action.uuid; if action is CXStartCallAction { onLifecycleDiagnostic?("start_action_timed_out", id) }; onActionTimedOut?(id, String(describing: type(of: action))) } }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { Task { @MainActor in guard let id = pendingAudioCallUUID ?? currentCallUUID else { return }; activatedAudioCallUUID = id; pendingAudioCallUUID = nil; onAudioActivated?(id) } }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { Task { @MainActor in let id = activatedAudioCallUUID; activatedAudioCallUUID = nil; onAudioDeactivated?(id) } }
}
