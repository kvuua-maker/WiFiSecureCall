import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The UDP socket that carries RTP for one call.
///
/// A BSD socket is used instead of a higher-level API because the SDP offer has
/// to name the exact port the media will leave from. The socket is bound first,
/// then connected to the far end once the answer arrives, so the port in the
/// offer is the port that is actually used.
final class RTPMediaSession: @unchecked Sendable {
    struct Endpoint: Sendable, Equatable {
        let address: String
        let port: Int
    }

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var jitter: RTPJitterBuffer
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var payloadType: UInt8
    private(set) var localEndpoint: Endpoint?

    /// Called for every decoded media frame, in playback order.
    var onFrame: (@Sendable (Data) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?

    init(payloadType: UInt8 = SIPCodec.pcmu.rawValue) {
        self.payloadType = payloadType
        self.jitter = RTPJitterBuffer(silenceByte: payloadType == SIPCodec.pcma.rawValue ? 0xD5 : 0xFF)
    }

    deinit {
        close()
    }

    /// Binds a socket and works out which local address the OS would use to reach
    /// `probeHost`. The address is what goes into SDP; the port is what the peer
    /// will send to.
    func open(probeHost: String, probePort: UInt16) throws -> Endpoint {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw RTPError.socket(errno) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw RTPError.socket(code)
        }

        // Probe the route so getsockname reports the interface address, then keep
        // the socket unconnected until the far end is known.
        connect(fd, probeHost, probePort)

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            Darwin.close(fd)
            throw RTPError.socket(code)
        }

        let address = Self.ipv4String(assigned.sin_addr)
        let port = Int(UInt16(bigEndian: assigned.sin_port))
        guard !address.isEmpty, port > 0 else {
            Darwin.close(fd)
            throw RTPError.noLocalAddress
        }

        lock.lock()
        descriptor = fd
        localEndpoint = Endpoint(address: address, port: port)
        lock.unlock()

        startReadSource(fd)
        onDiagnostic?("rtp_socket_open address=\(address) port=\(port)")
        return Endpoint(address: address, port: port)
    }

    /// Points the socket at the peer's media address from the negotiated SDP.
    func connect(to endpoint: Endpoint) {
        lock.lock()
        let fd = descriptor
        lock.unlock()
        guard fd >= 0 else { return }
        guard connect(fd, endpoint.address, UInt16(clamping: endpoint.port)) != 0 else {
            onDiagnostic?("rtp_connected remote=\(endpoint.address):\(endpoint.port)")
            return
        }
        onDiagnostic?("rtp_connect_failed remote=\(endpoint.address):\(endpoint.port)")
    }

    func updatePayloadType(_ type: UInt8) {
        payloadType = type
    }

    /// Sends one 20 ms frame.
    func send(payload: Data) {
        lock.lock()
        let fd = descriptor
        lock.unlock()
        guard fd >= 0, !payload.isEmpty else { return }
        let packet = RTPPacket(
            payloadType: payloadType,
            sequence: sequence,
            timestamp: timestamp,
            ssrc: ssrc,
            marker: sequence == 0,
            payload: payload
        )
        sequence = sequence &+ 1
        timestamp = timestamp &+ UInt32(SIPConfiguration.samplesPerFrame)
        let data = packet.encode()
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.send(fd, base, buffer.count, 0)
        }
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        let source = readSource
        readSource = nil
        jitter.reset()
        lock.unlock()
        source?.setEventHandler {}
        source?.cancel()
        if fd >= 0 { Darwin.close(fd) }
    }

    // MARK: - Reading

    private func startReadSource(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "com.vkapps.wifisecurecall.rtp.read", qos: .userInteractive))
        source.setEventHandler { [weak self] in
            self?.drain(fd: fd)
        }
        source.setCancelHandler { }
        source.resume()
        lock.lock()
        readSource = source
        lock.unlock()
    }

    private func drain(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(fd, base, raw.count, Int32(MSG_DONTWAIT))
            }
            if count <= 0 { return }
            guard let packet = RTPPacket.decode(Data(buffer[0..<count])) else { continue }
            guard packet.payloadType == payloadType else { continue }
            let inserted = withLockedJitter { $0.insert(sequence: packet.sequence, payload: packet.payload) }
            if !inserted { continue }
            while let frame = withLockedJitter({ $0.next() }) {
                onFrame?(frame)
            }
        }
    }

    private func withLockedJitter<T>(_ body: (inout RTPJitterBuffer) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&jitter)
    }

    // MARK: - Helpers

    @discardableResult
    private func connect(_ fd: Int32, _ host: String, _ port: UInt16) -> Int32 {
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return -1 }
        return withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func ipv4String(_ address: in_addr) -> String {
        var value = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: buffer)
    }
}

enum RTPError: Error, Equatable {
    case socket(Int32)
    case noLocalAddress
}
