import CryptoKit
import Foundation

enum EncryptedAudioError: Error, Equatable {
    case invalidFrame
    case wrongCall
    case wrongDirection
    case wrongEpoch
    case replay
    case authentication
}

final class CallAudioCryptor: @unchecked Sendable {
    private let callID: UUID
    private var keys: CallAudioKeys?
    private let lock = NSLock()
    private var receivedSequences = Set<UInt64>()
    private var erased = false

    init(callID: UUID, keys: CallAudioKeys) { self.callID = callID; self.keys = keys }

    func encrypt(_ frame: Data, sequence: UInt64, timestampMicroseconds: UInt64) throws -> AudioPacket {
        guard frame.count == AudioEngine.bytesPerFrame else { throw EncryptedAudioError.invalidFrame }
        return try lock.wscLocked {
            guard !erased, let keys else { throw EncryptedAudioError.authentication }
            let nonceData = AudioPacket.encryptedNonce(epoch: keys.epoch, sequence: sequence)
            let provisional = AudioPacket(
                encryptedType: .audio, callID: callID, direction: keys.sendDirection, keyEpoch: keys.epoch,
                sequence: sequence, timestampMicroseconds: timestampMicroseconds, nonce: nonceData,
                sealedPayload: Data(repeating: 0, count: AudioEngine.bytesPerFrame + 16)
            )
            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let box = try ChaChaPoly.seal(frame, using: keys.send, nonce: nonce, authenticating: provisional.authenticatedHeader)
            return AudioPacket(
                encryptedType: .audio, callID: callID, direction: keys.sendDirection, keyEpoch: keys.epoch,
                sequence: sequence, timestampMicroseconds: timestampMicroseconds, nonce: nonceData,
                sealedPayload: box.ciphertext + box.tag
            )
        }
    }

    func decrypt(_ packet: AudioPacket) throws -> AudioPacket {
        try lock.wscLocked {
            guard !erased, let keys else { throw EncryptedAudioError.authentication }
            guard packet.protocolVersion == AudioPacket.encryptedVersion, packet.callID == callID else { throw EncryptedAudioError.wrongCall }
            guard packet.direction == keys.receiveDirection else { throw EncryptedAudioError.wrongDirection }
            guard packet.keyEpoch == keys.epoch else { throw EncryptedAudioError.wrongEpoch }
            guard !receivedSequences.contains(packet.sequence) else { throw EncryptedAudioError.replay }
            guard packet.payload.count == AudioEngine.bytesPerFrame + 16 else { throw EncryptedAudioError.invalidFrame }
            do {
                let nonce = try ChaChaPoly.Nonce(data: packet.nonce)
                let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: packet.payload.dropLast(16), tag: packet.payload.suffix(16))
                let plaintext = try ChaChaPoly.open(box, using: keys.receive, authenticating: packet.authenticatedHeader)
                guard plaintext.count == AudioEngine.bytesPerFrame else { throw EncryptedAudioError.invalidFrame }
                receivedSequences.insert(packet.sequence)
                if receivedSequences.count > 2_048, let floor = receivedSequences.max().map({ $0 > 1_024 ? $0 - 1_024 : 0 }) {
                    receivedSequences = receivedSequences.filter { $0 >= floor }
                }
                return AudioPacket(type: .audio, callID: packet.callID, sequence: packet.sequence, timestampMicroseconds: packet.timestampMicroseconds, payload: plaintext)
            } catch let error as EncryptedAudioError {
                throw error
            } catch {
                throw EncryptedAudioError.authentication
            }
        }
    }

    func erase() {
        lock.wscLocked {
            receivedSequences.removeAll(keepingCapacity: false)
            keys = nil
            erased = true
        }
    }
}
