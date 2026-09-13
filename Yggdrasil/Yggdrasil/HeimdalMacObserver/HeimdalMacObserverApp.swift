import SwiftUI

struct HeimdalMacObserverRuntime {
    static let identifier = "HeimdalMacObserver"

    let screenCaptureEnabled = false
}

@main
struct HeimdalMacObserverApp: App {
    private let runtime = HeimdalMacObserverRuntime()

    var body: some Scene {
        WindowGroup {
            HeimdalMacObserverFoundationView(runtime: runtime)
        }
    }
}

private struct HeimdalMacObserverFoundationView: View {
    let runtime: HeimdalMacObserverRuntime

    var body: some View {
        VStack(spacing: 12) {
            Text("Heimdal macOS observer foundation")
                .font(.title2)
            Text("Platform target ready; screen observation is not implemented in this slice.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 420, minHeight: 180)
        .accessibilityIdentifier(HeimdalMacObserverRuntime.identifier)
    }
}
