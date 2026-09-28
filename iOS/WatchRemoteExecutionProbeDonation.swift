import Intents

enum WatchRemoteExecutionProbeDonation {
    static let interactionIdentifier = "watch-remote-execution-probe"

    static func register() {
        let intent = WatchRemoteExecutionProbeIntent()
        intent.suggestedInvocationPhrase = "Run iPhone execution probe"

        if let shortcut = INShortcut(intent: intent) {
            INVoiceShortcutCenter.shared.setShortcutSuggestions([shortcut])
        }

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = interactionIdentifier
        interaction.donate(completion: nil)
    }
}
