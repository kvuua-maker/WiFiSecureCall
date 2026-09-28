import Intents
import IntentsUI
import SwiftUI

enum RemoteExecutionShortcutInstallState: String, Equatable {
    case checking = "CHECKING"
    case notAdded = "NOT_ADDED"
    case added = "ADDED"
    case queryFailed = "QUERY_FAILED"
}

enum RemoteExecutionShortcutOperationState: Equatable {
    case idle
    case presentingAdd
    case presentingEdit
    case verifyingAdd
    case verifyingEdit
    case verifyingDelete
    case addConfirmed
    case editConfirmed
    case deleteConfirmed
    case cancelled
    case failed(String)

    var displayValue: String {
        switch self {
        case .idle: return "IDLE"
        case .presentingAdd: return "SYSTEM_ADD_SHEET_OPEN"
        case .presentingEdit: return "SYSTEM_EDIT_SHEET_OPEN"
        case .verifyingAdd: return "VERIFYING_ADD"
        case .verifyingEdit: return "VERIFYING_EDIT"
        case .verifyingDelete: return "VERIFYING_DELETE"
        case .addConfirmed: return "ADD_CONFIRMED"
        case .editConfirmed: return "EDIT_CONFIRMED"
        case .deleteConfirmed: return "DELETE_CONFIRMED"
        case .cancelled: return "CANCELLED"
        case let .failed(reason): return reason
        }
    }
}

struct RemoteExecutionVoiceShortcutRecord {
    let identifier: UUID
    let intentIdentity: String
    let systemShortcut: INVoiceShortcut?

    init(identifier: UUID, intentIdentity: String, systemShortcut: INVoiceShortcut? = nil) {
        self.identifier = identifier
        self.intentIdentity = intentIdentity
        self.systemShortcut = systemShortcut
    }
}

protocol RemoteExecutionVoiceShortcutQuerying {
    func getAllVoiceShortcuts(
        completion: @escaping (Result<[RemoteExecutionVoiceShortcutRecord], Error>) -> Void
    )
}

