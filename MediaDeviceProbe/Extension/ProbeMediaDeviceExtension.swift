import Foundation
import MediaDevice
import Network
import UniformTypeIdentifiers

@main
@available(iOS 27.0, *)
final class ProbeMediaDeviceExtension: MediaDeviceExtension, RealtimeSampleHandling {
    private static let protocolIdentifier = "media-device-protocol.com.vkapps.wifisecurecall.mediadeviceprobe"
    private static let deviceID = UUID(uuidString: "9E342CB6-9EB2-47F6-BBD6-0A4B7054A827")!

    var protocolType: UTType {
        UTType(exportedAs: Self.protocolIdentifier)
    }

    var supportsSimultaneousSessions: Bool { false }

    lazy var routingManager: MediaDeviceRoutingManager = .routingManager(for: self)

    required init() {}

    func startDeviceDiscovery() {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)

        guard let device = MediaOutputDevice(
            id: Self.deviceID,
            displayName: "WiFi Secure Call Probe",
            capabilities: [.realtimeAudioStreaming],
            canGroupWithCurrentlyActivatedDevices: false,
            deviceType: .hifiSpeaker,
            volumeControl: .none,
            canMute: false,
            requiredNetworkEndpoints: [endpoint],
            supportsSimultaneousSessions: false
        ) else {
            return
        }

        routingManager.foundDevice(device)
    }

    func stopDeviceDiscovery() {}

    func activateDevice(
        _ device: MediaOutputDevice,
        session: MediaOutputSession,
        for deviceFeatures: MediaOutputDevice.Capabilities
    ) {
        routingManager.activatedDevice(device, session: session)
    }

    func connectUsingPairingCode(
        _ pairingCode: String?,
        to device: MediaOutputDevice,
        session: MediaOutputSession
    ) {
        routingManager.activatedDevice(device, session: session)
    }

    func deactivateDevice(
        _ device: MediaOutputDevice,
        session: MediaOutputSession
    ) {}

    func setVolume(_ volume: Float, for device: MediaOutputDevice) {}

    func volume(for device: MediaOutputDevice) -> Float { 1.0 }

    func changeVolume(by increments: Int, for device: MediaOutputDevice) {}

    func muteDevice(_ device: MediaOutputDevice) {}

    func isDeviceMuted(_ device: MediaOutputDevice) -> Bool { false }

    func startSession(
        _ session: MediaOutputSession,
        identifier: String?,
        url: URL
    ) {}

    func stopSession(_ session: MediaOutputSession) {}

    func sendData(
        _ data: Data,
        toApplication applicationIdentifier: String,
        session: MediaOutputSession
    ) {}

    func startRealtimeSampleDelivery(session: MediaOutputSession) {
        // Route-visibility probe only.
        // A real AudioServerPlugIn is intentionally deferred until Phone-route eligibility is proven.
    }

    func stopRealtimeSampleDelivery(session: MediaOutputSession) {}
}
