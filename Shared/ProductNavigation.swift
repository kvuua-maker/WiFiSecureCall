import Foundation

enum ProductSection: String, CaseIterable, Identifiable {
    case chats = "Chats"
    case calls = "Calls"
    case contacts = "Contacts"
    case profile = "Profile"
    var id: String { rawValue }
}

enum ProductLoadingState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

enum ProductAccessibility {
    static let mute = "Mute microphone transmission"
    static let unmute = "Resume microphone transmission"
    static let endCall = "End secure call"
    static let sendMessage = "Send encrypted message"
}

@MainActor
final class ProductNavigation: ObservableObject {
    static let shared = ProductNavigation()

    struct ConversationRoute: Equatable, Sendable {
        let accountID: UUID
        let conversationID: UUID
    }

    @Published private(set) var pendingConversation: ConversationRoute?
    @Published private(set) var selectedSection: ProductSection = .chats

    func openConversation(accountID: UUID, conversationID: UUID) {
        selectedSection = .chats
        pendingConversation = .init(accountID: accountID, conversationID: conversationID)
    }

    func select(_ section: ProductSection) {
        selectedSection = section
    }

    func consumeConversation() -> ConversationRoute? {
        defer { pendingConversation = nil }
        return pendingConversation
    }
}
