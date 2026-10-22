import AVFoundation
import XCTest

/// Guards the numbers in `Docs/CallArchitecture.md`.
///
/// These are not arbitrary constants: the media format, the packet header, the
/// jitter window and the reconnect schedule were tuned on physical devices, and a
/// silent change to any of them is a different call engine with the same name.
/// A test fails at build time, where a comment would only be read after it is
/// already too late.
final class CallArchitectureInvariantTests: XCTestCase {
    func testNetworkAudioFormatIsTheDocumentedOne() {
        XCTAssertEqual(AudioEngine.networkSampleRate, 16_000, "network sample rate changed")
        XCTAssertEqual(AudioEngine.samplesPerFrame, 320, "samples per frame changed")
        XCTAssertEqual(AudioEngine.bytesPerFrame, 640, "payload bytes changed")

        // 320 samples at 16 kHz is exactly 20 ms, which is what the playout timer
        // and the jitter window are expressed in.
        let milliseconds = Double(AudioEngine.samplesPerFrame) / AudioEngine.networkSampleRate * 1_000
        XCTAssertEqual(milliseconds, 20, accuracy: 0.001, "a frame is no longer 20 ms")
    }

    func testPacketHeaderIsThirtyFourBytes() {
        XCTAssertEqual(AudioPacket.headerSize, 34, "the wire header changed")
        XCTAssertEqual(AudioPacket.version, 1, "the wire version changed")

        // An encoded packet must be header plus payload and nothing else.
        let packet = AudioPacket(
            type: .audio,
            callID: UUID(),
            sequence: 7,
            timestampMicroseconds: 140_000,
            payload: Data(repeating: 0, count: AudioEngine.bytesPerFrame)
        )
        XCTAssertEqual(packet.encode().count, AudioPacket.headerSize + AudioEngine.bytesPerFrame)
        XCTAssertEqual(AudioPacket.decode(packet.encode()), packet)
    }

    func testJitterBufferDefaultsMatchTheDocumentedWindow() {
        // The window is expressed in 20 ms frames, so 100 ms is five frames and
        // 240 ms is twelve. Filling fewer than five must not start playout.
        var jitter = JitterBuffer()
        for sequence in 0..<4 {
            jitter.insert(Self.packet(sequence: UInt64(sequence)))
        }
        XCTAssertNil(jitter.nextPayload(), "playout started before the initial window filled")

        jitter.insert(Self.packet(sequence: 4))
        XCTAssertNotNil(jitter.nextPayload(), "playout did not start once the window filled")
    }

    func testJitterBufferDropsLatePackets() {
        var jitter = JitterBuffer()
        for sequence in 0..<5 {
            jitter.insert(Self.packet(sequence: UInt64(sequence)))
        }
        _ = jitter.nextPayload()
        jitter.insert(Self.packet(sequence: 0))
        XCTAssertEqual(jitter.stats.lateDropped, 1, "a late packet was accepted")
    }

    func testReconnectScheduleStartsSmallAndCaps() {
        let schedule = ReconnectSchedule(total: 10)
        XCTAssertEqual(schedule.intervals.first ?? 0, 0.25, accuracy: 0.001, "the first retry delay changed")
        XCTAssertTrue(schedule.intervals.allSatisfy { $0 <= 2.0 }, "a retry delay exceeds the 2 s cap")
        XCTAssertLessThanOrEqual(schedule.intervals.reduce(0, +), 10.0, "the retry budget exceeds 10 s")
    }

    func testWatchConnectivityIsNotAnAudioTransport() throws {
        // A regression here would be silent: audio would appear to work while
        // actually riding the watch link, which cannot carry 32 kB/s reliably.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = ["Watch/WatchCallBridge.swift", "iOS/IOSWatchCallBridge.swift"]
        for relative in candidates {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertFalse(
                source.contains("bytesPerFrame") || source.contains("AudioPacket"),
                "\(relative) mentions audio framing; WatchConnectivity must not carry audio"
            )
        }
    }

    private static func packet(sequence: UInt64) -> AudioPacket {
        AudioPacket(
            type: .audio,
            callID: UUID(),
            sequence: sequence,
            timestampMicroseconds: sequence * 20_000,
            payload: Data(repeating: 1, count: AudioEngine.bytesPerFrame)
        )
    }
}
