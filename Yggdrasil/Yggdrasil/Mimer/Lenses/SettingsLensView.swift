import SwiftUI
import YggdrasilCore

/// A14 lens: the general options + retention window declared in
/// `settings.md`, editable by the human as intent.
struct SettingsLensView: View {
    let fileStore: VaultFileStore

    @State private var retentionDays: Int = 30
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var lastRefreshedAt: Date?
    // Guards against onChange firing save() for the value load() itself just
    // set — without this, opening the tab immediately rewrites settings.md.
    @State private var hasLoaded = false

    var body: some View {
        YggLensScaffold(
            title: "Settings",
            sourcePath: HeimdalPaths.settings,
            isLoading: isLoading,
            loadError: loadError,
            lastRefreshedAt: lastRefreshedAt,
            onRetry: load
        ) {
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
            .onAppear(perform: load)
    }

    private func load() {
        isLoading = true
        defer {
            isLoading = false
            lastRefreshedAt = Date()
        }
        defer { hasLoaded = true }
        do {
            let text = try fileStore.read(HeimdalPaths.settings)
            let note = SettingsNote(document: try FrontmatterDocument.parse(text))
            retentionDays = note.retentionWindowDays ?? 30
            loadError = nil
        } catch VaultFileStoreError.notFound {
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save(retentionDays: Int) {
        do {
            try fileStore.readModifyWrite(HeimdalPaths.settings) { document in
                var note = SettingsNote(document: document)
                note.setRetentionWindowDays(retentionDays)
                document = note.document
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
