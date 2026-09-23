import Foundation

@MainActor
final class AccountPushRegistrationCoordinator {
    static let shared = AccountPushRegistrationCoordinator(
        store: .shared,
        client: AccountAPIClient(config: .load(), tokenStore: AccountSessionStore.shared.tokenStore),
        platform: {
            #if os(watchOS)
            return "watchOS"
            #else
            return "iOS"
            #endif
        }()
    )

    private let store: AccountSessionStore
    private let client: AccountAPIClient
    let platform: String
    private let generation: UInt64
    private let environment: APNSEnvironment
    private var tokens: [DevicePushType: Data] = [:]
    private var currentCapabilities = DeviceCapabilities(voipPush: false, alertPush: false, notificationsAuthorized: false, microphoneReady: false)

    init(store: AccountSessionStore, client: AccountAPIClient, platform: String, generation: UInt64 = InstallationIdentity.shared.generation, environment: APNSEnvironment = .production) {
        self.store = store
        self.client = client
        self.platform = platform
        self.generation = generation
        self.environment = environment
    }

    func update(token: Data, pushType: DevicePushType, capabilities: DeviceCapabilities) async {
        tokens[pushType] = token
        currentCapabilities = capabilities
        for account in store.accounts {
            try? await client.registerDevice(accountID: account.accountID, token: token, pushType: pushType, capabilities: capabilities, installationGeneration: generation, environment: environment)
        }
    }

    func registerKnownTokens(for accountID: UUID) async {
        for pushType in [DevicePushType.alert, .voip] {
            guard let token = tokens[pushType] else { continue }
            try? await client.registerDevice(accountID: accountID, token: token, pushType: pushType, capabilities: currentCapabilities, installationGeneration: generation, environment: environment)
        }
    }

    func invalidate(pushType: DevicePushType, expectedToken: Data?) async {
        if expectedToken == nil || tokens[pushType] == expectedToken { tokens[pushType] = nil }
        for account in store.accounts {
            try? await client.invalidateDevice(accountID: account.accountID, pushType: pushType, expectedToken: expectedToken, capabilities: currentCapabilities, installationGeneration: generation, environment: environment)
        }
    }
}
