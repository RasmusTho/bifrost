import SwiftUI
import YggdrasilCore

/// A14 lens: the general options + retention window declared in
/// `settings.md`, editable by the human as intent.
struct SettingsLensView: View {
    let fileStore: VaultFileStore

    @State private var retentionDays: Int = 30
    @State private var loadError: String?
    @State private var savedRetentionDays = 30
    @State private var canEditSettings = false
    @State private var isSaving = false
    // Guards against onChange firing save() for the value load() itself just
    // set — without this, opening the tab immediately rewrites settings.md.
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
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
                    NavigationLink("Browse settings.md") {
                        NoteDetailView(relativePath: HeimdalPaths.settings, fileStore: fileStore)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: load)
        }
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
                retentionDays = note.retentionWindowDays ?? 30
                savedRetentionDays = retentionDays
                canEditSettings = true
                hasLoaded = true
                loadError = nil
            } catch VaultFileStoreError.notFound(_) {
                // A vault without settings.md uses defaults; its first edit
                // creates the note through readModifyWrite.
                canEditSettings = true
                hasLoaded = true
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
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
