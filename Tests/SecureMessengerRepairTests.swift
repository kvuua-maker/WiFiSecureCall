import Foundation
import XCTest

private final class RepairMemorySecretStorage: E2EESecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func load(_ key: String) throws -> Data? { lock.wscLocked { values[key] } }
    func save(_ data: Data, key: String) throws { lock.wscLocked { values[key] = data } }
}

private final class RepairMemoryTokenStore: SecureTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: AccountTokens] = [:]
    func tokens(for accountID: UUID) throws -> AccountTokens? { lock.wscLocked { values[accountID] } }
    func save(_ tokens: AccountTokens, for accountID: UUID) throws { lock.wscLocked { values[accountID] = tokens } }
    func delete(accountID: UUID) throws { lock.wscLocked { values[accountID] = nil } }
    func deleteIfRefreshTokenMatches(accountID: UUID, refreshToken: String) throws -> Bool {
        lock.wscLocked {
            guard values[accountID]?.refreshToken == refreshToken else { return false }
            values[accountID] = nil
            return true
        }
    }
}

private final class RepairMessageURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class CallHistoryMemoryPersistence: CallHistoryPersisting {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

private struct LegacyCallHistoryRecord: Codable {
    let id: UUID
    let direction: CallHistoryDirection
    let peerDisplayName: String
    let startedAt: Date
    let terminalAt: Date?
    let status: CallHistoryStatus
    let deduplicationToken: String?
}

private actor RepairAsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let values = waiters
        waiters.removeAll()
        values.forEach { $0.resume() }
    }
}

@MainActor
private final class RepairNotificationRecorder {
    var loads: [(UUID, UUID)] = []
    var routes: [(UUID, UUID)] = []
    var loaderObservedCancellation = false
}

@MainActor
final class SecureMessengerCallHistoryRepairTests: XCTestCase {
    func testVerifiedOutgoingTargetSurvivesRestartButLegacyRecordNeverInventsTarget() throws {
        let persistence = CallHistoryMemoryPersistence()
        let accountID = UUID(), peerID = UUID()
        let store = CallHistoryStore(persistence: persistence)
        let recordID = store.begin(accountID: accountID, logicalCallID: UUID(), direction: .outgoing,
                                   peerDisplayName: "@peer", targetUserID: peerID)
        store.finish(recordID, status: .answered)
        XCTAssertEqual(CallHistoryStore(persistence: persistence).records.first?.targetUserID, peerID)

        let legacy = LegacyCallHistoryRecord(id: UUID(), direction: .incoming, peerDisplayName: "@old",
                                            startedAt: Date(), terminalAt: Date(), status: .missed,
                                            deduplicationToken: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        persistence.data = try encoder.encode([legacy])
        XCTAssertNil(CallHistoryStore(persistence: persistence).records.first?.targetUserID)
    }

    func testLifecycleUpdatesOneRecordExactlyOnce() throws {
        let persistence = CallHistoryMemoryPersistence()
        let store = CallHistoryStore(persistence: persistence, retentionLimit: 10)
        let accountID = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let logicalCallID = UUID()
        let id = store.begin(accountID: accountID, logicalCallID: logicalCallID, direction: .outgoing, peerDisplayName: "@peer", at: start)
        XCTAssertEqual(store.begin(accountID: accountID, logicalCallID: logicalCallID, direction: .outgoing, peerDisplayName: "@peer", at: start), id)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.status, .ringing)
        store.markActive(id)
        XCTAssertEqual(store.records.first?.status, .active)
        let terminal = Date(timeIntervalSince1970: 1_100)
        store.finish(id, status: .failed, at: terminal)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.status, .answered)
        XCTAssertEqual(store.records.first?.terminalAt, terminal)
        store.finish(id, status: .missed, at: Date(timeIntervalSince1970: 1_200))
        XCTAssertEqual(store.records.first?.status, .answered)
        XCTAssertEqual(store.records.first?.terminalAt, terminal)

