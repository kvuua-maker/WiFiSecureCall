import Foundation
import WatchConnectivity

@MainActor
final class WatchContactsCache: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchContactsCache()

    @Published private(set) var contacts: [LocalContactEntry] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var generation: UInt64 = 0

    private let cacheURL: URL

    override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        cacheURL = root.appendingPathComponent("WiFiSecureCall/watch-contacts-v1.json")
        super.init()
        if let data = try? Data(contentsOf: cacheURL), let snapshot = try? JSONDecoder().decode(LocalContactSnapshot.self, from: data), snapshot.isValid {
            apply(snapshot)
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL), let snapshot = try? JSONDecoder().decode(LocalContactSnapshot.self, from: data), snapshot.isValid else { return }
        Task { @MainActor in
            guard snapshot.generation > self.generation else { return }
            self.persistAndApply(snapshot)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        let formatVersion = (applicationContext["formatVersion"] as? NSNumber)?.intValue
            ?? applicationContext["formatVersion"] as? Int
        let generation = (applicationContext["generation"] as? NSNumber)?.uint64Value
            ?? applicationContext["generation"] as? UInt64
        guard formatVersion == LocalContactSnapshot.formatVersion,
              let generation,
              let kind = applicationContext["contactsKind"] as? String else { return }
        Task { @MainActor in
            guard generation >= self.generation else { return }
            if kind == "cleared" { self.clear(generation: generation) }
            else if kind != "available" { return }
        }
    }

    private func persistAndApply(_ snapshot: LocalContactSnapshot) {
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            apply(snapshot)
        } catch { return }
    }

    private func apply(_ snapshot: LocalContactSnapshot) {
        contacts = snapshot.contacts
        generation = snapshot.generation
        updatedAt = snapshot.updatedAt
    }

    private func clear(generation: UInt64) {
        contacts = []
        updatedAt = nil
        self.generation = generation
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
