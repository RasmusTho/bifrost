import SwiftUI
import YggdrasilCore

/// A14 lens: the general options + retention window declared in
/// `settings.md`, editable by the human as intent.
struct SettingsLensView: View {
    let fileStore: VaultFileStore

    @State private var retentionDays: Int = 30
    @State private var loadError: String?
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
                            guard hasLoaded else { return }
                            save(retentionDays: newValue)
                        }
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
        Task { @MainActor in
            defer { hasLoaded = true }
            do {
                let text = try await fileStore.read(HeimdalPaths.settings)
                let note = SettingsNote(document: try FrontmatterDocument.parse(text))
                retentionDays = note.retentionWindowDays ?? 30
                loadError = nil
            } catch VaultFileStoreError.notFound(_) {
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func save(retentionDays: Int) {
        Task { @MainActor in
            do {
                try await fileStore.readModifyWrite(HeimdalPaths.settings) { document in
                    var note = SettingsNote(document: document)
                    note.setRetentionWindowDays(retentionDays)
                    document = note.document
                }
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
