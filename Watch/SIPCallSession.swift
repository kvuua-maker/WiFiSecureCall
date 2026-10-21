import CallKit
import Foundation
import SwiftUI

/// The state the watch screen shows.
enum SIPCallUIState: Equatable {
    case idle
    case dialing(String)
    case ringing(String)
    case connecting(String)
    case active(String)
    case ended(String)
    case failed(String)

    var callID: String? {
        switch self {
        case .idle, .failed: return nil
        case let .dialing(id), let .ringing(id), let .connecting(id), let .active(id), let .ended(id): return id
        }
    }

    var isBusy: Bool {
        switch self {
        case .idle, .ended, .failed: return false
        default: return true
        }
    }
}

/// Drives one SIP call from the watch, with CallKit for the system call UI.
///
/// This is the whole point of the rewrite: the watch registers with the SIP server
/// itself, places its own INVITE, binds its own RTP socket and renders the audio.
/// No paired iPhone and no HTTP call API are involved.
@MainActor
final class SIPCallSession: NSObject, ObservableObject {
    @Published private(set) var state: SIPCallUIState = .idle
    @Published private(set) var registrationText = "Not registered"
    @Published private(set) var isRegistered = false
    @Published private(set) var isMuted = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var remoteDisplay = ""
    @Published private(set) var lastFailure: String?
    @Published private(set) var lastDialled: String?

    private let accountStore: SIPAccountStore
    private var client: SIPClient?
    private var callKit: (any CallKitHandling)?
    private let audio = SIPAudioEngine()
    private var media: RTPMediaSession?
    private var callKitUUID: UUID?
    private var mediaTokenCallID: String?
    private var durationTask: Task<Void, Never>?
    private var pendingOffer: Data?
    private var remoteMedia: SIPMediaDescription?

    init(accountStore: SIPAccountStore = .shared) {
        self.accountStore = accountStore
        super.init()
        audio.onDiagnostic = { line in
            Task { @MainActor [weak self] in self?.note(line) }
        }
    }

    // MARK: - CallKit wiring

    /// Creates the CallKit provider the first time the screen appears.
    ///
    /// CallKit has to exist before any call is reported, and the adapter holds the
    /// provider, so the session owns it for the lifetime of the app.
    func installCallKitAdapter() {
        guard callKit == nil else { return }
        let adapter = WatchCallKitAdapter()
        attach(callKit: adapter)
        self.callKit = adapter
    }

    func attach(callKit: any CallKitHandling) {
        self.callKit = callKit
        callKit.onPrepareAudio = {
            try AVAudioSession.sharedInstance().setActive(true)
        }
        callKit.onStartRequested = { [weak self] id, _ in
            await self?.beginOutgoing(callKitUUID: id)
        }
        callKit.onAnswerRequested = { [weak self] id, _ in
            await self?.beginAnswering(callKitUUID: id)
        }
        callKit.onEndRequested = { [weak self] id, _, _ in
            await self?.endCall(callKitUUID: id)
            return .ended
        }
        callKit.onMutedRequested = { [weak self] _, muted in
            self?.audio.setMuted(muted)
            self?.isMuted = muted
        }
        callKit.onAudioActivated = { [weak self] _ in
            self?.startMedia()
        }
        callKit.onAudioDeactivated = { [weak self] _ in
            self?.stopMedia()
        }
        callKit.onProviderReset = { [weak self] _ in
            self?.reset()
        }
        callKit.onActionFailed = { [weak self] _, stage, error in
            self?.lastFailure = "\(stage): \(error.localizedDescription)"
        }
    }

    // MARK: - Account

    func connect() {
        disconnect()
        let account = accountStore.account
        let password = accountStore.password
        guard account.isComplete, !password.isEmpty else {
            registrationText = "Add SIP account"
            isRegistered = false
            return
        }
        registrationText = "Connecting…"
        let client = SIPClient(account: account, password: password)
        client.delegate = self
        self.client = client
        client.start()
    }

    func disconnect() {
        client?.stop()
        client = nil
        isRegistered = false
        registrationText = "Not registered"
    }

    // MARK: - Outgoing

