import SwiftUI

/// The Mimer client: the daily reader/steerer over vault notes, hosted inside
/// the Yggdrasil shell. Compact widths preserve the shipped tab experience;
/// regular widths use the iPad thinking canvas without changing the lenses'
/// vault binding or data flow.
struct MimerShellView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let vaultURL: URL

    private var fileStore: VaultFileStore { VaultFileStore(rootURL: vaultURL) }

    var body: some View {
        if horizontalSizeClass == .regular {
            MimerCanvasView(fileStore: fileStore)
        } else {
            MimerTabView(fileStore: fileStore)
        }
    }
}

private enum MimerLens: String, CaseIterable, Hashable, Identifiable {
    case today
    case interests
    case entities
    case consent
    case vault
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .interests: "Interests"
        case .entities: "Entities"
        case .consent: "Consent"
        case .vault: "Vault"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .interests: "slider.horizontal.3"
        case .entities: "person.crop.circle.badge.questionmark"
        case .consent: "hand.raised"
        case .vault: "folder"
        case .settings: "gearshape"
        }
    }
}

/// Kept separate so the compact branch remains the original tab set and
/// presentation hierarchy. New canvas work must not alter this view.
private struct MimerTabView: View {
    let fileStore: VaultFileStore

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
        .accessibilityIdentifier("mimer.compact.tabView")
    }
}

private struct MimerCanvasView: View {
    let fileStore: VaultFileStore
    @State private var selectedLens: MimerLens? = .today
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedLens) {
                ForEach(MimerLens.allCases) { lens in
                    Label(lens.title, systemImage: lens.systemImage)
                        .tag(lens)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mimer.canvas.lens.\(lens.rawValue)")
                }
            }
            .navigationTitle("Mimer")
        } content: {
            if let selectedLens {
                MimerLensContentView(lens: selectedLens, fileStore: fileStore)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("mimer.canvas.content.\(selectedLens.rawValue)")
            } else {
                ContentUnavailableView("Choose a Lens", systemImage: "sidebar.left")
            }
        } detail: {
            YggEmptyState(
                systemImage: "rectangle.on.rectangle",
                title: "Select an Item",
                message: "Choose an item from a Mimer lens to inspect it here."
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mimer.canvas.detail")
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct MimerLensContentView: View {
    let lens: MimerLens
    let fileStore: VaultFileStore

    @ViewBuilder
    var body: some View {
        switch lens {
        case .today:
            AttentionLensView(fileStore: fileStore)
        case .interests:
            InterestsLensView(fileStore: fileStore)
        case .entities:
            EntityConfirmLensView(fileStore: fileStore)
        case .consent:
            ConsentLensView(fileStore: fileStore)
        case .vault:
            // NoteBrowserView assumes a navigation context for folder drills;
            // the canvas supplies it without changing the compact tab path.
            NavigationStack {
                NoteBrowserView(fileStore: fileStore)
            }
        case .settings:
            SettingsLensView(fileStore: fileStore)
        }
    }
}
