import AVFoundation
import CallKit
import Foundation

@MainActor
final class WatchCallKitAdapter: NSObject, CallKitHandling, CXProviderDelegate {
    var onPrepareAudio: (() throws -> Void)?
    var onActionFailed: ((UUID, String, Error) -> Void)?
    var onStartRequested: ((UUID, Date) async throws -> Void)?
    var onAnswerRequested: ((UUID, Date) async throws -> Void)?
    var onEndRequested: ((UUID, Date) async throws -> Void)?
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

    override init() {
        provider = CXProvider(configuration: Self.configuration())
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func startOutgoing(id: UUID) async throws {
        provider.configuration = Self.configuration(); currentCallUUID = id
        do { try await request(CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Wi-Fi call"))) }
        catch { clear(id); throw error }
    }
    func reportIncoming(id: UUID) async throws {
        provider.configuration = Self.configuration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.reportNewIncomingCall(with: id, update: Self.callUpdate()) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
        currentCallUUID = id
    }
    func requestAnswer(id: UUID) async throws { try await request(CXAnswerCallAction(call: id)) }
    func requestEnd(id: UUID) async throws { try await request(CXEndCallAction(call: id)) }
    func requestSetMuted(id: UUID, muted: Bool) async throws { try await request(CXSetMutedCallAction(call: id, muted: muted)) }
    func reportOutgoingStartedConnecting(id: UUID) { provider.reportOutgoingCall(with: id, startedConnectingAt: Date()) }
    func reportOutgoingConnected(id: UUID) { provider.reportOutgoingCall(with: id, connectedAt: Date()) }
    func reportEnded(id: UUID, reason: CallEndReason) { provider.reportCall(with: id, endedAt: Date(), reason: Self.cxReason(reason)); clear(id) }
    private func request(_ action: CXAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = WatchCallKitRequestCompletion(continuation)
            controller.request(CXTransaction(action: action)) { error in completion.finish(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + CallTimeouts.httpRequest) { completion.finish(NSError(domain: "WiFiSecureCall.CallKitTransaction", code: 1)) }
        }
    }

    private static func configuration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false; configuration.maximumCallGroups = 1; configuration.maximumCallsPerCallGroup = 1; configuration.supportedHandleTypes = [.generic]
        return configuration
    }
    private static func callUpdate() -> CXCallUpdate {
        let update = CXCallUpdate(); update.localizedCallerName = "Incoming Wi-Fi call"; update.remoteHandle = CXHandle(type: .generic, value: "Wi-Fi call"); update.hasVideo = false
        update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false; update.supportsDTMF = false
        return update
    }
    private static func cxReason(_ reason: CallEndReason) -> CXCallEndedReason {
        switch reason { case .remoteEnded: return .remoteEnded; case .failed: return .failed; case .unanswered: return .unanswered; case .declined: return .declinedElsewhere; case .localEnded: return .remoteEnded }
    }
    private func clear(_ id: UUID) { if currentCallUUID == id { currentCallUUID = nil }; if pendingAudioCallUUID == id { pendingAudioCallUUID = nil }; if activatedAudioCallUUID == id { activatedAudioCallUUID = nil } }
    private func perform(_ action: CXCallAction, stage: String, operation: @escaping (UUID, Date) async throws -> Void) async { do { try await operation(action.callUUID, action.timeoutDate); guard !action.isComplete else { return }; action.fulfill() } catch { if !action.isComplete { action.fail() }; onActionFailed?(action.callUUID, stage, error) } }

    nonisolated func providerDidReset(_ provider: CXProvider) { Task { @MainActor in let id = currentCallUUID ?? activatedAudioCallUUID ?? pendingAudioCallUUID; currentCallUUID = nil; pendingAudioCallUUID = nil; activatedAudioCallUUID = nil; onProviderReset?(id) } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) { Task { @MainActor in await self.perform(action, stage: "start") { [self] id, deadline in try self.onPrepareAudio?(); guard let handler = self.onStartRequested else { throw CallKitCoordinatorError.missingCoordinator }; self.pendingAudioCallUUID = id; self.currentCallUUID = id; try await handler(id, deadline) } } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { Task { @MainActor in await self.perform(action, stage: "answer") { [self] id, deadline in try self.onPrepareAudio?(); guard let handler = self.onAnswerRequested else { throw CallKitCoordinatorError.missingCoordinator }; self.pendingAudioCallUUID = id; self.currentCallUUID = id; try await handler(id, deadline) } } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) { Task { @MainActor in await self.perform(action, stage: "end") { [self] id, deadline in guard let handler = self.onEndRequested else { throw CallKitCoordinatorError.missingCoordinator }; try await handler(id, deadline) } } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) { Task { @MainActor in do { guard let handler = onMutedRequested else { throw CallKitCoordinatorError.missingCoordinator }; try handler(action.callUUID, action.isMuted); if !action.isComplete { action.fulfill() } } catch { if !action.isComplete { action.fail() }; onActionFailed?(action.callUUID, "mute", error) } } }
    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) { Task { @MainActor in onActionTimedOut?((action as? CXCallAction)?.callUUID ?? action.uuid, String(describing: type(of: action))) } }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { Task { @MainActor in guard let id = pendingAudioCallUUID ?? currentCallUUID else { return }; activatedAudioCallUUID = id; pendingAudioCallUUID = nil; onAudioActivated?(id) } }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { Task { @MainActor in let id = activatedAudioCallUUID; activatedAudioCallUUID = nil; onAudioDeactivated?(id) } }
}

private final class WatchCallKitRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        let value = lock.withLock { () -> CheckedContinuation<Void, Error>? in let result = continuation; continuation = nil; return result }
        guard let value else { return }
        if let error { value.resume(throwing: error) } else { value.resume(returning: ()) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
