import SwiftUI

@main
struct YggdrasilApp: App {
    // This lifetime is intentionally independent from authentication, vault
    // selection, and the Heimdal tab: WCSession can launch the app in the
    // background solely to hand off a Watch recording.
    @StateObject private var watchRelayStartup: WatchRelayStartup

    init() {
        // DEBUG-only, and a no-op unless the journey's launch argument is
        // present: seeds one outbox item so the composed queue journey has real
        // durable evidence to watch advance.
        UITestLaunchConfiguration.current.seedTransferQueueFixtureIfNeeded()
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
        UITestLaunchConfiguration.current.authInitialState ?? .locked
    }
}
