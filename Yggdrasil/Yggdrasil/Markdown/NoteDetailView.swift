import SwiftUI

/// Generic read/write `.md` surface: renders a note, and — the constraint
/// this shell exists to serve — lets the human edit the raw markdown and
/// save it straight back to the vault. Every capability is a note edit, so
/// this view alone (with no `_heimdal`-specific code) already satisfies
/// "renders vault notes read/write."
struct NoteDetailView: View {
    let relativePath: String
    let fileStore: VaultFileStore

    @State private var rawText: String = ""
    @State private var isEditing = false
    @State private var loadError: String?
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YggTheme.Spacing.md) {
                if let loadError {
                    Text(loadError)
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(.red)
                }
                if isEditing {
                    TextEditor(text: $rawText)
                        .font(YggTheme.Typography.monospaceBody)
                        .frame(minHeight: 320)
                        .padding(YggTheme.Spacing.xs)
                        .background(YggTheme.Color.tertiaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
                } else {
                    MarkdownRendererView(text: rawText)
                }
            }
            .padding(YggTheme.Spacing.md)
        }
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

    private func load() {
        do {
            rawText = try fileStore.read(relativePath)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        isSaving = true
        do {
            try fileStore.write(rawText, to: relativePath)
            isEditing = false
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isSaving = false
    }
}
