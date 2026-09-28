import Foundation

final class TransmitMuteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var muted = false
    private let frameSize: Int
    private lazy var silence = Data(repeating: 0, count: frameSize)

    init(frameSize: Int = AudioEngine.bytesPerFrame) { self.frameSize = frameSize }

    var isMuted: Bool { lock.wscLocked { muted } }

    @discardableResult
    func setMuted(_ value: Bool) -> Bool {
        lock.wscLocked {
            let changed = muted != value
            muted = value
            return changed
        }
    }

    func outgoingFrame(_ captured: Data) -> Data {
        guard captured.count == frameSize else { return captured }
        return lock.wscLocked { muted ? silence : captured }
    }

    func reset() { _ = setMuted(false) }
}

extension NSLock {
    func wscLocked<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