        let relaunched = CallHistoryStore(persistence: persistence, retentionLimit: 10)
        XCTAssertEqual(
            relaunched.begin(accountID: accountID, logicalCallID: logicalCallID, direction: .outgoing, peerDisplayName: "@peer"),
            id
        )
        XCTAssertEqual(relaunched.records.count, 1)
    }

    func testPersistenceNewestFirstAndBoundedRetention() throws {
        let persistence = CallHistoryMemoryPersistence()
        let store = CallHistoryStore(persistence: persistence, retentionLimit: 3)
        let accountID = UUID()
        for offset in 0..<5 {
            let id = store.begin(
                accountID: accountID,
                logicalCallID: UUID(), direction: offset.isMultiple(of: 2) ? .incoming : .outgoing,
                peerDisplayName: "@peer\(offset)",
                at: Date(timeIntervalSince1970: TimeInterval(offset))
            )
            store.finish(id, status: .missed, at: Date(timeIntervalSince1970: TimeInterval(offset + 10)))
        }
        XCTAssertEqual(store.records.map(\.peerDisplayName), ["@peer4", "@peer3", "@peer2"])
        let reloaded = CallHistoryStore(persistence: persistence, retentionLimit: 3)
        XCTAssertEqual(reloaded.records, store.records)
    }

    func testInterruptedLiveHistoryIsRecoveredAsStaticTerminalState() {
        let persistence = CallHistoryMemoryPersistence()
        let store = CallHistoryStore(persistence: persistence, retentionLimit: 10)
        let accountID = UUID()
        let incoming = store.begin(accountID: accountID, logicalCallID: UUID(), direction: .incoming, peerDisplayName: "@incoming")
        let active = store.begin(accountID: accountID, logicalCallID: UUID(), direction: .outgoing, peerDisplayName: "@active")
        store.markActive(active)
        XCTAssertEqual(store.records.first(where: { $0.id == incoming })?.status, .ringing)
        let recovered = CallHistoryStore(persistence: persistence, retentionLimit: 10)
        XCTAssertEqual(recovered.records.first(where: { $0.id == incoming })?.status, .missed)
        XCTAssertEqual(recovered.records.first(where: { $0.id == active })?.status, .failed)
        XCTAssertTrue(recovered.records.allSatisfy { $0.status.isTerminal && $0.terminalAt != nil })
    }

    func testHistoryRejectsPhoneLikeDisplayAndPersistsNoSensitiveCallMaterial() throws {
        let persistence = CallHistoryMemoryPersistence()
        let store = CallHistoryStore(persistence: persistence)
        let accountID = UUID()
        let logicalCallID = UUID()
        _ = store.begin(accountID: accountID, logicalCallID: logicalCallID, direction: .incoming, peerDisplayName: "+380501234567")
        XCTAssertEqual(store.records.first?.peerDisplayName, "Secure contact")
        let encoded = try XCTUnwrap(persistence.data)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("+380501234567"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains(logicalCallID.uuidString))
        let mixed = store.begin(accountID: accountID, logicalCallID: UUID(), direction: .outgoing, peerDisplayName: "Alice +380501234567")
        XCTAssertEqual(store.records.first(where: { $0.id == mixed })?.peerDisplayName, "Secure contact")
        for forbidden in ["mediaToken", "APNs", "ciphertext", "privateKey", "audio"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHistoryIsAccountScopedAcrossPersistenceAndLegacyRecordsRemainHidden() throws {
        let persistence = CallHistoryMemoryPersistence()
        let store = CallHistoryStore(persistence: persistence, retentionLimit: 10)
        let accountA = UUID(), accountB = UUID(), sharedLogicalCallID = UUID()
        let recordA = store.begin(
            accountID: accountA, logicalCallID: sharedLogicalCallID,
            direction: .outgoing, peerDisplayName: "@account-a"
        )
        let recordB = store.begin(
            accountID: accountB, logicalCallID: sharedLogicalCallID,
            direction: .incoming, peerDisplayName: "@account-b"
        )
        XCTAssertNotEqual(recordA, recordB)
        XCTAssertEqual(store.records(for: accountA).map(\.peerDisplayName), ["@account-a"])
        XCTAssertEqual(store.records(for: accountB).map(\.peerDisplayName), ["@account-b"])
        XCTAssertTrue(store.records(for: nil).isEmpty)

        let reloaded = CallHistoryStore(persistence: persistence, retentionLimit: 10)
        XCTAssertEqual(reloaded.records(for: accountA).map(\.peerDisplayName), ["@account-a"])
        XCTAssertEqual(reloaded.records(for: accountB).map(\.peerDisplayName), ["@account-b"])

        let legacy = LegacyCallHistoryRecord(
            id: UUID(), direction: .incoming, peerDisplayName: "@legacy",
            startedAt: Date(timeIntervalSince1970: 100), terminalAt: Date(timeIntervalSince1970: 110),
            status: .missed, deduplicationToken: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        persistence.data = try encoder.encode([legacy])
        let migrated = CallHistoryStore(persistence: persistence, retentionLimit: 10)
        XCTAssertEqual(migrated.records.count, 1)
        XCTAssertNil(migrated.records.first?.accountID)
        XCTAssertTrue(migrated.records(for: accountA).isEmpty)
        XCTAssertTrue(migrated.records(for: accountB).isEmpty)
    }
}

final class SecureConversationPeerMetadataTests: XCTestCase {
    func testContactSnapshotIsMinimalValidatedAndInternationalOnly() throws {
        XCTAssertEqual(LocalPhoneNumberNormalizer.normalize("+380 (50) 123-45-67"), "+380501234567")
        XCTAssertNil(LocalPhoneNumberNormalizer.normalize("0501234567"))
        let entry = LocalContactEntry(id: "local-id", name: "Олена", normalizedNumbers: ["+380501234567"])
        let snapshot = LocalContactSnapshot(generation: 4, updatedAt: Date(timeIntervalSince1970: 100), contacts: [entry])
        XCTAssertTrue(snapshot.isValid)
        let encoded = try JSONEncoder().encode(snapshot)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["token", "message", "note", "email", "address"] { XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden)) }
        XCTAssertEqual(try JSONDecoder().decode(LocalContactSnapshot.self, from: encoded), snapshot)
    }

    func testContactGenerationSurvivesIPhoneRestartAndPermissionClearAdvancesIt() throws {
        let suite = "LocalContactGeneration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstLaunch = LocalContactGenerationStore(defaults: defaults)
        XCTAssertEqual(firstLaunch.next(), 1)
        XCTAssertEqual(firstLaunch.next(), 2)
        let restarted = LocalContactGenerationStore(defaults: defaults)
        XCTAssertEqual(restarted.current, 2)
        XCTAssertEqual(restarted.next(), 3, "permission revocation/read failure must publish a newer tombstone")
    }

    func testWatchRestartRetainsClearTombstoneAndRejectsDelayedOldFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-contact-cache-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snapshot.json")
        let contact = LocalContactEntry(id: "one", name: "Олена", normalizedNumbers: ["+380501234567"])
        let first = LocalContactSnapshot(generation: 8, updatedAt: Date(timeIntervalSince1970: 80), contacts: [contact])
        let cleared = LocalContactSnapshot(generation: 9, updatedAt: Date(timeIntervalSince1970: 90), contacts: [])
        let cache = LocalContactSnapshotDiskCache(url: url)
        XCTAssertTrue(cache.storeIfNewer(first))
        XCTAssertTrue(cache.storeIfNewer(cleared))
        let restarted = LocalContactSnapshotDiskCache(url: url)
        XCTAssertEqual(restarted.load(), cleared)
        XCTAssertFalse(restarted.storeIfNewer(first), "delayed pre-revocation file restored contacts")
        XCTAssertEqual(restarted.load(), cleared)
    }

    func testInternationalNumberNormalizationDoesNotGuessCountryOrChangeUsername() {
        XCTAssertEqual(RecipientQueryNormalization.normalize(" +380 (50) 123-45-67 "), "+380501234567")
        XCTAssertEqual(RecipientQueryNormalization.normalize("0501234567"), "0501234567")
        XCTAssertEqual(RecipientQueryNormalization.normalize("@friend"), "@friend")
    }

    func testPeerIdentityIsOptionalForOldConversationResponses() throws {
        let conversation = SecureConversation(conversationID: UUID(), participants: [UUID(), UUID()],
                                              createdAt: Date(), updatedAt: Date())
        let legacy = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(SecureConversation.self, from: legacy)
        XCTAssertNil(decoded.peer)
        XCTAssertEqual(decoded.peerDisplayName, "Адресат недоступний")
    }

    func testAuthenticatedPeerMetadataNamesConversationWithoutUsingPhoneNumber() throws {
        let peer = ResolvedRecipient(userID: UUID(), username: "peer", displayName: "Олена",
                                     publicIdentity: "wsc:user:peer", phoneNumber: nil)
        let conversation = SecureConversation(conversationID: UUID(), participants: [UUID(), peer.userID],
                                              createdAt: Date(), updatedAt: Date(), peer: peer)
        let decoded = try JSONDecoder().decode(SecureConversation.self,
                                               from: JSONEncoder().encode(conversation))
        XCTAssertEqual(decoded.peerDisplayName, "Олена")
        XCTAssertEqual(decoded.peer?.userID, peer.userID)
        XCTAssertNil(decoded.peer?.phoneNumber)
    }
}

