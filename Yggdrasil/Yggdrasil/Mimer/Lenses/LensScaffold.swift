import SwiftUI

/// Shared presentation and error-handling scaffolding for Mimer's typed
/// lenses. Each lens keeps ownership of its note-specific load/save work,
/// while errors are rendered and recorded consistently.
enum LensScaffold {
    @ViewBuilder
    static func errorBanner(_ error: String?) -> some View {
        if let error {
            Text(error).foregroundStyle(.red)
        }
    }

    @discardableResult
    static func perform(error errorBinding: Binding<String?>, _ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            errorBinding.wrappedValue = nil
            return true
        } catch let caughtError {
            errorBinding.wrappedValue = caughtError.localizedDescription
            return false
        }
    }

    static func load(
        error errorBinding: Binding<String?>,
        operation: () throws -> Void,
        recover: (Error) -> Bool
    ) {
        do {
            try operation()
            errorBinding.wrappedValue = nil
        } catch let caughtError {
            if recover(caughtError) {
                errorBinding.wrappedValue = nil
            } else {
                errorBinding.wrappedValue = caughtError.localizedDescription
            }
        }
    }
}