    func placeCall(to destination: String) {
        guard !state.isBusy else { return }
        guard isRegistered, client != nil else {
            lastFailure = "SIP account is not registered"
            return
        }
        let localUUID = UUID()
        callKitUUID = localUUID
        state = .dialing(destination)
        remoteDisplay = destination
        lastDialled = destination

        // Bind the media socket before the offer so the SDP states the real port.
        do {
            let rtp = RTPMediaSession(payloadType: SIPCodec.pcmu.rawValue)
            let endpoint = try rtp.open(probeHost: accountStore.account.host, probePort: 443)
            media = rtp
            audio.codec = .pcmu
            let offer = SDP.make(
                address: endpoint.address,
                port: endpoint.port,
                codecs: SIPConfiguration.preferredCodecs,
                sessionID: UInt64.random(in: 1...UInt64.max)
            )
            pendingOffer = offer
            rtp.onFrame = { [weak self] payload in
                Task { @MainActor in self?.receiveMedia(payload: payload) }
            }
        } catch {
            state = .failed("Media socket: \(error)")
            lastFailure = "\(error)"
            return
        }

        Task {
            do {
                guard let callKit else { return }
                try await callKit.startOutgoing(id: localUUID)
            } catch {
                await fail("CallKit refused the call")
            }
        }
    }

    private func beginOutgoing(callKitUUID: UUID) async {
        guard let client, let offer = pendingOffer else {
            await fail("No media offer")
            return
        }
        let destination = remoteDisplay
        let callID = client.placeCall(to: destination, offer: offer)
        mediaTokenCallID = callID
        state = .dialing(destination)
        callKit?.reportOutgoingStartedConnecting(id: callKitUUID)
    }

    // MARK: - Incoming

    /// Asks the system to answer, which is what makes CallKit activate audio.
    func answerIncoming() {
        guard case .ringing = state, let callKitUUID else { return }
        Task {
            do {
                try await callKit?.requestAnswer(id: callKitUUID)
            } catch {
                await fail("Could not answer the call")
            }
        }
    }

    private func beginAnswering(callKitUUID: UUID) async {
        guard let client, let callID = mediaTokenCallID else {
            await fail("No incoming call to answer")
            return
        }
        do {
            let rtp = RTPMediaSession()
            let endpoint = try rtp.open(probeHost: accountStore.account.host, probePort: 443)
            let answer = SDP.make(
                address: endpoint.address,
                port: endpoint.port,
                codecs: SIPConfiguration.preferredCodecs,
                sessionID: UInt64.random(in: 1...UInt64.max)
            )
            media = rtp
            rtp.onFrame = { [weak self] payload in
                Task { @MainActor in self?.receiveMedia(payload: payload) }
            }
            if let remote = remoteMedia {
                rtp.connect(to: .init(address: remote.address, port: remote.port))
                audio.codec = remote.codec
                rtp.updatePayloadType(remote.payloadType)
            }
            client.accept(callID: callID, answer: answer)
            state = .connecting(remoteDisplay)
        } catch {
            await fail("Media socket: \(error)")
        }
    }

    // MARK: - Ending

    func hangUp() {
        Task {
            if let callKitUUID {
                try? await callKit?.requestEnd(id: callKitUUID)
            }
        }
    }

    private func endCall(callKitUUID: UUID) async {
        if let callID = mediaTokenCallID {
            client?.hangUp(callID: callID)
        }
        stopMedia()
        durationTask?.cancel()
        durationTask = nil
        if let callKitUUID {
            callKit?.reportEnded(id: callKitUUID, reason: .localEnded)
        }
        state = .ended(mediaTokenCallID ?? "")
        mediaTokenCallID = nil
        callKitUUID = nil
    }

    func sendDTMF(_ digit: String) {
        guard case .active = state, let callID = mediaTokenCallID else { return }
        client?.sendDTMF(digit)
    }

    func toggleMute() {
        guard let callKitUUID else { return }
        Task { try? await callKit?.requestSetMuted(id: callKitUUID, muted: !isMuted) }
    }

    func reset() {
        stopMedia()
        durationTask?.cancel()
        durationTask = nil
        state = .idle
        mediaTokenCallID = nil
        callKitUUID = nil
        elapsedSeconds = 0
        remoteDisplay = ""
    }

