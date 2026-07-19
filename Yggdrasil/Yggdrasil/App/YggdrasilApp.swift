import SwiftUI

@main
struct YggdrasilApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(authGateInitialState: launchAuthState)
        }
    }

    private var launchAuthState: AuthGate.State {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-auth-unlocked") {
            return .unlocked
        }
#endif
        return .locked
    }
}