final class SecureMessengerRecordRepairTests: XCTestCase {
    func testCachedPlaintextKeepsContentButRefreshesAuthoritativeReceiptState() {
        let messageID = UUID(), conversationID = UUID(), senderID = UUID(), now = Date()
        let cached = DecryptedMessage(
            id: messageID, conversationID: conversationID, senderUserID: senderID,
            text: "locally decrypted", createdAt: now, isSentByCurrentUser: true,
            delivered: false, read: false
        )
        let record = SecureMessageRecord(
            messageID: messageID, conversationID: conversationID, clientMessageID: UUID(),
            senderUserID: senderID, senderDeviceID: UUID(), recipientUserID: UUID(),
            createdAt: now, protocolVersion: 1, keyVersion: 1,
            nonce: "opaque", ciphertext: "opaque", tag: "opaque", envelopes: [], signature: "opaque",
            receipts: [.init(deviceID: UUID(), deliveredAt: now, readAt: now)]
        )
        let merged = SecureMessageStore.mergingReceiptState(cached: cached, record: record)
        XCTAssertEqual(merged.text, cached.text)
        XCTAssertTrue(merged.delivered)
        XCTAssertTrue(merged.read)
        XCTAssertEqual(merged.availability, cached.availability)

        let staleRecord = SecureMessageRecord(
            messageID: messageID, conversationID: conversationID, clientMessageID: UUID(),
            senderUserID: senderID, senderDeviceID: UUID(), recipientUserID: UUID(),
            createdAt: now, protocolVersion: 1, keyVersion: 1,
            nonce: "opaque", ciphertext: "opaque", tag: "opaque", envelopes: [], signature: "opaque",
            receipts: []
        )
        let staleMerge = SecureMessageStore.mergingReceiptState(cached: merged, record: staleRecord)
        XCTAssertTrue(staleMerge.delivered)
        XCTAssertTrue(staleMerge.read)
    }

