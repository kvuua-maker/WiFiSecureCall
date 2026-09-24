import Foundation

struct CellularAudioGatewayVerdict: Equatable, Sendable {
    var cellularCallConnected = false
    var userConfirmedCellularMicMuted = false
    var uplinkToneWasRun = false
    var remoteHeardTone: Bool?
    var downlinkDigitalStreamProven = false

    var uplinkStrongEvidence: Bool {
        cellularCallConnected
            && userConfirmedCellularMicMuted
            && uplinkToneWasRun
            && remoteHeardTone == true
    }

    var fullGatewayPass: Bool {
        cellularCallConnected && uplinkStrongEvidence && downlinkDigitalStreamProven
    }
}
