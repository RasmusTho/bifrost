import Combine
import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
            MimerCanvasKeyboardHost(fileStore: fileStore)
                .id(vaultURL)
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

struct MimerCanvasView: View {
    let fileStore: VaultFileStore
    @ObservedObject var keyboardRouter: MimerCanvasKeyboardRouter
    @StateObject private var appendDraft: MimerCanvasAppendDraft
    @State private var selectedLens: MimerLens? = .today
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedNote: MimerCanvasNote?
    @State private var inspectorIsPresented = true
    @State private var focusedColumn: MimerCanvasFocus = .sidebar
    @FocusState private var focusedElement: MimerCanvasFocus?

    init(fileStore: VaultFileStore, keyboardRouter: MimerCanvasKeyboardRouter) {
        self.fileStore = fileStore
        self.keyboardRouter = keyboardRouter
        _appendDraft = StateObject(wrappedValue: MimerCanvasAppendDraft(fileStore: fileStore))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedLens) {
                ForEach(MimerLens.allCases) { lens in
                    Button {
                        selectedLens = lens
                        setFocus(.content)
                    } label: {
                        Label(lens.title, systemImage: lens.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
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
                        focusedElement: $focusedElement,
                        focusFilter: { setFocus(.filter) },
                        appendDraft: appendDraft
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
                note: $selectedNote,
                inspectorIsPresented: inspectorIsPresented,
                fileStore: fileStore,
                appendDraft: appendDraft
            )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mimer.canvas.detail")
                .focusable()
                .focused($focusedElement, equals: .detail)
                .accessibilityValue(focusValue(for: .detail))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(inspectorIsPresented ? "Hide Inspector" : "Show Inspector") {
                    inspectorIsPresented.toggle()
                }
                .accessibilityIdentifier("mimer.canvas.inspector.toggle")
            }
        }
        .onChange(of: focusedElement) { _, element in
            guard let element else { return }
            focusedColumn = element == .filter ? .content : element
        }
        .onChange(of: selectedLens) { oldLens, newLens in
            guard oldLens != newLens else { return }
            selectedNote = nil
            if newLens != .vault, focusedElement == .filter { setFocus(.content) }
        }
        .onReceive(keyboardRouter.$command) { command in
            switch command {
            case .previousColumn:
                moveFocus(forward: false)
            case .nextColumn:
                moveFocus(forward: true)
            case .focusFilter where selectedLens == .vault:
                setFocus(.filter)
            case .focusFilter:
                break
            case .toggleInspector:
                inspectorIsPresented.toggle()
            case nil:
                break
            }
        }
    }

    private func moveFocus(forward: Bool) {
        let targets: [MimerCanvasFocus] = [.sidebar, .content, .detail]
        let currentIndex = targets.firstIndex(of: focusedColumn) ?? 0
        let offset = forward ? 1 : -1
        setFocus(targets[(currentIndex + offset + targets.count) % targets.count])
    }

    private func setFocus(_ target: MimerCanvasFocus) {
        focusedColumn = target == .filter ? .content : target
        focusedElement = target
    }

    private func focusValue(for target: MimerCanvasFocus) -> String {
        focusedColumn == target ? "focused" : "unfocused"
    }
}

private enum MimerCanvasFocus: Hashable {
    case sidebar, content, detail, filter
}

struct MimerCanvasNote: Equatable {
    let relativePath: String
    let text: String
    let modificationDate: Date?
}

/// One ephemeral drag payload representation: its persisted representation is
/// still the markdown link rendered by `promotionBlock`, never app-local state.
struct MimerCanvasPromotion: Hashable, Sendable, Transferable {
    let relativePath: String
    let snippet: String

    private var markdownLink: String {
        let pathWithoutExtension = relativePath.hasSuffix(".md")
            ? String(relativePath.dropLast(3))
            : relativePath
        return "[[\(pathWithoutExtension)]]"
    }

    var plainTextRepresentation: String {
        "\(markdownLink)\n\(snippet)"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { promotion in
            Data(promotion.plainTextRepresentation.utf8)
        }
        DataRepresentation(importedContentType: .plainText) { data in
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let markdownLink = lines.first,
                  markdownLink.hasPrefix("[["),
                  markdownLink.hasSuffix("]]"),
                  markdownLink.count > 4 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return MimerCanvasPromotion(
                relativePath: String(markdownLink.dropFirst(2).dropLast(2)),
                snippet: lines.count == 2 ? String(lines[1]) : ""
            )
        }
    }
}

