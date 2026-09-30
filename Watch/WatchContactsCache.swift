import Foundation
import WatchConnectivity

@MainActor
final class WatchContactsCache: NSObject, ObservableObject {
    static let shared = WatchContactsCache()

    @Published private(set) var contacts: [LocalContactEntry] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var generation: UInt64 = 0

    private let diskCache: LocalContactSnapshotDiskCache

    override convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.init(cacheURL: root.appendingPathComponent("WiFiSecureCall/watch-contacts-v1.json"))
    }

    init(cacheURL: URL) {
        diskCache = LocalContactSnapshotDiskCache(url: cacheURL)
        super.init()
        if let snapshot = diskCache.load() {
            apply(snapshot)
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WatchWCSessionRouter.shared.activate()
    }

    nonisolated func didReceive(_ file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL), let snapshot = try? JSONDecoder().decode(LocalContactSnapshot.self, from: data), snapshot.isValid else { return }
        Task { @MainActor in
            guard snapshot.generation > self.generation else { return }
            self.persistAndApply(snapshot)
        }
    }

    nonisolated func didReceiveApplicationContext(_ applicationContext: [String : Any]) {
        let source = (applicationContext["contacts"] as? [String: Any]) ?? applicationContext
        let formatVersion = (source["formatVersion"] as? NSNumber)?.intValue
            ?? source["formatVersion"] as? Int
        let generation = (source["generation"] as? NSNumber)?.uint64Value
            ?? source["generation"] as? UInt64
        guard formatVersion == LocalContactSnapshot.formatVersion,
              let generation,
              let kind = source["contactsKind"] as? String else { return }
        Task { @MainActor in
            guard generation >= self.generation else { return }
            if kind == "cleared" { self.clear(generation: generation) }
            else if kind != "available" { return }
        }
    }

    private func persistAndApply(_ snapshot: LocalContactSnapshot) {
        guard diskCache.storeIfNewer(snapshot) else { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: LocalContactSnapshot) {
        contacts = snapshot.contacts
        generation = snapshot.generation
        updatedAt = snapshot.updatedAt
    }

    private func clear(generation: UInt64) {
        persistAndApply(LocalContactSnapshot(generation: generation, contacts: []))
    }
}
