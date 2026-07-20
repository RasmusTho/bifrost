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
final class MimerCanvasHostingController: UIViewController {
    private let keyboardRouter: MimerCanvasKeyboardRouter
    private let canvasHost: UIHostingController<MimerCanvasView>

    init(fileStore: VaultFileStore) {
        let keyboardRouter = MimerCanvasKeyboardRouter()
        self.keyboardRouter = keyboardRouter
        canvasHost = UIHostingController(
            rootView: MimerCanvasView(
                fileStore: fileStore,
                keyboardRouter: keyboardRouter
            )
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = MimerCanvasKeyboardCaptureView(keyboardRouter: keyboardRouter)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(canvasHost)
        view.addSubview(canvasHost.view)
        canvasHost.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvasHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasHost.view.topAnchor.constraint(equalTo: view.topAnchor),
            canvasHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        canvasHost.didMove(toParent: self)
    }
}

/// A stable UIKit superview for the SwiftUI canvas. On iOS 17, a focused
/// SwiftUI list can consume Tab and arrow events before an embedded hosting
/// controller's `keyCommands` are consulted. Keeping the commands on this
/// view places them in every focused canvas control's responder chain,
/// including the filter text field.
@MainActor
private final class MimerCanvasKeyboardCaptureView: UIView {
    private let keyboardRouter: MimerCanvasKeyboardRouter

    init(keyboardRouter: MimerCanvasKeyboardRouter) {
        self.keyboardRouter = keyboardRouter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var keyCommands: [UIKeyCommand]? {
        [
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
    }

    @objc private func moveToPreviousColumn(_: UIKeyCommand) {
        keyboardRouter.send(.previousColumn)
    }

    @objc private func moveToNextColumn(_: UIKeyCommand) {
        keyboardRouter.send(.nextColumn)
    }

    @objc private func focusFilter(_: UIKeyCommand) {
        keyboardRouter.send(.focusFilter)
    }

    @objc private func toggleMimerInspector(_: UIKeyCommand) {
        keyboardRouter.send(.toggleInspector)
    }

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
