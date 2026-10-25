import SwiftUI

/// The detail column of the iPad thinking canvas: renders the selected note
/// and hosts the annotate/promote append affordances. Split out of
/// MimerShellView.swift to keep that file within its length budget.
struct MimerCanvasDetailView: View {
    @Binding var note: MimerCanvasNote?
    let inspectorIsPresented: Bool
    let fileStore: VaultFileStore
    @ObservedObject var appendDraft: MimerCanvasAppendDraft
    @StateObject private var detailCoordinator: MimerCanvasDetailCoordinator
    @State private var isAnnotationComposerPresented = false
    /// The heading/block a followed link points into, for the note it opened.
    @State private var linkedAnchor: VaultNoteLink?
    @State private var linkedNoteLoadToken = UUID()

    init(
        note: Binding<MimerCanvasNote?>,
        inspectorIsPresented: Bool,
        fileStore: VaultFileStore,
        appendDraft: MimerCanvasAppendDraft
    ) {
        _note = note
        self.inspectorIsPresented = inspectorIsPresented
        self.fileStore = fileStore
        self.appendDraft = appendDraft
        _detailCoordinator = StateObject(wrappedValue: MimerCanvasDetailCoordinator(fileStore: fileStore))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if let note {
                    VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
                        HStack {
                            Button("Annotate") {
                                detailCoordinator.beginAnnotationComposition(for: note.relativePath)
                                isAnnotationComposerPresented = true
                            }
                                .accessibilityIdentifier("mimer.canvas.annotate")
                            Spacer()
                            MimerReadAloudControls(text: note.text)
                        }
                        .padding(.horizontal, YggTheme.Spacing.md)
                        if isAnnotationComposerPresented {
                            TextField("Annotation", text: $appendDraft.annotationText, axis: .vertical)
                                .accessibilityIdentifier("mimer.canvas.annotation.field")
                            Button("Save Annotation") {
                                // Always commits to the note the composer was
                                // opened against, not to whatever note
                                // happens to be selected now (INV-B2-3).
                                guard let targetPath = detailCoordinator.composedAnnotationPath else { return }
                                Task {
                                    if await appendDraft.submitAnnotation(to: targetPath) {
                                        isAnnotationComposerPresented = false
                                        detailCoordinator.annotationCompositionCommitted()
                                        await refreshAfterAppend(path: targetPath)
                                    }
                                }
                            }
                            .accessibilityIdentifier("mimer.canvas.annotation.commit")
                        }
                        if let failureMessage = appendDraft.failureMessage {
                            Text(failureMessage).foregroundStyle(YggTheme.Color.destructive)
                            if !appendDraft.failureText.isEmpty {
                                Text(appendDraft.failureText).textSelection(.enabled)
                            }
                            HStack {
                                Button("Retry Append") {
                                    let retryPath = note.relativePath
                                    Task {
                                        if await appendDraft.retry() {
                                            await refreshAfterAppend(path: retryPath)
                                        }
                                    }
                                }
                                Button("Copy Pending Text") { appendDraft.copyFailureText() }
                            }
                        }
                        NoteWebView(
                            markdown: note.text,
                            notePath: note.relativePath,
                            fileStore: fileStore,
                            anchor: linkedAnchor?.path == note.relativePath ? linkedAnchor?.anchor : nil,
                            onOpenNote: { path, anchor in openLinkedNote(path, anchor: anchor) },
                            onDrop: { providers in
                                acceptDroppedPromotion(providers, onto: note.relativePath)
                            }
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("mimer.canvas.detail.document")
                        .accessibilityValue(note.text)
                    }
                    .yggPage()
                    .navigationTitle(note.relativePath.split(separator: "/").last.map(String.init) ?? note.relativePath)
                    // Inline: a long note name would otherwise run as a large
                    // title across the inspector column. The note's own H1
                    // is the reading heading.
                    .navigationBarTitleDisplayMode(.inline)
                    .dropDestination(for: MimerCanvasPromotion.self) { promotions, _ in
                        guard let promotion = promotions.first else { return false }
                        let targetPath = note.relativePath
                        Task {
                            if await appendDraft.submitPromotion(promotion, to: targetPath) {
                                await refreshAfterAppend(path: targetPath)
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
            .yggPage()
            if inspectorIsPresented {
                MimerNoteInspectorView(
                    model: NoteInspectorModel(
                        text: note?.text ?? "",
                        modificationDate: note?.modificationDate
                    )
                )
                    .frame(width: 260)
                    .accessibilityIdentifier("mimer.canvas.inspector")
            }
        }
        .onChange(of: note?.relativePath) { _, _ in
            linkedNoteLoadToken = UUID()
            detailCoordinator.selectionChanged()
        }
    }

    /// Drag-promote onto the rendered note (the web reading surface hands its
    /// drops here; `dropDestination` covers the rest of the note container).
    private func acceptDroppedPromotion(_ providers: [NSItemProvider], onto targetPath: String) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadTransferable(type: MimerCanvasPromotion.self) { result in
            guard case .success(let promotion) = result else { return }
            Task { @MainActor in
                if await appendDraft.submitPromotion(promotion, to: targetPath) {
                    await refreshAfterAppend(path: targetPath)
                }
            }
        }
        return true
    }

    /// Follows a `[[wikilink]]` from the rendered note: the linked note
    /// becomes the canvas selection, exactly as if picked in the Vault column.
    private func openLinkedNote(_ path: String, anchor: String?) {
        linkedAnchor = VaultNoteLink(path: path, anchor: anchor)
        let loadToken = UUID()
        linkedNoteLoadToken = loadToken
        guard path != note?.relativePath else { return }
        Task { @MainActor in
            async let text = fileStore.read(path)
            async let modified = fileStore.modificationDate(of: path)
            guard let linked = try? await MimerCanvasNote(
                relativePath: path,
                text: text,
                modificationDate: modified
            ) else { return }
            guard linkedNoteLoadToken == loadToken else { return }
            note = linked
        }
    }

    private func refreshAfterAppend(path: String) async {
        await detailCoordinator.refresh(
            path: path,
            currentSelectedPath: { self.note?.relativePath },
            applyRefreshedNote: { refreshed in note = refreshed }
        )
    }
}
