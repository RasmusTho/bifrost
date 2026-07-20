import Combine
import SwiftUI
import UIKit

/// Hosts the iPad canvas in the UIKit responder chain so traversal commands
/// remain available while a SwiftUI text field is the first responder.
struct MimerCanvasKeyboardHost: UIViewControllerRepresentable {
    let fileStore: VaultFileStore

    func makeUIViewController(context: Context) -> MimerCanvasHostingController {
        MimerCanvasHostingController(fileStore: fileStore)
    }

    func updateUIViewController(
        _: MimerCanvasHostingController,
        context _: Context
    ) {}
}

@MainActor
final class MimerCanvasHostingController: UIHostingController<MimerCanvasView> {
    private let keyboardRouter: MimerCanvasKeyboardRouter

    init(fileStore: VaultFileStore) {
        let keyboardRouter = MimerCanvasKeyboardRouter()
        self.keyboardRouter = keyboardRouter
        super.init(
            rootView: MimerCanvasView(
                fileStore: fileStore,
                keyboardRouter: keyboardRouter
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + traversalKeyCommands
    }

    @objc private func moveToPreviousColumn(_ sender: UIKeyCommand) {
        keyboardRouter.send(.previousColumn)
    }

    @objc private func moveToNextColumn(_ sender: UIKeyCommand) {
        keyboardRouter.send(.nextColumn)
    }

    @objc private func focusFilter(_ sender: UIKeyCommand) {
        keyboardRouter.send(.focusFilter)
    }

    @objc private func toggleMimerInspector(_ sender: UIKeyCommand) {
        keyboardRouter.send(.toggleInspector)
    }

    private lazy var traversalKeyCommands: [UIKeyCommand] = [
        priorityKeyCommand(
            input: "\t",
            modifierFlags: .shift,
            action: #selector(moveToPreviousColumn(_:)),
            discoverabilityTitle: "Previous Column"
        ),
        priorityKeyCommand(
            input: UIKeyCommand.inputLeftArrow,
            modifierFlags: [],
            action: #selector(moveToPreviousColumn(_:)),
            discoverabilityTitle: "Previous Column"
        ),
        priorityKeyCommand(
            input: "\t",
            modifierFlags: [],
            action: #selector(moveToNextColumn(_:)),
            discoverabilityTitle: "Next Column"
        ),
        priorityKeyCommand(
            input: UIKeyCommand.inputRightArrow,
            modifierFlags: [],
            action: #selector(moveToNextColumn(_:)),
            discoverabilityTitle: "Next Column"
        ),
        priorityKeyCommand(
            input: "f",
            modifierFlags: .command,
            action: #selector(focusFilter(_:)),
            discoverabilityTitle: "Filter Notes"
        ),
        priorityKeyCommand(
            input: "i",
            modifierFlags: .command,
            action: #selector(toggleMimerInspector(_:)),
            discoverabilityTitle: "Toggle Inspector"
        )
    ]

    private func priorityKeyCommand(
        input: String,
        modifierFlags: UIKeyModifierFlags,
        action: Selector,
        discoverabilityTitle: String
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifierFlags,
            action: action
        )
        command.discoverabilityTitle = discoverabilityTitle
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}

enum MimerCanvasKeyboardCommand {
    case previousColumn
    case nextColumn
    case focusFilter
    case toggleInspector
}

@MainActor
final class MimerCanvasKeyboardRouter: ObservableObject {
    @Published private(set) var command: MimerCanvasKeyboardCommand?

    func send(_ command: MimerCanvasKeyboardCommand) {
        self.command = command
    }
}
