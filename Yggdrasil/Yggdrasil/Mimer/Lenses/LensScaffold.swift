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
    static func perform(error: Binding<String?>, _ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            error.wrappedValue = nil
            return true
        } catch {
            error.wrappedValue = error.localizedDescription
            return false
        }
    }

    static func load(
        error: Binding<String?>,
        operation: () throws -> Void,
        recover: (Error) -> Bool
    ) {
        do {
            try operation()
            error.wrappedValue = nil
        } catch {
            if recover(error) {
                error.wrappedValue = nil
            } else {
                error.wrappedValue = error.localizedDescription
            }
        }
    }
}
