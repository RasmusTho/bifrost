import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import YggdrasilCore

/// Owns the currently open vault and the small set of vaults the user has
/// previously picked (folder bookmarks only — never a typed path). Vault
/// selection is always a visual pick through `UIDocumentPickerViewController`.
@MainActor
final class VaultManager: ObservableObject {
    @Published private(set) var recentVaults: [VaultReference] = []
    @Published private(set) var activeVaultURL: URL?
    @Published private(set) var activeVaultReference: VaultReference?
    @Published var lastError: String?

    private let defaultsKey = "yggdrasil.recentVaults"

    init() {
        loadRecents()
    }

    func openVault(at url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "Couldn't access the selected folder. Try picking it again."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let reference = VaultReference(
                displayName: url.lastPathComponent,
                bookmarkData: bookmark,
                lastOpenedAt: Date(),
                resolvedPath: url.standardizedFileURL.path
            )
            // Dedup by resolved path, not display name — two different
            // folders can share a leaf name (e.g. two "Notes" folders under
            // different iCloud locations) without being the same vault.
            var updated = recentVaults.filter { $0.resolvedPath != reference.resolvedPath }
            updated.insert(reference, at: 0)
            recentVaults = Array(updated.prefix(8))
            persistRecents()
            activate(reference)
        } catch {
            lastError = "Couldn't remember this vault: \(error.localizedDescription)"
        }
    }

    func activate(_ reference: VaultReference) {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: reference.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            activeVaultURL = url
            activeVaultReference = reference
            lastError = nil
            if isStale {
                refreshBookmark(for: reference, resolvedURL: url)
            }
        } catch {
            lastError = "This vault is no longer reachable. Pick it again from Files."
        }
    }

    /// Re-mints and re-persists a bookmark that resolved successfully but was
    /// reported stale (e.g. the vault folder moved under iCloud sync), so the
    /// app keeps working across launches instead of silently drifting toward
    /// a bookmark that eventually fails to resolve at all.
    private func refreshBookmark(for reference: VaultReference, resolvedURL: URL) {
        guard resolvedURL.startAccessingSecurityScopedResource() else { return }
        defer { resolvedURL.stopAccessingSecurityScopedResource() }
        guard let freshBookmark = try? resolvedURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return }
        let refreshed = VaultReference(
            id: reference.id,
            displayName: resolvedURL.lastPathComponent,
            bookmarkData: freshBookmark,
            lastOpenedAt: reference.lastOpenedAt,
            resolvedPath: resolvedURL.standardizedFileURL.path
        )
        if let index = recentVaults.firstIndex(where: { $0.id == reference.id }) {
            recentVaults[index] = refreshed
            persistRecents()
        }
        activeVaultReference = refreshed
    }

    func closeVault() {
        activeVaultURL = nil
        activeVaultReference = nil
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([VaultReference].self, from: data) else { return }
        recentVaults = decoded
    }

    private func persistRecents() {
        guard let data = try? JSONEncoder().encode(recentVaults) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Wraps `UIDocumentPickerViewController` in directory-pick mode — the only
/// vault-selection affordance the shell offers. No path text field anywhere.
struct VaultFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
