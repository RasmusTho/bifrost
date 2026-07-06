import Foundation
import YggdrasilCore

enum VaultFileStoreError: Error, LocalizedError {
    case notFound(String)
    case readFailed(String, Error)
    case writeFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "\(path) doesn't exist in this vault yet."
        case .readFailed(let path, let underlying):
            return "Couldn't read \(path): \(underlying.localizedDescription)"
        case .writeFailed(let path, let underlying):
            return "Couldn't save \(path): \(underlying.localizedDescription)"
        }
    }
}

/// Read/write access to vault-relative files, scoped to the active vault's
/// security-scoped URL. Every `_heimdal/**` lens and the generic markdown
/// renderer go through this one seam.
struct VaultFileStore {
    let rootURL: URL

    func read(_ relativePath: String) throws -> String {
        guard rootURL.startAccessingSecurityScopedResource() else {
            throw VaultFileStoreError.readFailed(relativePath, CocoaError(.fileReadNoPermission))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        return try readFile(relativePath)
    }

    /// Reads several vault-relative files under a single security-scoped
    /// access session, so independent reads (e.g. a lens loading multiple
    /// notes at once) don't each pay for their own start/stop of scoped
    /// access. Each path's outcome is reported independently.
    func readMany(_ relativePaths: [String]) -> [String: Result<String, Error>] {
        guard rootURL.startAccessingSecurityScopedResource() else {
            let joinedPaths = relativePaths.joined(separator: ", ")
            let error = VaultFileStoreError.readFailed(joinedPaths, CocoaError(.fileReadNoPermission))
            return Dictionary(uniqueKeysWithValues: relativePaths.map { ($0, .failure(error)) })
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        var results: [String: Result<String, Error>] = [:]
        for relativePath in relativePaths {
            results[relativePath] = Result { try readFile(relativePath) }
        }
        return results
    }

    private func readFile(_ relativePath: String) throws -> String {
        let url = VaultPath.resolve(relativePath, in: rootURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultFileStoreError.notFound(relativePath)
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw VaultFileStoreError.readFailed(relativePath, error)
        }
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = VaultPath.resolve(relativePath, in: rootURL)
        guard rootURL.startAccessingSecurityScopedResource() else {
            throw VaultFileStoreError.writeFailed(relativePath, CocoaError(.fileWriteNoPermission))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic write: never leave a note half-written for the other
            // writers (Mac runtime, Obsidian) sharing this vault over iCloud.
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw VaultFileStoreError.writeFailed(relativePath, error)
        }
    }

    /// Lists both folders and `.md` files directly inside `relativeDirectory`
    /// (empty string = vault root), for the visual vault browser.
    func listEntries(in relativeDirectory: String) throws -> [VaultEntry] {
        let url = VaultPath.resolve(relativeDirectory, in: rootURL)
        guard rootURL.startAccessingSecurityScopedResource() else {
            throw VaultFileStoreError.readFailed(relativeDirectory, CocoaError(.fileReadNoPermission))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .compactMap { name -> VaultEntry? in
                var isDirectory: ObjCBool = false
                let childURL = url.appendingPathComponent(name)
                let exists = FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDirectory)
                guard exists, isDirectory.boolValue || name.hasSuffix(".md") else { return nil }
                let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
                return VaultEntry(
                    id: relativePath, name: name, relativePath: relativePath, isDirectory: isDirectory.boolValue
                )
            }
    }

    /// Read-merge-write helper: loads the existing note (or starts an empty
    /// one), lets the caller mutate only the fields it owns, then writes the
    /// full document back — so concurrent edits to fields this client
    /// doesn't touch are never lost.
    func readModifyWrite(
        _ relativePath: String,
        mutate: (inout FrontmatterDocument) -> Void
    ) throws {
        var document: FrontmatterDocument
        do {
            let text = try read(relativePath)
            document = try FrontmatterDocument.parse(text)
        } catch VaultFileStoreError.notFound {
            document = FrontmatterDocument(frontmatter: YAMLMap(), body: "")
        }
        mutate(&document)
        try write(document.rendered(), to: relativePath)
    }
}
