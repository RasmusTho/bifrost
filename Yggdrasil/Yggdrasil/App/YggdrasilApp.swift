import SwiftUI

@main
struct YggdrasilApp: App {
    // This lifetime is intentionally independent from authentication, vault
    // selection, and the Heimdal tab: WCSession can launch the app in the
    // background solely to hand off a Watch recording.
    @StateObject private var watchRelayStartup: WatchRelayStartup

    init() {
        _watchRelayStartup = StateObject(wrappedValue: WatchRelayStartup())
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                authGateInitialState: launchAuthState,
                heimdalSessionModel: watchRelayStartup.sessionModel
            )
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