/// The sole canvas write shape. It deliberately delegates to the existing
/// coordinated store seam; it owns only suffix construction, not conflict or
/// retry policy.
enum MimerCanvasAppend {
    static func annotationBlock(_ text: String) -> String {
        let quotedText = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "> [!note] Annotation\n\(quotedText)\n> — bifrost-ios"
    }

    static func promotionBlock(_ promotion: MimerCanvasPromotion) -> String {
        let snippet = promotion.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathWithoutExtension = promotion.relativePath.hasSuffix(".md")
            ? String(promotion.relativePath.dropLast(3))
            : promotion.relativePath
        return "[[\(pathWithoutExtension)]]\(snippet.isEmpty ? "" : " — \(snippet)")"
    }

    static func appendBlock(
        to relativePath: String,
        block: String,
        using fileStore: VaultFileStore
    ) async throws {
        let normalizedBlock = block.trimmingCharacters(in: .newlines)
        guard !normalizedBlock.isEmpty else { return }

        try await fileStore.readModifyWrite(relativePath) { document in
            let separator: String
            if document.body.isEmpty || document.body.hasSuffix("\n\n") {
                separator = ""
            } else if document.body.hasSuffix("\n") {
                separator = "\n"
            } else {
                separator = "\n\n"
            }
            document.body += "\(separator)\(normalizedBlock)\n"
        }
    }
}

/// In-memory composition and visible failure state for one human-directed
/// append. It is intentionally not a queue: leaving the canvas loses it.
@MainActor
final class MimerCanvasAppendDraft: ObservableObject {
    @Published var annotationText = ""
    @Published private(set) var failureMessage: String?
    @Published private(set) var failureText = ""

    private let fileStore: VaultFileStore
    private var failedPath: String?
    private var failedBlock: String?

    init(fileStore: VaultFileStore) {
        self.fileStore = fileStore
    }

    func submitAnnotation(to relativePath: String) async -> Bool {
        let text = annotationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            failureMessage = "Enter an annotation before saving."
            failureText = annotationText
            return false
        }
        return await submit(
            block: MimerCanvasAppend.annotationBlock(text),
            visibleText: annotationText,
            to: relativePath
        )
    }

    func submitPromotion(_ promotion: MimerCanvasPromotion, to relativePath: String) async -> Bool {
        await submit(
            block: MimerCanvasAppend.promotionBlock(promotion),
            visibleText: promotion.snippet.isEmpty ? promotion.relativePath : promotion.snippet,
            to: relativePath
        )
    }

    func retry() async -> Bool {
        guard let failedPath, let failedBlock else { return false }
        return await submit(block: failedBlock, visibleText: failureText, to: failedPath)
    }

    func copyFailureText() {
        UIPasteboard.general.string = failureText
    }

    private func submit(block: String, visibleText: String, to relativePath: String) async -> Bool {
        do {
            try await MimerCanvasAppend.appendBlock(to: relativePath, block: block, using: fileStore)
            annotationText = ""
            failureMessage = nil
            failureText = ""
            failedPath = nil
            failedBlock = nil
            return true
        } catch {
            failureMessage = "Couldn't save. Your text is still here: \(error.localizedDescription)"
            failureText = visibleText
            failedPath = relativePath
            failedBlock = block
            return false
        }
    }
}

/// Read-only, filesystem-backed Notes column. Its selection is deliberately
/// local SwiftUI state: each folder enumeration is transient and no vault
/// metadata is cached or indexed by the client.
private struct MimerVaultColumnView: View {
    let fileStore: VaultFileStore
    @Binding var selectedNote: MimerCanvasNote?
    let focusedElement: FocusState<MimerCanvasFocus?>.Binding
    let focusFilter: () -> Void
    @ObservedObject var appendDraft: MimerCanvasAppendDraft

