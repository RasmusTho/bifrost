import Foundation
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
    @State private var selectedNote: MimerCanvasNote?
    @State private var inspectorIsPresented = true
    @State private var focusedColumn: MimerCanvasFocus = .sidebar
    @FocusState private var focusedElement: MimerCanvasFocus?

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
            .focusable()
            .focused($focusedElement, equals: .sidebar)
            .accessibilityIdentifier("mimer.canvas.focus.sidebar")
            .accessibilityValue(focusValue(for: .sidebar))
        } content: {
            if let selectedLens {
                if selectedLens == .vault {
                    MimerVaultColumnView(
                        fileStore: fileStore,
                        selectedNote: $selectedNote,
                        focusedElement: $focusedElement
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("mimer.canvas.content.\(selectedLens.rawValue)")
                    .accessibilityValue(focusValue(for: .content))
                } else {
                    MimerLensContentView(lens: selectedLens, fileStore: fileStore)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("mimer.canvas.content.\(selectedLens.rawValue)")
                        .focusable()
                        .focused($focusedElement, equals: .content)
                        .accessibilityValue(focusValue(for: .content))
                }
            } else {
                ContentUnavailableView("Choose a Lens", systemImage: "sidebar.left")
            }
        } detail: {
            MimerCanvasDetailView(
                note: selectedNote,
                inspectorIsPresented: inspectorIsPresented
            )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mimer.canvas.detail")
                .focusable()
                .focused($focusedElement, equals: .detail)
                .accessibilityValue(focusValue(for: .detail))
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            MimerCanvasKeyboardCommands(moveFocus: moveFocus)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(inspectorIsPresented ? "Hide Inspector" : "Show Inspector") {
                    inspectorIsPresented.toggle()
                }
                .keyboardShortcut("i", modifiers: .command)
                .accessibilityIdentifier("mimer.canvas.inspector.toggle")
            }
        }
        .onChange(of: selectedLens) { _, lens in
            if lens != nil { setFocus(.content) }
        }
        .onAppear {
            setFocus(.sidebar)
        }
    }

    private func moveFocus(forward: Bool) {
        let targets: [MimerCanvasFocus] = [.sidebar, .content, .detail]
        let currentIndex = targets.firstIndex(of: focusedColumn) ?? 0
        let offset = forward ? 1 : -1
        setFocus(targets[(currentIndex + offset + targets.count) % targets.count])
    }

    private func setFocus(_ target: MimerCanvasFocus) {
        focusedColumn = target
        focusedElement = target
    }

    private func focusValue(for target: MimerCanvasFocus) -> String {
        focusedColumn == target ? "focused" : "unfocused"
    }
}

private enum MimerCanvasFocus: Hashable {
    case sidebar
    case content
    case detail
    case filter
}

private struct MimerCanvasKeyboardCommands: View {
    let moveFocus: (Bool) -> Void

    var body: some View {
        Group {
            Button("Previous column") { moveFocus(false) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Previous column") { moveFocus(false) }
                .keyboardShortcut(.tab, modifiers: .shift)
            Button("Next column") { moveFocus(true) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Next column") { moveFocus(true) }
                .keyboardShortcut(.tab, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct MimerCanvasNote: Equatable {
    let relativePath: String
    let text: String
    let modificationDate: Date?
}

/// Read-only, filesystem-backed Notes column. Its selection is deliberately
/// local SwiftUI state: each folder enumeration is transient and no vault
/// metadata is cached or indexed by the client.
private struct MimerVaultColumnView: View {
    let fileStore: VaultFileStore
    @Binding var selectedNote: MimerCanvasNote?
    let focusedElement: FocusState<MimerCanvasFocus?>.Binding

    @State private var directory = ""
    @State private var entries: [VaultEntry] = []
    @State private var filter = ""
    @State private var loadError: String?

    private var visibleEntries: [VaultEntry] {
        guard !filter.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List {
            Section {
                TextField("Filter notes", text: $filter)
                    .focused(focusedElement, equals: .filter)
                    .accessibilityIdentifier("mimer.canvas.vault.filter")
                    .accessibilityValue(focusedElement.wrappedValue == .filter ? "focused" : "unfocused")
            }
            if !directory.isEmpty {
                Button("Back to \(directory.split(separator: "/").dropLast().last.map(String.init) ?? "Vault")") {
                    directory = directory.split(separator: "/").dropLast().joined(separator: "/")
                    selectedNote = nil
                }
                .accessibilityIdentifier("mimer.canvas.vault.back")
            }
            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
            ForEach(visibleEntries) { entry in
                Button {
                    select(entry)
                } label: {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                }
                .accessibilityIdentifier("mimer.canvas.vault.entry.\(entry.relativePath)")
            }
            if visibleEntries.isEmpty && loadError == nil {
                Text("No files here yet.").foregroundStyle(YggTheme.Color.textSecondary)
            }
        }
        .navigationTitle(directory.isEmpty ? "Vault" : directory.split(separator: "/").last.map(String.init) ?? "Vault")
        .focusable()
        .focused(focusedElement, equals: .content)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Filter") { focusedElement.wrappedValue = .filter }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
        .onAppear(perform: load)
        .onChange(of: directory) { _, _ in load() }
    }

    private func select(_ entry: VaultEntry) {
        if entry.isDirectory {
            directory = entry.relativePath
            selectedNote = nil
            return
        }
        let path = entry.relativePath
        Task { @MainActor in
            do {
                async let text = fileStore.read(path)
                async let modified = fileStore.modificationDate(of: path)
                selectedNote = try await MimerCanvasNote(
                    relativePath: path,
                    text: text,
                    modificationDate: modified
                )
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func load() {
        let currentDirectory = directory
        Task { @MainActor in
            do {
                entries = try await fileStore.listEntries(in: currentDirectory)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct MimerCanvasDetailView: View {
    let note: MimerCanvasNote?
    let inspectorIsPresented: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if let note {
                    ScrollView {
                        MarkdownRendererView(text: note.text)
                            .padding(YggTheme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(note.relativePath.split(separator: "/").last.map(String.init) ?? note.relativePath)
                } else {
                    YggEmptyState(
                        systemImage: "rectangle.on.rectangle",
                        title: "Select an Item",
                        message: "Choose a note from the Vault column to inspect it here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if inspectorIsPresented {
                MimerNoteInspectorView(
                    model: NoteInspectorModel(
                        text: note?.text ?? "",
                        modificationDate: note?.modificationDate
                    )
                )
                    .frame(width: 260)
                    .background(YggTheme.Color.secondaryBackground)
                    .accessibilityIdentifier("mimer.canvas.inspector")
            }
        }
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
