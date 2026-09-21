import CallKit
import Foundation
import AVFoundation

@MainActor
final class IOSCallKitAdapter: NSObject, CallKitHandling, CXProviderDelegate {
    var onPrepareAudio: (() throws -> Void)?
    var onActionFailed: ((UUID, String, Error) -> Void)?
    var onStartApproved: ((UUID) -> Void)?
    var onAnswerApproved: ((UUID) -> Void)?
    var onEndApproved: ((UUID) -> Void)?
    var onAudioActivated: ((UUID) -> Void)?
    var onAudioDeactivated: ((UUID?) -> Void)?
    var onProviderReset: ((UUID?) -> Void)?
    private let provider: CXProvider
    private let controller = CXCallController()
    private var currentCallUUID: UUID?
    private var pendingAudioCallUUID: UUID?
    private var activatedAudioCallUUID: UUID?

    override init() {
        provider = CXProvider(configuration: Self.configuration())
        super.init(); provider.setDelegate(self, queue: .main)
    }

    func startOutgoing(id: UUID) async throws {
        provider.configuration = Self.configuration()
        currentCallUUID = id
        try await request(CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Wi-Fi call")))
    }
    func reportIncoming(id: UUID) async throws {
        provider.configuration = Self.configuration()
        currentCallUUID = id
        let update = CXCallUpdate(); update.localizedCallerName = "Incoming Wi-Fi call"; update.remoteHandle = CXHandle(type: .generic, value: "Wi-Fi call"); update.hasVideo = false
        try await withCheckedThrowingContinuation { continuation in provider.reportNewIncomingCall(with: id, update: update) { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume(returning: ()) } }
    }
    func requestAnswer(id: UUID) async throws { try await request(CXAnswerCallAction(call: id)) }
    func requestEnd(id: UUID) async throws { try await request(CXEndCallAction(call: id)) }
    func reportOutgoingStartedConnecting(id: UUID) { provider.reportOutgoingCall(with: id, startedConnectingAt: Date()) }
    func reportOutgoingConnected(id: UUID) { provider.reportOutgoingCall(with: id, connectedAt: Date()) }
    func reportEnded(id: UUID) {
        provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
        if currentCallUUID == id { currentCallUUID = nil }
        if pendingAudioCallUUID == id { pendingAudioCallUUID = nil }
        if activatedAudioCallUUID == id { activatedAudioCallUUID = nil }
    }
    private func request(_ action: CXAction) async throws { try await withCheckedThrowingContinuation { continuation in controller.request(CXTransaction(action: action)) { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume(returning: ()) } } }

    private static func configuration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration(localizedName: "WiFi Secure Call")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        return configuration
    }

    nonisolated func providerDidReset(_ provider: CXProvider) { Task { @MainActor in
        let id = currentCallUUID ?? activatedAudioCallUUID ?? pendingAudioCallUUID
        currentCallUUID = nil; pendingAudioCallUUID = nil; activatedAudioCallUUID = nil
        onProviderReset?(id)
    } }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            do {
                try onPrepareAudio?()
                pendingAudioCallUUID = action.callUUID
                currentCallUUID = action.callUUID
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
                pendingAudioCallUUID = action.callUUID
                currentCallUUID = action.callUUID
                onAnswerApproved?(action.callUUID)
                action.fulfill()
            } catch {
                action.fail()
                onActionFailed?(action.callUUID, "prepareAnswer", error)
            }
        }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) { Task { @MainActor in onEndApproved?(action.callUUID); action.fulfill() } }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { Task { @MainActor in
        guard let id = pendingAudioCallUUID ?? currentCallUUID else { return }
        activatedAudioCallUUID = id; pendingAudioCallUUID = nil; onAudioActivated?(id)
    } }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { Task { @MainActor in
        let id = activatedAudioCallUUID; activatedAudioCallUUID = nil; onAudioDeactivated?(id)
    } }
}