    func testMixedPageKeepsValidMessagesAndUsesSafePerRecordPlaceholders() throws {
        let senderUserID = UUID(), recipientUserID = UUID(), conversationID = UUID()
        let sender = E2EEDeviceIdentity(deviceID: UUID(), signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 1)
        let recipient = E2EEDeviceIdentity(deviceID: UUID(), signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 1)
        let anotherDevice = E2EEDeviceIdentity(deviceID: UUID(), signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 1)

        func record(_ text: String, recipientDevices: [E2EEPublicDeviceBundle], at seconds: TimeInterval) throws -> SecureMessageRecord {
            let input = try SecureMessageCrypto.encrypt(
                text: text,
                conversationID: conversationID,
                senderUserID: senderUserID,
                identity: sender,
                recipientDevices: recipientDevices,
                senderOtherDevices: []
            )
            return .init(
                messageID: input.messageID,
                conversationID: conversationID,
                clientMessageID: input.clientMessageID,
                senderUserID: senderUserID,
                senderDeviceID: sender.deviceID,
                recipientUserID: recipientUserID,
                createdAt: Date(timeIntervalSince1970: seconds),
                protocolVersion: input.protocolVersion,
                keyVersion: input.keyVersion,
                nonce: input.nonce,
                ciphertext: input.ciphertext,
                tag: input.tag,
                envelopes: input.envelopes,
                signature: input.signature,
                receipts: []
            )
        }

        let first = try record("valid one", recipientDevices: [recipient.publicBundle], at: 1)
        let missing = try record("must stay hidden", recipientDevices: [anotherDevice.publicBundle], at: 2)
        let signed = try record("must not be forged", recipientDevices: [recipient.publicBundle], at: 3)
        let tampered = SecureMessageRecord(
            messageID: signed.messageID, conversationID: signed.conversationID,
            clientMessageID: signed.clientMessageID, senderUserID: signed.senderUserID,
            senderDeviceID: signed.senderDeviceID, recipientUserID: signed.recipientUserID,
            createdAt: signed.createdAt, protocolVersion: signed.protocolVersion,
            keyVersion: signed.keyVersion, nonce: signed.nonce,
            ciphertext: Data("tampered".utf8).base64EncodedString(), tag: signed.tag,
            envelopes: signed.envelopes, signature: signed.signature, receipts: []
        )
        let last = try record("valid two", recipientDevices: [recipient.publicBundle], at: 4)

        let decoded = [first, missing, tampered, last].map {
            SecureMessageStore.materialize(
                $0, currentUserID: recipientUserID, identity: recipient,
                senderIdentity: sender.publicBundle, trust: .unchanged
            )
        }
        XCTAssertEqual(decoded.map(\.availability), [.available, .unavailableOnDevice, .securityFailure, .available])
        XCTAssertEqual(decoded.map(\.text), [
            "valid one", "Message unavailable on this device",
            "Secure message could not be verified", "valid two"
        ])
        XCTAssertFalse(decoded[1].text.contains("must stay hidden"))
        XCTAssertFalse(decoded[2].text.contains(tampered.ciphertext))
    }

