import Foundation
import SwiftUI

struct ResolvedCaptureFolder {
    let url: URL
    let isStale: Bool
}

/// Owns the iCloud-visible watched-folder binding. This is deliberately
/// separate from `VaultManager`: choosing a capture folder never grants the
/// app authority to write into the operator's vault.
@MainActor
final class CaptureFolderManager: ObservableObject {
    static let bookmarkDefaultsKey = "yggdrasil.captureFolder"

    @Published private(set) var boundFolderURL: URL?
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private let resolveBookmark: (Data) throws -> ResolvedCaptureFolder
    private let makeBookmark: (URL) throws -> Data
    private let beginSecurityScope: (URL) -> Bool
    private let endSecurityScope: (URL) -> Void

    init(
        defaults: UserDefaults = .standard,
        resolveBookmark: @escaping (Data) throws -> ResolvedCaptureFolder = CaptureFolderManager.resolve,
        makeBookmark: @escaping (URL) throws -> Data = CaptureFolderManager.makeBookmark,
        beginSecurityScope: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        endSecurityScope: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.defaults = defaults
        self.resolveBookmark = resolveBookmark
        self.makeBookmark = makeBookmark
        self.beginSecurityScope = beginSecurityScope
        self.endSecurityScope = endSecurityScope
        restoreBinding()
    }

    var isBound: Bool { boundFolderURL != nil }

    func bind(folderURL: URL) {
        guard beginSecurityScope(folderURL) else {
            lastError = "Couldn't access the selected capture folder. Try picking it again."
            return
        }
        defer { endSecurityScope(folderURL) }

        do {
            defaults.set(try makeBookmark(folderURL), forKey: Self.bookmarkDefaultsKey)
            boundFolderURL = folderURL
            lastError = nil
        } catch {
            lastError = "Couldn't remember this capture folder: \(error.localizedDescription)"
        }
    }

    func restoreBinding() {
        guard let bookmark = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return }
        do {
            let resolved = try resolveBookmark(bookmark)
            boundFolderURL = resolved.url
            lastError = nil
            if resolved.isStale {
                refreshBookmark(for: resolved.url)
            }
        } catch {
            boundFolderURL = nil
            lastError = "This capture folder is no longer reachable. Pick it again from Files."
        }
    }

    private func refreshBookmark(for folderURL: URL) {
        guard beginSecurityScope(folderURL) else { return }
        defer { endSecurityScope(folderURL) }
        guard let bookmark = try? makeBookmark(folderURL) else { return }
        defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
    }

    nonisolated private static func resolve(bookmark: Data) throws -> ResolvedCaptureFolder {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedCaptureFolder(url: url, isStale: isStale)
    }

    nonisolated private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
