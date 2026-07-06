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
                lastOpenedAt: Date()
            )
            var updated = recentVaults.filter { $0.displayName != reference.displayName }
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
        } catch {
            lastError = "This vault is no longer reachable. Pick it again from Files."
        }
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
