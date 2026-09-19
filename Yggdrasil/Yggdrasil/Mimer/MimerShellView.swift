import Foundation
import SwiftUI
import YggdrasilCore

/// The Mimer-iPhone client: the daily reader/steerer over vault notes,
/// hosted inside the Yggdrasil shell. Each tab is a lens over one of the
/// hub's A14–A19 `_heimdal/**` control-surface notes — never a private
/// store, always a markdown note this same client (or Obsidian) can edit.
struct MimerShellView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let vaultURL: URL

    private var fileStore: VaultFileStore { VaultFileStore(rootURL: vaultURL) }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                MimerIPadCanvasView(fileStore: fileStore)
            } else {
                MimerPhoneTabView(fileStore: fileStore)
            }
        }
        .tint(YggTheme.Color.accent)
        .background(YggTheme.Color.background)
    }
}

private struct MimerPhoneTabView: View {
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
    }
}

private enum MimerIPadLens: String, CaseIterable, Hashable, Identifiable {
    case today, interests, entities, consent, vault, settings

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

    var sourcePath: String {
        switch self {
        case .today: HeimdalPaths.attention(for: Date())
        case .interests: HeimdalPaths.interests
        case .entities: HeimdalPaths.entityReview
        case .consent: HeimdalPaths.consent
        case .vault: HeimdalPaths.root
        case .settings: HeimdalPaths.settings
        }
    }
}

private struct MimerIPadCanvasView: View {
    let fileStore: VaultFileStore

    @State private var selectedLens: MimerIPadLens = .today
    @State private var selectedNotePath: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isInspectorPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                Section("Mimer") {
                    ForEach(MimerIPadLens.allCases) { lens in
                        Button {
                            selectedLens = lens
                        } label: {
                            Label(lens.title, systemImage: lens.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedLens == lens
                                ? YggTheme.Color.agent.opacity(0.14)
                                : YggTheme.Color.secondaryBackground
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Mimer")
        } content: {
            if selectedLens == .vault {
                MimerIPadVaultColumnView(fileStore: fileStore, selectedNotePath: $selectedNotePath)
            } else {
                MimerIPadLensColumnView(lens: selectedLens, fileStore: fileStore)
            }
        } detail: {
            if selectedLens == .vault, let selectedNotePath {
                HStack(spacing: 0) {
                    NoteDetailView(relativePath: selectedNotePath, fileStore: fileStore)
                        .id(selectedNotePath)
                    if isInspectorPresented {
                        Divider()
                        MimerIPadInspectorView(relativePath: selectedNotePath, fileStore: fileStore)
                            .frame(width: 280)
                    }
                }
            } else {
                MimerIPadContextDetail(lens: selectedLens)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            if selectedLens == .vault, selectedNotePath != nil {
                ToolbarItem(placement: .navigationBarLeading) {
                    if columnVisibility == .detailOnly {
                        Button {
                            columnVisibility = .all
                        } label: {
                            Label("Browse", systemImage: "sidebar.left")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isInspectorPresented ? "Hide Inspector" : "Inspector") {
                        isInspectorPresented.toggle()
                    }
                }
            }
        }
        .onChange(of: selectedLens) { _, lens in
            guard lens != .vault else { return }
            selectedNotePath = nil
            columnVisibility = .all
            isInspectorPresented = false
        }
        .onChange(of: selectedNotePath) { _, path in
            guard path != nil else { return }
            columnVisibility = .detailOnly
            isInspectorPresented = false
        }
    }
}

private struct MimerIPadLensColumnView: View {
    let lens: MimerIPadLens
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
            EmptyView()
        case .settings:
            SettingsLensView(fileStore: fileStore)
        }
    }
}

private struct MimerIPadVaultColumnView: View {
    let fileStore: VaultFileStore
    @Binding var selectedNotePath: String?

    @State private var relativeDirectory = ""
    @State private var entries: [VaultEntry] = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        List {
            if let loadError {
                YggBanner(
                    title: "Vault unreachable",
                    message: loadError,
                    kind: .destructive,
                    retry: load
                )
                .listRowBackground(Color.clear)
            }

            Section {
                YggSourceFooter(path: relativeDirectory.isEmpty ? HeimdalPaths.root : relativeDirectory)
                    .listRowBackground(Color.clear)
            }

            Section(navigationTitle) {
                if isLoading {
                    YggLoadingRows()
                } else if entries.isEmpty {
                    YggEmptyState(
                        systemImage: "folder",
                        title: "Nothing here yet",
                        message: "Markdown files and folders will appear here."
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            Button {
                                relativeDirectory = entry.relativePath
                                selectedNotePath = nil
                                load()
                            } label: {
                                Label(entry.name, systemImage: "folder")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                selectedNotePath = entry.relativePath
                            } label: {
                                Label(entry.name, systemImage: "doc.text")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(YggTheme.Color.textPrimary)
                            .listRowBackground(
                                selectedNotePath == entry.relativePath
                                    ? YggTheme.Color.agent.opacity(0.14)
                                    : YggTheme.Color.secondaryBackground
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(YggTheme.Color.background)
        .navigationTitle(navigationTitle)
        .toolbar {
            if !relativeDirectory.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") {
                        relativeDirectory = parentDirectory
                        selectedNotePath = nil
                        load()
                    }
                }
            }
        }
        .refreshable { load() }
        .onAppear(perform: load)
    }

    private var navigationTitle: String {
        guard !relativeDirectory.isEmpty else { return "Vault" }
        return relativeDirectory.split(separator: "/").last.map(String.init) ?? "Folder"
    }

    private var parentDirectory: String {
        guard let separator = relativeDirectory.lastIndex(of: "/") else { return "" }
        return String(relativeDirectory[..<separator])
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try fileStore.listEntries(in: relativeDirectory)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct MimerIPadContextDetail: View {
    let lens: MimerIPadLens

    var body: some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.md) {
            YggEmptyState(
                systemImage: lens.systemImage,
                title: "(lens.title) lens",
                message: "The selected lens is the active markdown-backed surface in the content column."
            )
            YggSourceFooter(path: lens.sourcePath)
        }
        .padding(YggTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(YggTheme.Color.background)
    }
}

private struct MimerIPadInspectorView: View {
    let relativePath: String
    let fileStore: VaultFileStore

    @State private var metadata: [(key: String, value: String)] = []
    @State private var loadError: String?

    var body: some View {
        List {
            Section("Inspector") {
                if let loadError {
                    YggBanner(title: "Metadata unavailable", message: loadError, kind: .destructive)
                        .listRowBackground(Color.clear)
                } else if metadata.isEmpty {
                    Text("No frontmatter recorded.")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                } else {
                    ForEach(metadata, id: \.key) { field in
                        LabeledContent(field.key) {
                            Text(field.value)
                                .font(YggTheme.Typography.monospaceCaption)
                                .foregroundStyle(YggTheme.Color.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(YggTheme.Color.secondaryBackground)
        .navigationTitle("Inspector")
        .onAppear(perform: load)
        .onChange(of: relativePath) { _, _ in load() }
    }

    private func load() {
        do {
            let document = try FrontmatterDocument.parse(fileStore.read(relativePath))
            let preferredKeys = ["uuid", "zone", "origin", "provenance", "modified"]
            metadata = preferredKeys.map { key in
                (key: key, value: valueDescription(document.frontmatter[key]))
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func valueDescription(_ value: YAMLValue?) -> String {
        guard let value else { return "Not recorded" }
        if let scalar = value.stringValue { return scalar }
        return YAMLCodec.serialize(value)
    }
}