struct SystemRemoteExecutionVoiceShortcutCenter: RemoteExecutionVoiceShortcutQuerying {
    func getAllVoiceShortcuts(
        completion: @escaping (Result<[RemoteExecutionVoiceShortcutRecord], Error>) -> Void
    ) {
        INVoiceShortcutCenter.shared.getAllVoiceShortcuts { shortcuts, error in
            let result: Result<[RemoteExecutionVoiceShortcutRecord], Error>
            if let error {
                result = .failure(error)
            } else {
                result = .success((shortcuts ?? []).map { shortcut in
                    RemoteExecutionVoiceShortcutRecord(
                        identifier: shortcut.identifier,
                        intentIdentity: WatchRemoteExecutionProbeDonation.intentIdentity(
                            for: shortcut.shortcut.intent
                        ) ?? "OTHER_INTENT",
                        systemShortcut: shortcut
                    )
                })
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

enum RemoteExecutionShortcutSystemSheet: Identifiable {
    case add(INShortcut)
    case edit(INVoiceShortcut)

    var id: String {
        switch self {
        case .add: return "add"
        case let .edit(shortcut): return "edit-\(shortcut.identifier.uuidString)"
        }
    }
}

final class WatchRemoteExecutionProbeSetupModel: ObservableObject {
    @Published private(set) var installState: RemoteExecutionShortcutInstallState = .checking
    @Published private(set) var operationState: RemoteExecutionShortcutOperationState = .idle
    @Published private(set) var isQuerying = false
    @Published var systemSheet: RemoteExecutionShortcutSystemSheet?

    private enum Verification {
        case add(UUID)
        case edit(UUID)
        case delete(UUID)
    }

    private let center: RemoteExecutionVoiceShortcutQuerying
    private let shortcutFactory: () -> INShortcut?
    private var matchingShortcut: RemoteExecutionVoiceShortcutRecord?
    private var queryGeneration = 0

    init(
        center: RemoteExecutionVoiceShortcutQuerying = SystemRemoteExecutionVoiceShortcutCenter(),
        shortcutFactory: @escaping () -> INShortcut? = WatchRemoteExecutionProbeDonation.makeShortcut
    ) {
        self.center = center
        self.shortcutFactory = shortcutFactory
    }

    func refresh() {
        refresh(verification: nil, preserveOperation: false)
    }

    func presentSystemFlow() {
        guard !isQuerying else {
            operationState = .failed("QUERY_IN_PROGRESS")
            return
        }

        switch installState {
        case .notAdded:
            guard let shortcut = shortcutFactory() else {
                operationState = .failed("SHORTCUT_CREATION_FAILED")
                return
            }
            operationState = .presentingAdd
            systemSheet = .add(shortcut)
        case .added:
            guard let voiceShortcut = matchingShortcut?.systemShortcut else {
                operationState = .failed("INSTALLED_SHORTCUT_UNAVAILABLE")
                refresh(verification: nil, preserveOperation: true)
                return
            }
            operationState = .presentingEdit
            systemSheet = .edit(voiceShortcut)
        case .checking:
            operationState = .failed("QUERY_IN_PROGRESS")
        case .queryFailed:
            operationState = .failed("QUERY_FAILED")
        }
    }

    func didFinishAdd(identifier: UUID?, error: Error?) {
        systemSheet = nil
        guard error == nil, let identifier else {
            operationState = .failed("ADD_FAILED")
            refresh(verification: nil, preserveOperation: true)
            return
        }
        operationState = .verifyingAdd
        refresh(verification: .add(identifier), preserveOperation: true)
    }

    func didFinishEdit(identifier: UUID?, error: Error?) {
        systemSheet = nil
        guard error == nil, let identifier else {
            operationState = .failed("EDIT_FAILED")
            refresh(verification: nil, preserveOperation: true)
            return
        }
        operationState = .verifyingEdit
        refresh(verification: .edit(identifier), preserveOperation: true)
    }

    func didDelete(identifier: UUID) {
        systemSheet = nil
        operationState = .verifyingDelete
        refresh(verification: .delete(identifier), preserveOperation: true)
    }

    func didCancelSystemFlow() {
        systemSheet = nil
        operationState = .cancelled
        refresh(verification: nil, preserveOperation: true)
    }

    private func refresh(verification: Verification?, preserveOperation: Bool) {
        queryGeneration += 1
        let generation = queryGeneration
        isQuerying = true
        installState = .checking
        if !preserveOperation { operationState = .idle }

        center.getAllVoiceShortcuts { [weak self] result in
            guard let self, generation == self.queryGeneration else { return }
            self.isQuerying = false
            switch result {
            case let .success(records):
                let matches = records
                    .filter { $0.intentIdentity == WatchRemoteExecutionProbeDonation.intentTypeIdentity }
                    .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
                self.matchingShortcut = matches.first
                self.installState = matches.isEmpty ? .notAdded : .added
                guard let verification else { return }
                switch verification {
                case let .add(identifier):
                    self.operationState = matches.contains { $0.identifier == identifier }
                        ? .addConfirmed
                        : .failed("ADD_NOT_CONFIRMED")
                case let .edit(identifier):
                    self.operationState = matches.contains { $0.identifier == identifier }
                        ? .editConfirmed
                        : .failed("EDIT_NOT_CONFIRMED")
                case let .delete(identifier):
                    self.operationState = matches.contains { $0.identifier == identifier }
                        ? .failed("DELETE_NOT_CONFIRMED")
                        : .deleteConfirmed
                }
            case .failure:
                self.matchingShortcut = nil
                self.installState = .queryFailed
                self.operationState = .failed("QUERY_FAILED")
            }
        }
    }
}

struct WatchRemoteExecutionProbeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WatchRemoteExecutionProbeSetupModel()

    var body: some View {
        NavigationView {
            Form {
                Section("Shortcut execution probe") {
                    HStack {
                        Text("Installation state")
                        Spacer()
                        Text(model.installState.rawValue)
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Operation")
                        Spacer()
                        Text(model.operationState.displayValue)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Phrase: Run remote execution probe")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if model.installState == .added {
                        Button("Edit Remote Execution Probe in Shortcuts") {
                            model.presentSystemFlow()
                        }
                    } else {
                        Button("Add Remote Execution Probe to Shortcuts") {
                            model.presentSystemFlow()
                        }
                        .disabled(model.installState != .notAdded)
                    }

                    Button("Refresh Shortcut State") { model.refresh() }
                        .disabled(model.isQuerying)
                }

                Section {
                    Text("The system add or edit sheet is authoritative. ADDED is shown only after the system callback and a refreshed Shortcuts query confirm the installed custom intent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Shortcut execution probe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { model.refresh() }
            .sheet(item: $model.systemSheet) { sheet in
                RemoteExecutionShortcutSystemViewController(sheet: sheet, model: model)
                    .interactiveDismissDisabled()
            }
        }
    }
}

private struct RemoteExecutionShortcutSystemViewController: UIViewControllerRepresentable {
    let sheet: RemoteExecutionShortcutSystemSheet
    let model: WatchRemoteExecutionProbeSetupModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        switch sheet {
        case let .add(shortcut):
            let controller = INUIAddVoiceShortcutViewController(shortcut: shortcut)
            controller.delegate = context.coordinator
            return controller
        case let .edit(voiceShortcut):
            let controller = INUIEditVoiceShortcutViewController(voiceShortcut: voiceShortcut)
            controller.delegate = context.coordinator
            return controller
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, INUIAddVoiceShortcutViewControllerDelegate,
        INUIEditVoiceShortcutViewControllerDelegate {
        private let model: WatchRemoteExecutionProbeSetupModel

        init(model: WatchRemoteExecutionProbeSetupModel) {
            self.model = model
        }

        func addVoiceShortcutViewController(
            _ controller: INUIAddVoiceShortcutViewController,
            didFinishWith voiceShortcut: INVoiceShortcut?,
            error: Error?
        ) {
            model.didFinishAdd(identifier: voiceShortcut?.identifier, error: error)
        }

        func addVoiceShortcutViewControllerDidCancel(_ controller: INUIAddVoiceShortcutViewController) {
            model.didCancelSystemFlow()
        }

        func editVoiceShortcutViewController(
            _ controller: INUIEditVoiceShortcutViewController,
            didUpdate voiceShortcut: INVoiceShortcut?,
            error: Error?
        ) {
            model.didFinishEdit(identifier: voiceShortcut?.identifier, error: error)
        }

        func editVoiceShortcutViewController(
            _ controller: INUIEditVoiceShortcutViewController,
            didDeleteVoiceShortcutWithIdentifier deletedVoiceShortcutIdentifier: UUID
        ) {
            model.didDelete(identifier: deletedVoiceShortcutIdentifier)
        }

        func editVoiceShortcutViewControllerDidCancel(_ controller: INUIEditVoiceShortcutViewController) {
            model.didCancelSystemFlow()
        }
    }
}