    func testKeyChangedIsFailClosedUntilExplicitAccountScopedApproval() throws {
        let store = RepairMemorySecretStorage()
        let pins = E2EEIdentityPinStore(storage: store)
        let accountA = UUID(), accountB = UUID(), userID = UUID(), deviceID = UUID()
        let original = E2EEDeviceIdentity(deviceID: deviceID, signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 1).publicBundle
        let changed = E2EEDeviceIdentity(deviceID: deviceID, signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 2).publicBundle

        XCTAssertEqual(try pins.evaluate(userID: userID, bundle: original, accountID: accountA), .firstTrusted)
        XCTAssertEqual(try pins.evaluate(userID: userID, bundle: changed, accountID: accountA), .keyChanged)
        XCTAssertEqual(try pins.pinnedBundle(userID: userID, deviceID: deviceID, accountID: accountA), original)

        // Cancel is intentionally no mutation: the old pin remains authoritative.
        XCTAssertEqual(try pins.evaluate(userID: userID, bundle: changed, accountID: accountA), .keyChanged)
        XCTAssertEqual(try pins.evaluate(userID: userID, bundle: changed, accountID: accountB), .firstTrusted)
        XCTAssertEqual(try pins.pinnedBundle(userID: userID, deviceID: deviceID, accountID: accountA), original)

        try pins.approveReplacement(userID: userID, bundle: changed, accountID: accountA)
        XCTAssertEqual(try pins.evaluate(userID: userID, bundle: changed, accountID: accountA), .unchanged)
        XCTAssertEqual(try pins.evaluate(userID: userID, bundle: original, accountID: accountA), .keyChanged)
        XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
    }