    @State private var directory = ""
    @State private var entries: [VaultEntry] = []
    @State private var filter = ""
    @State private var loadError: String?
    @State private var noteSelectionID = UUID()

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
                    invalidateNoteSelection()
                }
                .accessibilityIdentifier("mimer.canvas.vault.back")
            }
            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
            if let failureMessage = appendDraft.failureMessage {
                Section("Append needs attention") {
                    Text(failureMessage).foregroundStyle(.red)
                    if !appendDraft.failureText.isEmpty {
                        Text(appendDraft.failureText).textSelection(.enabled)
                    }
                    HStack {
                        Button("Retry Append") {
                            Task { _ = await appendDraft.retry() }
                        }
                        Button("Copy Pending Text") { appendDraft.copyFailureText() }
                    }
                }
            }
            ForEach(visibleEntries) { entry in
                Button {
                    select(entry)
                } label: {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
                }
                .accessibilityIdentifier("mimer.canvas.vault.entry.\(entry.relativePath)")
                .draggable(MimerCanvasPromotion(relativePath: entry.relativePath, snippet: entry.name))
                .dropDestination(for: MimerCanvasPromotion.self) { promotions, _ in
                    guard !entry.isDirectory, let promotion = promotions.first else { return false }
                    Task {
                        if await appendDraft.submitPromotion(promotion, to: entry.relativePath) {
                            select(entry)
                        }
                    }
                    return true
                }
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
                Button("Filter", action: focusFilter)
            }
        }
        .onAppear(perform: load)
        .onChange(of: directory) { _, _ in load() }
        .onDisappear(perform: invalidatePendingNoteSelection)
    }

    private func select(_ entry: VaultEntry) {
        if entry.isDirectory {
            directory = entry.relativePath
            invalidateNoteSelection()
            return
        }
        let path = entry.relativePath
        let selectionID = UUID()
        noteSelectionID = selectionID
        selectedNote = nil
        loadError = nil
        Task { @MainActor in
            do {
                async let text = fileStore.read(path)
                async let modified = fileStore.modificationDate(of: path)
                let note = try await MimerCanvasNote(
                    relativePath: path,
                    text: text,
                    modificationDate: modified
                )
                guard selectionID == noteSelectionID else { return }
                selectedNote = note
                loadError = nil
            } catch {
                guard selectionID == noteSelectionID else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private func invalidateNoteSelection() { noteSelectionID = UUID(); selectedNote = nil }
    private func invalidatePendingNoteSelection() { noteSelectionID = UUID() }

    private func load() {
        let currentDirectory = directory
        Task { @MainActor in
            do {
                let loadedEntries = try await fileStore.listEntries(in: currentDirectory)
                guard currentDirectory == directory else { return }
                entries = loadedEntries
                loadError = nil
            } catch {
                guard currentDirectory == directory else { return }
                loadError = error.localizedDescription
            }
        }
    }
}

private struct MimerCanvasDetailView: View {
    @Binding var note: MimerCanvasNote?
    let inspectorIsPresented: Bool
    let fileStore: VaultFileStore
    @ObservedObject var appendDraft: MimerCanvasAppendDraft
    @State private var isAnnotationComposerPresented = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if let note {
                    VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
                        HStack {
                            Button("Annotate") { isAnnotationComposerPresented = true }
                                .accessibilityIdentifier("mimer.canvas.annotate")
                            Spacer()
                        }
                        if isAnnotationComposerPresented {
                            TextField("Annotation", text: $appendDraft.annotationText, axis: .vertical)
                                .accessibilityIdentifier("mimer.canvas.annotation.field")
                            Button("Save Annotation") {
                                Task {
                                    if await appendDraft.submitAnnotation(to: note.relativePath) {
                                        isAnnotationComposerPresented = false
                                        await refresh(note)
                                    }
                                }
                            }
                            .accessibilityIdentifier("mimer.canvas.annotation.commit")
                        }
                        if let failureMessage = appendDraft.failureMessage {
                            Text(failureMessage).foregroundStyle(.red)
                            if !appendDraft.failureText.isEmpty {
                                Text(appendDraft.failureText).textSelection(.enabled)
                            }
                            HStack {
                                Button("Retry Append") {
                                    Task {
                                        if await appendDraft.retry() { await refresh(note) }
                                    }
                                }
                                Button("Copy Pending Text") { appendDraft.copyFailureText() }
                            }
                        }
                        ScrollView {
                            MarkdownRendererView(text: note.text)
                                .padding(YggTheme.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("mimer.canvas.detail.document")
                        .accessibilityValue(note.text)
                    }
                    .navigationTitle(note.relativePath.split(separator: "/").last.map(String.init) ?? note.relativePath)
                    .dropDestination(for: MimerCanvasPromotion.self) { promotions, _ in
                        guard let promotion = promotions.first else { return false }
                        Task {
                            if await appendDraft.submitPromotion(promotion, to: note.relativePath) {
                                await refresh(note)
                            }
                        }
                        return true
                    }
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

    private func refresh(_ previousNote: MimerCanvasNote) async {
        do {
            async let text = fileStore.read(previousNote.relativePath)
            async let modificationDate = fileStore.modificationDate(of: previousNote.relativePath)
            note = try await MimerCanvasNote(
                relativePath: previousNote.relativePath,
                text: text,
                modificationDate: modificationDate
            )
        } catch {
            // The append draft already preserves the human's unsaved text only
            // on a failed append. A post-write refresh failure does not create
            // another write path; reopening the note performs the normal read.
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
