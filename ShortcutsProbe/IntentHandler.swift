import Foundation
import Intents
import UserNotifications

protocol RemoteExecutionReceiptNotificationScheduling {
    func schedule(
        identifier: String,
        title: String,
        body: String,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

protocol RemoteExecutionReceiptDeadlineCancellation {
    func cancel()
}

protocol RemoteExecutionReceiptDeadlineScheduling {
    func schedule(
        after interval: TimeInterval,
        operation: @escaping () -> Void
    ) -> RemoteExecutionReceiptDeadlineCancellation
}

private final class SystemRemoteExecutionReceiptNotificationScheduler:
    RemoteExecutionReceiptNotificationScheduling
{
    func schedule(
        identifier: String,
        title: String,
        body: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
}

private final class DispatchRemoteExecutionReceiptDeadlineCancellation:
    RemoteExecutionReceiptDeadlineCancellation
{
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private struct DispatchRemoteExecutionReceiptDeadlineScheduler:
    RemoteExecutionReceiptDeadlineScheduling
{
    func schedule(
        after interval: TimeInterval,
        operation: @escaping () -> Void
    ) -> RemoteExecutionReceiptDeadlineCancellation {
        let workItem = DispatchWorkItem(block: operation)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + interval,
            execute: workItem
        )
        return DispatchRemoteExecutionReceiptDeadlineCancellation(workItem: workItem)
    }
}

private final class RemoteExecutionResponseGate {
    private let lock = NSLock()
    private var isCompleted = false
    private var deadlineCancellation: RemoteExecutionReceiptDeadlineCancellation?

    func install(deadlineCancellation: RemoteExecutionReceiptDeadlineCancellation) {
        lock.lock()
        if isCompleted {
            lock.unlock()
            deadlineCancellation.cancel()
            return
        }
        self.deadlineCancellation = deadlineCancellation
        lock.unlock()
    }

    func complete(
        with response: WatchRemoteExecutionProbeIntentResponse,
        completion: @escaping (WatchRemoteExecutionProbeIntentResponse) -> Void
    ) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let deadlineCancellation = self.deadlineCancellation
        self.deadlineCancellation = nil
        lock.unlock()

        deadlineCancellation?.cancel()
        completion(response)
    }
}

final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        guard intent is WatchRemoteExecutionProbeIntent else { return self }
        return WatchRemoteExecutionProbeIntentHandler()
    }
}

final class WatchRemoteExecutionProbeIntentHandler: NSObject, WatchRemoteExecutionProbeIntentHandling {
    static let executionMarker = "EXECUTED_ON_IPHONE"
    static let receiptTitle = "Remote execution confirmed"
    static let receiptScheduleAccepted = "LOCAL_RECEIPT_SCHEDULE_ACCEPTED"
    static let receiptScheduleFailed = "LOCAL_RECEIPT_SCHEDULE_FAILED"
    static let receiptScheduleTimedOut = "LOCAL_RECEIPT_SCHEDULE_TIMED_OUT"

    private let nonceFactory: () -> UUID
    private let receiptScheduler: RemoteExecutionReceiptNotificationScheduling
    private let deadlineScheduler: RemoteExecutionReceiptDeadlineScheduling
    private let receiptSchedulingBudget: TimeInterval

    override convenience init() {
        self.init(
            nonceFactory: UUID.init,
            receiptScheduler: SystemRemoteExecutionReceiptNotificationScheduler(),
            deadlineScheduler: DispatchRemoteExecutionReceiptDeadlineScheduler(),
            receiptSchedulingBudget: 2
        )
    }

    init(
        nonceFactory: @escaping () -> UUID,
        receiptScheduler: RemoteExecutionReceiptNotificationScheduling,
        deadlineScheduler: RemoteExecutionReceiptDeadlineScheduling,
        receiptSchedulingBudget: TimeInterval = 2
    ) {
        self.nonceFactory = nonceFactory
        self.receiptScheduler = receiptScheduler
        self.deadlineScheduler = deadlineScheduler
        self.receiptSchedulingBudget = receiptSchedulingBudget
        super.init()
    }

    func handle(
        intent: WatchRemoteExecutionProbeIntent,
        completion: @escaping (WatchRemoteExecutionProbeIntentResponse) -> Void
    ) {
        let nonce = nonceFactory().uuidString.lowercased()
        let executionResult = "\(Self.executionMarker) · \(nonce)"
        let gate = RemoteExecutionResponseGate()
        let deadlineCancellation = deadlineScheduler.schedule(after: receiptSchedulingBudget) {
            gate.complete(
                with: Self.makeResponse(
                    nonce: nonce,
                    executionResult: executionResult,
                    receiptStatus: Self.receiptScheduleTimedOut
                ),
                completion: completion
            )
        }
        gate.install(deadlineCancellation: deadlineCancellation)

        receiptScheduler.schedule(
            identifier: "remote-execution-receipt.\(nonce)",
            title: Self.receiptTitle,
            body: executionResult
        ) { result in
            let receiptStatus: String
            switch result {
            case .success:
                receiptStatus = Self.receiptScheduleAccepted
            case .failure:
                receiptStatus = Self.receiptScheduleFailed
            }
            gate.complete(
                with: Self.makeResponse(
                    nonce: nonce,
                    executionResult: executionResult,
                    receiptStatus: receiptStatus
                ),
                completion: completion
            )
        }
    }

    private static func makeResponse(
        nonce: String,
        executionResult: String,
        receiptStatus: String
    ) -> WatchRemoteExecutionProbeIntentResponse {
        let response = WatchRemoteExecutionProbeIntentResponse(code: .success, userActivity: nil)
        response.nonce = nonce
        response.executionResult = executionResult
        response.receiptStatus = receiptStatus
        return response
    }
}