    func testConcurrentFirstObservationPinsExactlyOneIdentity() async throws {
        let storage = RepairMemorySecretStorage()
        let firstPins = E2EEIdentityPinStore(storage: storage)
        let secondPins = E2EEIdentityPinStore(storage: storage)
        let accountID = UUID(), userID = UUID(), deviceID = UUID()
        let first = E2EEDeviceIdentity(
            deviceID: deviceID, signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 1
        ).publicBundle
        let second = E2EEDeviceIdentity(
            deviceID: deviceID, signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 2
        ).publicBundle

        let results = try await withThrowingTaskGroup(of: E2EETrustState.self) { group in
            group.addTask { try firstPins.evaluate(userID: userID, bundle: first, accountID: accountID) }
            group.addTask { try secondPins.evaluate(userID: userID, bundle: second, accountID: accountID) }
            var values: [E2EETrustState] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(results.filter { $0 == .firstTrusted }.count, 1)
        XCTAssertEqual(results.filter { $0 == .keyChanged }.count, 1)
        let pinned = try XCTUnwrap(firstPins.pinnedBundle(userID: userID, deviceID: deviceID, accountID: accountID))
        XCTAssertTrue(pinned == first || pinned == second)
    }

    func testKeyChangedRecordNeverDisplaysPlaintext() throws {
        let senderUserID = UUID(), recipientUserID = UUID(), conversationID = UUID()
        let sender = E2EEDeviceIdentity(deviceID: UUID(), signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 1)
        let recipient = E2EEDeviceIdentity(deviceID: UUID(), signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 1)
        let input = try SecureMessageCrypto.encrypt(
            text: "hidden after identity change", conversationID: conversationID,
            senderUserID: senderUserID, identity: sender,
            recipientDevices: [recipient.publicBundle], senderOtherDevices: []
        )
        let record = SecureMessageRecord(
            messageID: input.messageID, conversationID: conversationID,
            clientMessageID: input.clientMessageID, senderUserID: senderUserID,
            senderDeviceID: sender.deviceID, recipientUserID: recipientUserID,
            createdAt: Date(), protocolVersion: input.protocolVersion,
            keyVersion: input.keyVersion, nonce: input.nonce,
            ciphertext: input.ciphertext, tag: input.tag, envelopes: input.envelopes,
            signature: input.signature, receipts: []
        )
        let decoded = SecureMessageStore.materialize(
            record, currentUserID: recipientUserID, identity: recipient,
            senderIdentity: sender.publicBundle, trust: .keyChanged
        )
        XCTAssertEqual(decoded.availability, .securityFailure)
        XCTAssertEqual(decoded.text, "Secure message could not be verified")
    }
}

@MainActor
final class SecureMessengerAccountIsolationRepairTests: XCTestCase {
    func testNonActiveNotificationRefreshCannotReplaceVisibleAccountState() async throws {
        let accountA = UUID(), accountB = UUID(), userA = UUID(), userB = UUID()
        let sharedConversationID = UUID()
        let conversationA = SecureConversation(
            conversationID: sharedConversationID, participants: [userA, UUID()], createdAt: Date(), updatedAt: Date()
        )
        let conversationB = SecureConversation(
            conversationID: sharedConversationID, participants: [userB, UUID()], createdAt: Date(), updatedAt: Date()
        )
        let identityStorage = RepairMemorySecretStorage()
        let identity = E2EEIdentityStore(storage: identityStorage, deviceID: UUID())
        let publicBundle = try identity.identity().publicBundle
        let tokenStore = RepairMemoryTokenStore()
        let defaultsName = "SecureMessengerAccountIsolationRepairTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            RepairMessageURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let sessions = AccountSessionStore(tokenStore: tokenStore, defaults: defaults)
        let tokensA = AccountTokens(
            accessToken: "access-a", accessExpiresAt: .distantFuture,
            refreshToken: "refresh-a", refreshExpiresAt: .distantFuture
        )
        let tokensB = AccountTokens(
            accessToken: "access-b", accessExpiresAt: .distantFuture,
            refreshToken: "refresh-b", refreshExpiresAt: .distantFuture
        )
        let profileA = UserProfile(
            userID: userA, username: "account-a", displayName: "Account A", email: nil,
            verifiedPhones: [], publicIdentity: "wsc:user:account-a"
        )
        let profileB = UserProfile(
            userID: userB, username: "account-b", displayName: "Account B", email: nil,
            verifiedPhones: [], publicIdentity: "wsc:user:account-b"
        )
        try sessions.add(.init(
            account: .init(accountID: accountA, userID: userA, phoneNumber: nil, displayLabel: "Account A"),
            deviceID: publicBundle.deviceID, accessToken: tokensA.accessToken,
            accessExpiresAt: tokensA.accessExpiresAt, refreshToken: tokensA.refreshToken,
            refreshExpiresAt: tokensA.refreshExpiresAt, user: profileA
        ))
        try sessions.add(.init(
            account: .init(accountID: accountB, userID: userB, phoneNumber: nil, displayLabel: "Account B"),
            deviceID: publicBundle.deviceID, accessToken: tokensB.accessToken,
            accessExpiresAt: tokensB.accessExpiresAt, refreshToken: tokensB.refreshToken,
            refreshExpiresAt: tokensB.refreshExpiresAt, user: profileB
        ))

        RepairMessageURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            let isA = authorization == "Bearer access-a"
            let path = request.url?.path ?? ""
            let body: Data
            if path.hasSuffix("/device-keys") {
                body = try JSONEncoder.account.encode(publicBundle)
            } else if path.hasSuffix("/conversations") {
                body = try JSONEncoder.account.encode(isA ? [conversationA] : [conversationB])
            } else if path.hasSuffix("/messages") {
                body = try JSONEncoder.account.encode(SecureMessagePage(messages: [], nextCursor: nil))
            } else if path.hasSuffix("/me") {
                body = try JSONEncoder.account.encode(isA ? profileA : profileB)
            } else {
                throw URLError(.badURL)
            }
            return (200, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RepairMessageURLProtocol.self]
        let config = AppConfig(
            apiBaseURL: URL(string: "https://example.invalid/wifi-secure-call/v1")!,
            mediaURL: URL(string: "wss://example.invalid/media")!,
            role: .B,
            bearerToken: String(repeating: "b", count: 64)
        )
        let accountAPI = AccountAPIClient(
            config: config, tokenStore: tokenStore, session: URLSession(configuration: configuration),
            deviceID: publicBundle.deviceID, platform: "iOS"
        )
        let messageStore = SecureMessageStore(
            sessions: sessions,
            accountAPI: accountAPI,
            identityStore: identity,
            pinStore: E2EEIdentityPinStore(storage: RepairMemorySecretStorage())
        )

        XCTAssertEqual(sessions.activeAccountID, accountB)
        let refreshedA = await messageStore.refresh(accountID: accountA)
        let refreshedB = await messageStore.refresh(accountID: accountB)
        XCTAssertTrue(refreshedA)
        XCTAssertTrue(refreshedB)
        XCTAssertEqual(messageStore.conversations.map(\.id), [conversationB.id])
        XCTAssertEqual(messageStore.conversations.first?.participants, conversationB.participants)

        let prepared = await messageStore.prepareNotificationConversation(
            conversationID: conversationA.id,
            accountID: accountA
        )
        XCTAssertTrue(prepared)
        XCTAssertEqual(sessions.activeAccountID, accountB)
        XCTAssertEqual(messageStore.conversations.map(\.id), [conversationB.id])
        XCTAssertEqual(messageStore.conversations.first?.participants, conversationB.participants)

        sessions.switchAccount(to: accountA)
        XCTAssertEqual(messageStore.conversations.map(\.id), [conversationA.id])
        XCTAssertEqual(messageStore.conversations.first?.participants, conversationA.participants)
        sessions.switchAccount(to: accountB)
        XCTAssertEqual(messageStore.conversations.map(\.id), [conversationB.id])
        XCTAssertEqual(messageStore.conversations.first?.participants, conversationB.participants)
    }
}

@MainActor
final class SecureMessengerNavigationRepairTests: XCTestCase {
    func testRecipientSearchRejectsStaleAccountAndGenerationCompletions() {
        let accountA = UUID(), accountB = UUID()
        var gate = RecipientSearchOperationGate()

        let accountARequest = gate.begin(accountID: accountA)
        gate.invalidate()
        XCTAssertFalse(gate.accepts(accountARequest, selectedAccountID: accountB))

        let firstAccountBRequest = gate.begin(accountID: accountB)
        let newestAccountBRequest = gate.begin(accountID: accountB)
        XCTAssertFalse(gate.accepts(firstAccountBRequest, selectedAccountID: accountB))
        XCTAssertTrue(gate.accepts(newestAccountBRequest, selectedAccountID: accountB))
        XCTAssertFalse(gate.accepts(newestAccountBRequest, selectedAccountID: accountA))
    }