    // MARK: - Media

    private func startMedia() {
        guard media != nil else { return }
        do {
            try audio.configureSession()
            try audio.start()
            let socket = media
            audio.onEncodedFrame = { payload in
                socket?.send(payload: payload)
            }
        } catch {
            lastFailure = "Audio: \(error)"
        }
    }

    private func stopMedia() {
        audio.stop()
        audio.onEncodedFrame = nil
        media?.close()
        media = nil
    }

    private func receiveMedia(payload: Data) {
        let codec = audio.codec
        audio.enqueueEncodedFrame(payload, codec: codec)
    }

    // MARK: - Reporting

    private func callConnected(media remote: SIPMediaDescription?) {
        state = .active(remoteDisplay)
        if let remote, let rtp = media {
            rtp.connect(to: .init(address: remote.address, port: remote.port))
            audio.codec = remote.codec
            rtp.updatePayloadType(remote.payloadType)
        }
        if let callKitUUID {
            callKit?.reportOutgoingConnected(id: callKitUUID)
        }
        startDurationTimer()
    }

    private func startDurationTimer() {
        durationTask?.cancel()
        elapsedSeconds = 0
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func fail(_ reason: String) async {
        lastFailure = reason
        state = .failed(reason)
        stopMedia()
        durationTask?.cancel()
        if let callKitUUID {
            callKit?.reportEnded(id: callKitUUID, reason: .failed)
        }
        if let callID = mediaTokenCallID {
            client?.hangUp(callID: callID)
        }
        mediaTokenCallID = nil
        callKitUUID = nil
    }

    private func note(_ line: String) {
        #if DEBUG
        print("[sip] \(line)")
        #endif
    }
}

// MARK: - SIPClientDelegate

extension SIPCallSession: SIPClientDelegate {
    nonisolated func sipClient(_ client: SIPClient, didChange state: SIPClientState) {
        Task { @MainActor in
            switch state {
            case .registered:
                self.isRegistered = true
                self.registrationText = "Registered"
            case .registering:
                self.registrationText = "Registering…"
            case .connecting:
                self.registrationText = "Connecting…"
            case .idle:
                self.isRegistered = false
                self.registrationText = "Not registered"
            case let .failed(reason):
                self.isRegistered = false
                self.registrationText = "Registration failed"
                self.lastFailure = reason
            }
        }
    }

    nonisolated func sipClient(_ client: SIPClient, didReceive event: SIPClientEvent) {
        Task { @MainActor in
            switch event {
            case let .incoming(callID, from, displayName, offer):
                self.remoteDisplay = displayName.isEmpty ? SIPClient.displayName(from: from) : displayName
                self.mediaTokenCallID = callID
                self.remoteMedia = offer
                self.state = .ringing(self.remoteDisplay)
                let localUUID = UUID()
                self.callKitUUID = localUUID
                do {
                    try await self.callKit?.reportIncoming(id: localUUID, callerName: self.remoteDisplay)
                } catch {
                    client.reject(callID: callID, code: 486)
                    await self.fail("CallKit rejected the incoming call")
                }
            case let .progressing(_, code, _):
                if code == 180 || code == 183 {
                    self.state = .ringing(self.remoteDisplay)
                }
            case let .answered(_, media):
                self.callConnected(media: media)
            case let .terminated(callID, code, reason):
                guard self.mediaTokenCallID == callID else { return }
                if case .active = self.state {
                    self.state = .ended(reason)
                } else if !self.state.isBusy {
                    return
                } else {
                    self.state = .ended(reason)
                }
                if let uuid = self.callKitUUID {
                    self.callKit?.reportEnded(id: uuid, reason: code == 200 ? .remoteEnded : .declined)
                }
                self.stopMedia()
                self.durationTask?.cancel()
                self.mediaTokenCallID = nil
                self.callKitUUID = nil
            case let .failed(callID, reason):
                guard self.mediaTokenCallID == callID else { return }
                await self.fail(reason)
            case let .mediaUpdated(callID, media):
                guard self.mediaTokenCallID == callID, let rtp = self.media else { return }
                rtp.connect(to: .init(address: media.address, port: media.port))
            }
        }
    }
}
