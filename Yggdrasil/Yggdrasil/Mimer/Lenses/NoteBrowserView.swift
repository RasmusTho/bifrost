import SwiftUI

struct VaultEntry: Identifiable {
    let id: String
    let name: String
    let relativePath: String
    let isDirectory: Bool
}

/// Generic vault browser: drills into any folder (starting at the vault
/// root) and opens any `.md` file in the read/write renderer. This is the
/// "renders `_heimdal/**` notes read/write" path made visual, not limited to
/// the five hardcoded lenses above.
struct NoteBrowserView: View {
    let fileStore: VaultFileStore
    var relativeDirectory: String = ""

    @State private var entries: [VaultEntry] = []
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink(entry.name) {
                        NoteBrowserView(fileStore: fileStore, relativeDirectory: entry.relativePath)
                    }
                } else {
                    NavigationLink(entry.name) {
                        NoteDetailView(relativePath: entry.relativePath, fileStore: fileStore)
                    }
                }
            }
            if entries.isEmpty && loadError == nil {
                Text("No files here yet.").foregroundStyle(YggTheme.Color.textSecondary)
            }
        }
        .navigationTitle(navigationTitle)
        .onAppear(perform: load)
    }

    private var navigationTitle: String {
        guard !relativeDirectory.isEmpty else { return "Vault" }
        return relativeDirectory.split(separator: "/").last.map(String.init) ?? "Folder"
    }

    private func load() {
        Task { @MainActor in
            do {
                entries = try await fileStore.listEntries(in: relativeDirectory)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