    func testConversationRoutePreservesAccountAndConsumesExactlyOnce() {
        let navigation = ProductNavigation()
        let accountID = UUID(), conversationID = UUID()
        navigation.openConversation(accountID: accountID, conversationID: conversationID)
        XCTAssertEqual(navigation.pendingConversation, .init(accountID: accountID, conversationID: conversationID))
        XCTAssertEqual(navigation.selectedSection, .chats)
        XCTAssertEqual(navigation.consumeConversation(), .init(accountID: accountID, conversationID: conversationID))
        XCTAssertNil(navigation.consumeConversation())
    }

    func testRoutesForTwoAccountsRemainExplicitAndNeverCollide() {
        let navigation = ProductNavigation()
        let firstAccount = UUID(), secondAccount = UUID(), conversationID = UUID()
        navigation.openConversation(accountID: firstAccount, conversationID: conversationID)
        XCTAssertNotEqual(navigation.pendingConversation?.accountID, secondAccount)
        navigation.openConversation(accountID: secondAccount, conversationID: conversationID)
        XCTAssertEqual(navigation.pendingConversation?.accountID, secondAccount)
    }

    func testCallKeyChangeWarningsRemainAccountScopedUntilExplicitClear() {
        let registry = E2EEKeyChangeRegistry.shared
        let accountA = UUID(), accountB = UUID(), userID = UUID(), deviceID = UUID()
        let observed = E2EEDeviceIdentity(
            deviceID: deviceID, signingPrivateKey: .init(), agreementPrivateKey: .init(), keyVersion: 2
        ).publicBundle
        let warningA = E2EECallKeyChangeWarning(
            accountID: accountA, userID: userID, deviceID: deviceID,
            pinnedFingerprint: "old-a", observedFingerprint: observed.fingerprint,
            observedBundle: observed
        )
        let warningB = E2EECallKeyChangeWarning(
            accountID: accountB, userID: userID, deviceID: deviceID,
            pinnedFingerprint: "old-b", observedFingerprint: observed.fingerprint,
            observedBundle: observed
        )

        registry.record(warningA)
        registry.record(warningB)
        XCTAssertEqual(registry.warnings.filter { $0.userID == userID && $0.deviceID == deviceID }.count, 2)
        XCTAssertEqual(registry.warnings(for: accountA), [warningA])
        XCTAssertEqual(registry.warnings(for: accountB), [warningB])
        XCTAssertTrue(registry.warnings(for: nil).isEmpty)
        registry.clear(accountID: accountA, userID: userID, deviceID: deviceID)
        XCTAssertFalse(registry.warnings.contains(where: { $0.id == warningA.id }))
        XCTAssertTrue(registry.warnings.contains(where: { $0.id == warningB.id }))
        registry.clear(accountID: accountB, userID: userID, deviceID: deviceID)
    }

