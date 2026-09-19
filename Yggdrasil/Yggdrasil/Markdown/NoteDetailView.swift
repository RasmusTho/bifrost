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
    @State private var originalText: String = ""
    @State private var isEditing = false
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var isLoading = true
    @State private var saveMessage: String?
    @State private var showDiscardConfirmation = false

    private var isDirty: Bool { rawText != originalText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YggTheme.Spacing.md) {
                if let loadError {
                    YggBanner(
                        title: "Vault unreachable",
                        message: loadError,
                        kind: .destructive,
                        retry: load
                    )
                } else if isLoading {
                    ProgressView("Loading note…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isEditing {
                    HStack {
                        if isDirty {
                            YggStatusPill(title: "Edited", systemImage: "circle.fill", kind: .pending)
                        }
                        Spacer()
                    }
                    TextEditor(text: $rawText)
                        .font(YggTheme.Typography.monospaceBody)
                        .frame(minHeight: 320)
                        .padding(YggTheme.Spacing.xs)
                        .background(YggTheme.Color.tertiaryBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous)
                                .stroke(YggTheme.Color.divider, lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
                } else {
                    MarkdownRendererView(text: rawText)
                }
                if let saveMessage {
                    YggStatusPill(title: saveMessage, systemImage: "checkmark.circle", kind: .healthy)
                }
                YggSourceFooter(path: relativePath)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, YggTheme.Spacing.lg)
            .padding(.vertical, YggTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(YggTheme.Color.background)
        .navigationTitle(relativePath.split(separator: "/").last.map(String.init) ?? relativePath)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing {
                    Button("Cancel") { cancelEditing() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving || !isDirty)
                } else {
                    // Disabled on a failed load: rawText wouldn't reflect the
                    // real note, and editing it would overwrite the note with
                    // stale/empty content on save.
                    Button("Edit") { isEditing = true }
                        .disabled(loadError != nil)
                }
            }
        }
        .confirmationDialog(
            "Discard your edits?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive) {
                rawText = originalText
                isEditing = false
                saveMessage = nil
            }
            Button("Keep editing", role: .cancel) { }
        }
        .onAppear(perform: load)
        .onChange(of: relativePath) { _, _ in load() }
    }

    private func load() {
        isLoading = true
        do {
            rawText = try fileStore.read(relativePath)
            originalText = rawText
            loadError = nil
            saveMessage = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func cancelEditing() {
        if isDirty {
            showDiscardConfirmation = true
        } else {
            isEditing = false
        }
    }

    private func save() {
        guard isDirty else { return }
        isSaving = true
        do {
            try fileStore.write(rawText, to: relativePath)
            originalText = rawText
            isEditing = false
            loadError = nil
            saveMessage = "Saved to the vault"
        } catch {
            loadError = error.localizedDescription
        }
        isSaving = false
    }
}
