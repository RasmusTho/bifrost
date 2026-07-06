import SwiftUI

/// The Mimer-iPhone client: the daily reader/steerer over vault notes,
/// hosted inside the Yggdrasil shell. Each tab is a lens over one of the
/// hub's A14–A19 `_heimdal/**` control-surface notes — never a private
/// store, always a markdown note this same client (or Obsidian) can edit.
struct MimerShellView: View {
    let vaultURL: URL

    private var fileStore: VaultFileStore { VaultFileStore(rootURL: vaultURL) }

    var body: some View {
        TabView {
            AttentionLensView(fileStore: fileStore)
                .tabItem { Label("Today", systemImage: "sun.max") }

            InterestsLensView(fileStore: fileStore)
                .tabItem { Label("Interests", systemImage: "slider.horizontal.3") }

            EntityConfirmLensView(fileStore: fileStore)
                .tabItem { Label("Entities", systemImage: "person.crop.circle.badge.questionmark") }

            ConsentLensView(fileStore: fileStore)
                .tabItem { Label("Consent", systemImage: "hand.raised") }

            // NoteBrowserView pushes further instances of itself via
            // NavigationLink as the user drills into folders, so the
            // NavigationStack belongs once here at the tab root — not inside
            // NoteBrowserView itself, which would nest a stack per push and
            // break back-navigation.
            NavigationStack {
                NoteBrowserView(fileStore: fileStore)
            }
            .tabItem { Label("Vault", systemImage: "folder") }

            SettingsLensView(fileStore: fileStore)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