    func testNotificationWorkRoutesOnlyTheExactLoadedAccountAndConversation() async {
        let recorder = RepairNotificationRecorder()
        let coordinator = SecureMessageNotificationWorkCoordinator(
            loader: { accountID, conversationID in
                recorder.loads.append((accountID, conversationID))
                return true
            },
            router: { accountID, conversationID in
                recorder.routes.append((accountID, conversationID))
            },
            sleeper: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) }
        )
        let accountID = UUID(), conversationID = UUID()
        let envelope = SecureMessagePushEnvelope(
            conversationID: conversationID,
            messageID: UUID(),
            accountID: accountID
        )

        let handled = await coordinator.handle(envelope, action: .openConversation, budgetNanoseconds: 1_000_000_000)
        XCTAssertTrue(handled)
        XCTAssertEqual(recorder.loads.count, 1)
        XCTAssertEqual(recorder.loads.first?.0, accountID)
        XCTAssertEqual(recorder.loads.first?.1, conversationID)
        XCTAssertEqual(recorder.routes.count, 1)
        XCTAssertEqual(recorder.routes.first?.0, accountID)
        XCTAssertEqual(recorder.routes.first?.1, conversationID)
        XCTAssertEqual(coordinator.trackedOperationCount, 0)
        XCTAssertEqual(coordinator.trackedDeadlineCount, 0)

        let otherAccount = UUID(), otherConversation = UUID()
        let foregroundEnvelope = SecureMessagePushEnvelope(
            conversationID: otherConversation,
            messageID: UUID(),
            accountID: otherAccount
        )
        let refreshed = await coordinator.handle(
            foregroundEnvelope,
            action: .refreshOnly,
            budgetNanoseconds: 1_000_000_000
        )
        XCTAssertTrue(refreshed)
        XCTAssertEqual(recorder.loads.last?.0, otherAccount)
        XCTAssertEqual(recorder.loads.last?.1, otherConversation)
        XCTAssertEqual(recorder.routes.count, 1)
        XCTAssertEqual(coordinator.trackedOperationCount, 0)
        XCTAssertEqual(coordinator.trackedDeadlineCount, 0)
    }

    func testNotificationDeadlineReturnsAndLateRefreshCannotRoute() async {
        let recorder = RepairNotificationRecorder()
        let loaderGate = RepairAsyncGate()
        let loaderFinishedGate = RepairAsyncGate()
        let deadlineGate = RepairAsyncGate()
        let coordinator = SecureMessageNotificationWorkCoordinator(
            loader: { accountID, conversationID in
                recorder.loads.append((accountID, conversationID))
                await loaderGate.wait()
                recorder.loaderObservedCancellation = Task.isCancelled
                await loaderFinishedGate.release()
                return true
            },
            router: { accountID, conversationID in
                recorder.routes.append((accountID, conversationID))
            },
            sleeper: { _ in await deadlineGate.wait() }
        )
        let envelope = SecureMessagePushEnvelope(
            conversationID: UUID(),
            messageID: UUID(),
            accountID: UUID()
        )
        let work = Task { await coordinator.handle(envelope, action: .openConversation) }
        while recorder.loads.isEmpty { await Task.yield() }
        await deadlineGate.release()
        let handled = await work.value
        XCTAssertFalse(handled)
        XCTAssertEqual(coordinator.trackedOperationCount, 0)
        XCTAssertEqual(coordinator.trackedDeadlineCount, 0)
        await loaderGate.release()
        await loaderFinishedGate.wait()
        XCTAssertTrue(recorder.loaderObservedCancellation)
        XCTAssertTrue(recorder.routes.isEmpty)
        XCTAssertEqual(coordinator.trackedOperationCount, 0)
        XCTAssertEqual(coordinator.trackedDeadlineCount, 0)
    }
}
