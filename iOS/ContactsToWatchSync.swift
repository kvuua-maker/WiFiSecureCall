import Foundation
import WatchConnectivity

final class ContactsToWatchSync: NSObject, @unchecked Sendable {
    static let shared = ContactsToWatchSync()
    private let queue = DispatchQueue(label: "com.vkapps.wifisecurecall.contacts-sync")
    private var latestSnapshot: LocalContactSnapshot?
    private var latestClearGeneration: UInt64?

    func activate() {
        guard WCSession.isSupported() else { return }
        IOSWCSessionRouter.shared.registerContacts(
            activation: { [weak self] state, error in self?.activationDidComplete(state, error: error) },
            fileFinished: { [weak self] transfer, error in self?.didFinish(transfer, error: error) }
        )
        IOSWCSessionRouter.shared.activate()
    }

    func publish(_ snapshot: LocalContactSnapshot) {
        guard snapshot.isValid else { return }
        queue.async {
            self.latestSnapshot = snapshot
            self.latestClearGeneration = nil
            self.send(snapshot)
        }
    }

    func publishCleared(generation: UInt64) {
        queue.async {
            self.latestSnapshot = nil
            self.latestClearGeneration = generation
            self.sendContext(kind: "cleared", generation: generation, updatedAt: Date())
        }
    }

    private func send(_ snapshot: LocalContactSnapshot) {
        guard WCSession.default.activationState == .activated else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wsc-contact-snapshots", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("contacts-\(snapshot.generation).json")
            try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            WCSession.default.transferFile(url, metadata: ["formatVersion": snapshot.formatVersion, "generation": snapshot.generation])
            sendContext(kind: "available", generation: snapshot.generation, updatedAt: snapshot.updatedAt)
        } catch { return }
    }

    private func sendContext(kind: String, generation: UInt64, updatedAt: Date) {
        guard WCSession.default.activationState == .activated else { return }
        IOSWCSessionRouter.shared.updateApplicationContext(namespace: "contacts", values: [
            "contactsKind": kind, "formatVersion": LocalContactSnapshot.formatVersion,
            "generation": generation, "updatedAt": updatedAt.timeIntervalSince1970
        ])
    }

    func activationDidComplete(_ activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated, error == nil else { return }
        queue.async {
            if let snapshot = self.latestSnapshot { self.send(snapshot) }
            else if let generation = self.latestClearGeneration { self.sendContext(kind: "cleared", generation: generation, updatedAt: Date()) }
        }
    }
    func didFinish(_ fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
