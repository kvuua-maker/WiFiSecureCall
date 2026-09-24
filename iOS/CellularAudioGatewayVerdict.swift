import Foundation

enum CellularCallProbeStatus: String, Equatable, Sendable {
    case notStarted = "NOT STARTED"
    case dialing = "DIALING"
    case connected = "CONNECTED"
    case ended = "ENDED"
}

enum ProbeAudioStatus: String, Equatable, Sendable {
    case notStarted = "NOT STARTED"
    case running = "RUNNING"
    case interrupted = "INTERRUPTED"
    case stopped = "STOPPED"
    case failed = "FAILED"
}

enum PostConnectAudioStatus: String, Equatable, Sendable {
    case notTested = "NOT TESTED"
    case running = "RUNNING"
    case failed = "FAILED"
}

enum ProbeAudioSessionStatus: String, Equatable, Sendable {
    case activeAttemptSuccess = "ACTIVE-ATTEMPT-SUCCESS"
    case failed = "FAILED"
    case interrupted = "INTERRUPTED"
    case unknown = "UNKNOWN"
}

enum ProbeAudioEngineStatus: String, Equatable, Sendable {
    case running = "RUNNING"
    case stopped = "STOPPED"
    case failed = "FAILED"
}

enum ProbeAudioMode: String, Equatable, Sendable {
    case prearm = "prearm"
    case postConnect = "post_connect"
}

enum UplinkToneBlockReason: String, Equatable, Sendable {
    case callNotConnected = "CALL_NOT_CONNECTED"
    case cellularMicNotConfirmedMuted = "CELLULAR_MIC_NOT_CONFIRMED_MUTED"
    case appAudioNotRunning = "APP_AUDIO_NOT_RUNNING"
    case toneAlreadyRun = "TONE_ALREADY_RUN"
}

struct ProbeAudioError: Equatable, Sendable {
    let stage: String
    let domain: String
    let code: Int
    let description: String
}

struct CellularAudioProbeState: Equatable, Sendable {
    var callStatus: CellularCallProbeStatus = .notStarted
    var prearmStatus: ProbeAudioStatus = .notStarted
    var postConnectStatus: PostConnectAudioStatus = .notTested
    var audioSessionStatus: ProbeAudioSessionStatus = .unknown
    var audioEngineStatus: ProbeAudioEngineStatus = .stopped
    var activeAudioMode: ProbeAudioMode?
    var prearmSurvivedCellularConnect: Bool?
    var lastAudioError: ProbeAudioError?
    var interruptionActive = false
    var resumeAvailable = false
    var resumeAttempted = false

    mutating func markCallDialing() {
        callStatus = .dialing
        prearmSurvivedCellularConnect = nil
        resumeAvailable = false
        resumeAttempted = false
    }

    mutating func markCallConnected(engineIsRunning: Bool) {
        callStatus = .connected
        guard activeAudioMode == .prearm else { return }
        let survived = engineIsRunning && prearmStatus == .running && !interruptionActive
        prearmSurvivedCellularConnect = survived
        if !survived, prearmStatus != .interrupted {
            prearmStatus = .stopped
            audioEngineStatus = .stopped
        }
    }

    mutating func markCallEnded() {
        callStatus = .ended
    }

    mutating func markAudioRunning(mode: ProbeAudioMode) {
        activeAudioMode = mode
        audioSessionStatus = .activeAttemptSuccess
        audioEngineStatus = .running
        lastAudioError = nil
        interruptionActive = false
        resumeAvailable = false
        if mode == .prearm {
            prearmStatus = .running
        } else {
            postConnectStatus = .running
        }
    }

    mutating func markAudioFailure(mode: ProbeAudioMode, error: ProbeAudioError) {
        activeAudioMode = mode
        audioSessionStatus = .failed
        audioEngineStatus = .failed
        lastAudioError = error
        if mode == .prearm {
            prearmStatus = .failed
        } else {
            postConnectStatus = .failed
        }
    }

    mutating func markInterruptionBegan(engineWasRunning: Bool) {
        interruptionActive = true
        audioSessionStatus = .interrupted
        if engineWasRunning || audioEngineStatus == .running { audioEngineStatus = .stopped }
        resumeAvailable = false
        if activeAudioMode == .prearm {
            prearmStatus = .interrupted
            if callStatus == .connected { prearmSurvivedCellularConnect = false }
        }
    }

    mutating func markInterruptionEnded(shouldResume: Bool) {
        interruptionActive = false
        resumeAvailable = shouldResume && !resumeAttempted
    }

    mutating func markStopped() {
        audioEngineStatus = .stopped
        audioSessionStatus = .unknown
        if activeAudioMode == .prearm, prearmStatus == .running { prearmStatus = .stopped }
        if activeAudioMode == .postConnect, postConnectStatus == .running { postConnectStatus = .notTested }
    }

    func uplinkToneBlockReasons(verdict: CellularAudioGatewayVerdict) -> [UplinkToneBlockReason] {
        var reasons: [UplinkToneBlockReason] = []
        if !verdict.cellularCallConnected { reasons.append(.callNotConnected) }
        if !verdict.userConfirmedCellularMicMuted { reasons.append(.cellularMicNotConfirmedMuted) }
        if audioEngineStatus != .running { reasons.append(.appAudioNotRunning) }
        if verdict.uplinkToneWasRun { reasons.append(.toneAlreadyRun) }
        return reasons
    }
}

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
