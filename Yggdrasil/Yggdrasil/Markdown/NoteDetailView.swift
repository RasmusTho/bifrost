import SwiftUI

/// Generic read/write `.md` surface: renders a note, and — the constraint
/// this shell exists to serve — lets the human edit the raw markdown and
/// save it straight back to the vault. Every capability is a note edit, so
/// this view alone (with no `_heimdal`-specific code) already satisfies
/// "renders vault notes read/write."
struct NoteDetailView: View {
    let relativePath: String
    let fileStore: VaultFileStore
    /// Heading/block anchor from the link that opened this note.
    var anchor: String?

    @State private var rawText: String = ""
    @State private var isEditing = false
    @State private var loadError: String?
    @State private var isSaving = false

    @State private var linkedNote: VaultNoteLink?
    @State private var localAnchor: String?

    var body: some View {
        Group {
            if isEditing {
                ScrollView {
                    VStack(alignment: .leading, spacing: YggTheme.Spacing.md) {
                        errorText
                        TextEditor(text: $rawText)
                            .accessibilityIdentifier("yggdrasil.noteEditor")
                            .font(YggTheme.Typography.monospaceBody)
                            .frame(minHeight: 320)
                            .padding(YggTheme.Spacing.xs)
                            .background(YggTheme.Color.tertiaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
                    }
                    .padding(YggTheme.Spacing.md)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    errorText
                        .padding(.horizontal, YggTheme.Spacing.md)
                    NoteWebView(
                        markdown: rawText,
                        notePath: relativePath,
                        fileStore: fileStore,
                        anchor: localAnchor ?? anchor,
                        onOpenNote: { path, anchor in
                            if path == relativePath {
                                localAnchor = anchor
                            } else {
                                linkedNote = VaultNoteLink(path: path, anchor: anchor)
                            }
                        }
                    )
                }
            }
        }
        .navigationDestination(item: $linkedNote) { link in
            NoteDetailView(relativePath: link.path, fileStore: fileStore, anchor: link.anchor)
        }
        .yggPage()
        .navigationTitle(relativePath.split(separator: "/").last.map(String.init) ?? relativePath)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving)
                } else {
                    // Disabled on a failed load: rawText wouldn't reflect the
                    // real note, and editing it would overwrite the note with
                    // stale/empty content on save.
                    Button("Edit") { isEditing = true }
                        .disabled(loadError != nil)
                }
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var errorText: some View {
        if let loadError {
            Text(loadError)
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.destructive)
        }
    }

    private func load() {
        let path = relativePath
        Task { @MainActor in
            do {
                rawText = try await fileStore.read(path)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func save() {
        let path = relativePath
        let text = rawText
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await fileStore.write(text, to: path)
                isEditing = false
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

/// A followed link: the target note and the heading/block it points into.
struct VaultNoteLink: Hashable {
    let path: String
    let anchor: String?
}
