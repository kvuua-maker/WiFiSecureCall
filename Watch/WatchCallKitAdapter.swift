import AVFoundation
import CallKit
import Foundation

@MainActor
final class WatchCallKitAdapter: NSObject, CallKitHandling, CXProviderDelegate {
    var onPrepareAudio: (() throws -> Void)?
    var onActionFailed: ((UUID, String, Error) -> Void)?
    var onStartApproved: ((UUID) -> Void)?
    var onAnswerApproved: ((UUID) -> Void)?
    var onEndApproved: ((UUID) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    private let provider: CXProvider
    private let controller = CXCallController()

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init(); provider.setDelegate(self, queue: .main)
    }

    func startOutgoing(id: UUID) async throws { try await request(CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Wi-Fi call"))) }
    func reportIncoming(id: UUID) async throws {
        let update = CXCallUpdate(); update.localizedCallerName = "Incoming Wi-Fi call"; update.remoteHandle = CXHandle(type: .generic, value: "Wi-Fi call"); update.hasVideo = false
        try await withCheckedThrowingContinuation { continuation in provider.reportNewIncomingCall(with: id, update: update) { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume(returning: ()) } }
    }
    func requestAnswer(id: UUID) async throws { try await request(CXAnswerCallAction(call: id)) }
    func requestEnd(id: UUID) async throws { try await request(CXEndCallAction(call: id)) }
    func reportEnded(id: UUID) { provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded) }
    private func request(_ action: CXAction) async throws { try await withCheckedThrowingContinuation { continuation in controller.request(CXTransaction(action: action)) { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume(returning: ()) } } }

    nonisolated func providerDidReset(_ provider: CXProvider) {}
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            do {
                try onPrepareAudio?()
                onStartApproved?(action.callUUID)
                action.fulfill()
            } catch {
                action.fail()
                onActionFailed?(action.callUUID, "prepareStart", error)
            }
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            do {
                try onPrepareAudio?()
                onAnswerApproved?(action.callUUID)
                action.fulfill()
            } catch {
                action.fail()
                onActionFailed?(action.callUUID, "prepareAnswer", error)
            }
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) { Task { @MainActor in onEndApproved?(action.callUUID); action.fulfill() } }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { Task { @MainActor in onAudioActivated?() } }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { Task { @MainActor in onAudioDeactivated?() } }
}
