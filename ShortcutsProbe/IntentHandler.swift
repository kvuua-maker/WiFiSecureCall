import Foundation
import Intents

final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        guard intent is WatchRemoteExecutionProbeIntent else { return self }
        return WatchRemoteExecutionProbeIntentHandler()
    }
}

final class WatchRemoteExecutionProbeIntentHandler: NSObject, WatchRemoteExecutionProbeIntentHandling {
    static let executionMarker = "EXECUTED_ON_IPHONE"

    private let nonceFactory: () -> UUID

    override convenience init() {
        self.init(nonceFactory: UUID.init)
    }

    init(nonceFactory: @escaping () -> UUID) {
        self.nonceFactory = nonceFactory
        super.init()
    }

    func handle(
        intent: WatchRemoteExecutionProbeIntent,
        completion: @escaping (WatchRemoteExecutionProbeIntentResponse) -> Void
    ) {
        completion(makeResponse())
    }

    private func makeResponse() -> WatchRemoteExecutionProbeIntentResponse {
        let nonce = nonceFactory().uuidString.lowercased()
        let response = WatchRemoteExecutionProbeIntentResponse(code: .success, userActivity: nil)
        response.nonce = nonce
        response.executionResult = "\(Self.executionMarker) · \(nonce)"
        return response
    }
}
