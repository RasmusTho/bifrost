import SwiftUI
import YggdrasilCore

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
    @State private var isLoading = true
    @State private var lastRefreshedAt: Date?

    var body: some View {
        YggLensScaffold(
            title: navigationTitle,
            sourcePath: relativeDirectory.isEmpty ? HeimdalPaths.root : relativeDirectory,
            isLoading: isLoading,
            loadError: loadError,
            lastRefreshedAt: lastRefreshedAt,
            onRetry: load,
            wrapsNavigationStack: false
        ) {
                Section {
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
                    if entries.isEmpty {
                        YggEmptyState(
                            systemImage: "folder",
                            title: "Nothing here yet",
                            message: "Markdown files and folders will appear here."
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .onAppear(perform: load)
    }

    private var navigationTitle: String {
        guard !relativeDirectory.isEmpty else { return "Vault" }
        return relativeDirectory.split(separator: "/").last.map(String.init) ?? "Folder"
    }

    private func load() {
        isLoading = true
        defer {
            isLoading = false
            lastRefreshedAt = Date()
        }
        do {
            entries = try fileStore.listEntries(in: relativeDirectory)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
