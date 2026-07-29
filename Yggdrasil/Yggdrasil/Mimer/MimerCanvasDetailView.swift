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
                        }
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
                            Text(failureMessage).foregroundStyle(.red)
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
        .onChange(of: note?.relativePath) { _, _ in
            detailCoordinator.selectionChanged()
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
