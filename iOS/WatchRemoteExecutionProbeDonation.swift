import Intents

enum WatchRemoteExecutionProbeDonation {
    static let interactionIdentifier = "watch-remote-execution-probe"
    static let intentTypeIdentity = "WatchRemoteExecutionProbeIntent"
    static let suggestedInvocationPhrase = "Run remote execution probe"

    static func makeIntent() -> WatchRemoteExecutionProbeIntent {
        let intent = WatchRemoteExecutionProbeIntent()
        intent.suggestedInvocationPhrase = suggestedInvocationPhrase
        return intent
    }

    static func makeShortcut() -> INShortcut? {
        INShortcut(intent: makeIntent())
    }

    static func intentIdentity(for intent: INIntent?) -> String? {
        intent is WatchRemoteExecutionProbeIntent ? intentTypeIdentity : nil
    }

    static func register() {
        let intent = makeIntent()

        if let shortcut = INShortcut(intent: intent) {
            INVoiceShortcutCenter.shared.setShortcutSuggestions([shortcut])
        }

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = interactionIdentifier
        interaction.donate(completion: nil)
    }
}
