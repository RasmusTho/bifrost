import SwiftUI

@main
struct YggdrasilApp: App {
    // This lifetime is intentionally independent from authentication, vault
    // selection, and the Heimdal tab: WCSession can launch the app in the
    // background solely to hand off a Watch recording.
    @StateObject private var watchRelayStartup: WatchRelayStartup
    @AppStorage(YggAppearance.storageKey) private var appearanceRawValue = YggAppearance.defaultValue.rawValue

    init() {
        // DEBUG-only, and a no-op unless the journey's launch argument is
        // present: seeds one outbox item so the composed queue journey has real
        // durable evidence to watch advance.
        #if DEBUG
        if UITestLaunchConfiguration.current.shouldResetOutbox {
            try? FileManager.default.removeItem(at: TransferOutboxStore.defaultRootURL())
        }
        #endif
        UITestLaunchConfiguration.current.seedTransferQueueFixtureIfNeeded()
        UITestLaunchConfiguration.current.seedPendingCaptureIfNeeded()
        #if DEBUG
        if UITestLaunchConfiguration.current.shouldResetLiveMeetingNotes {
            try? FileManager.default.removeItem(at: LiveMeetingNotePaths.defaultDirectory())
        }
        #endif
        YggFonts.register()
        YggAppearance.configureNavigationTitles()
        _watchRelayStartup = StateObject(wrappedValue: WatchRelayStartup())
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                authGateInitialState: launchAuthState,
                heimdalSessionModel: watchRelayStartup.sessionModel
            )
            // Yggdrasil Dark is the default; Yggdrasil Light "Shell" is a
            // per-user choice (Mimer Settings). Every YggTheme role resolves
            // through the colour scheme, so this is the only theme switch.
            // Standard controls take the Yggdrasil accent ink rather than the
            // asset-catalog AccentColor.
            .preferredColorScheme(YggAppearance(storedValue: appearanceRawValue).colorScheme)
            .tint(YggTheme.Color.accent)
            .font(YggTheme.Typography.body)
        }
    }

    private var launchAuthState: AuthGate.State {
        UITestLaunchConfiguration.current.authInitialState ?? .locked
    }
}
