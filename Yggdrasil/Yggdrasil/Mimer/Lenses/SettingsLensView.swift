import SwiftUI
import YggdrasilCore

/// A14 lens: the general options + retention window declared in
/// `settings.md`, editable by the human as intent.
struct SettingsLensView: View {
    let fileStore: VaultFileStore
    let usesCanvasNavigation: Bool

    @State private var retentionDays: Int = 30
    @State private var loadError: String?
    @State private var savedRetentionDays = 30
    @State private var canEditSettings = false
    @State private var isSaving = false
    @State private var isSettingsNotePresented = false
    @State private var settingsText = ""
    @State private var settingsNoteError: String?
    // Guards against onChange firing save() for the value load() itself just
    // set — without this, opening the tab immediately rewrites settings.md.
    @State private var hasLoaded = false

    init(fileStore: VaultFileStore, usesCanvasNavigation: Bool = false) {
        self.fileStore = fileStore
        self.usesCanvasNavigation = usesCanvasNavigation
    }

    var body: some View {
        Group {
            // The iPad canvas already supplies column navigation through its
            // NavigationSplitView. A nested stack leaves the split view with
            // stale navigation state after opening settings.md, so subsequent
            // vault selections can stop updating the detail column. The canvas
            // flag is explicit because a split-view content column can report
            // a compact local size class even when the iPad is regular-width.
            if usesCanvasNavigation {
                if isSettingsNotePresented {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Back to Settings") {
                                isSettingsNotePresented = false
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        ScrollView {
                            VStack(alignment: .leading, spacing: YggTheme.Spacing.md) {
                                if let settingsNoteError {
                                    Text(settingsNoteError)
                                        .font(YggTheme.Typography.caption)
                                        .foregroundStyle(.red)
                                }
                                MarkdownRendererView(text: settingsText)
                            }
                            .padding(YggTheme.Spacing.md)
                        }
                        .task { await loadSettingsText() }
                    }
                } else {
                    settingsForm
                }
            } else {
                NavigationStack {
                    settingsForm
                }
            }
        }
    }

    private var settingsForm: some View {
        Form {
            LensScaffold.errorBanner(loadError)
            Section("Retention") {
                Stepper("Retention window: \(retentionDays) days", value: $retentionDays, in: 1...365)
                    .onChange(of: retentionDays) { _, newValue in
                        guard hasLoaded, canEditSettings, !isSaving else { return }
                        save(retentionDays: newValue)
                    }
                    .disabled(!canEditSettings || isSaving)
            }
            Section("Vault") {
                if usesCanvasNavigation {
                    Button("Browse settings.md") {
                        isSettingsNotePresented = true
                    }
                } else {
                    NavigationLink("Browse settings.md") {
                        NoteDetailView(relativePath: HeimdalPaths.settings, fileStore: fileStore)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear(perform: load)
    }

    private func load() {
        retentionDays = 30
        savedRetentionDays = 30
        hasLoaded = false
        canEditSettings = false
        loadError = nil
        let path = HeimdalPaths.settings
        Task { @MainActor in
            do {
                let text = try await fileStore.read(path)
                let note = SettingsNote(document: try FrontmatterDocument.parse(text))
                settingsText = text
                retentionDays = note.retentionWindowDays ?? 30
                savedRetentionDays = retentionDays
                canEditSettings = true
                hasLoaded = true
                loadError = nil
            } catch VaultFileStoreError.notFound(_) {
                // A vault without settings.md uses defaults; its first edit
                // creates the note through readModifyWrite.
                settingsText = ""
                canEditSettings = true
                hasLoaded = true
                loadError = nil
            } catch {
                settingsText = ""
                loadError = error.localizedDescription
            }
        }
    }

    private func loadSettingsText() async {
        do {
            settingsText = try await fileStore.read(HeimdalPaths.settings)
            settingsNoteError = nil
        } catch {
            settingsNoteError = error.localizedDescription
        }
    }

    private func save(retentionDays: Int) {
        let path = HeimdalPaths.settings
        let days = retentionDays
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await fileStore.readModifyWrite(path) { document in
                    var note = SettingsNote(document: document)
                    note.setRetentionWindowDays(days)
                    document = note.document
                }
                savedRetentionDays = days
                loadError = nil
            } catch {
                loadError = error.localizedDescription
                canEditSettings = false
                self.retentionDays = savedRetentionDays
            }
        }
    }
}
