import CryptoKit
import Foundation
import YggdrasilCore

enum VaultFileStoreError: Error, LocalizedError {
    case notFound(String)
    case readFailed(String, Error)
    case writeFailed(String, Error)
    case staleWriteContention(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "\(path) doesn't exist in this vault yet."
        case .readFailed(let path, let underlying):
            return "Couldn't read \(path): \(underlying.localizedDescription)"
        case .writeFailed(let path, let underlying):
            return "Couldn't save \(path): \(underlying.localizedDescription)"
        case .staleWriteContention(let path):
            return "Couldn't save \(path) because it kept changing. Please try again."
        }
    }
}

/// App-side seam around Apple's coordinated file access. Keeping this here,
/// rather than in YggdrasilCore, preserves the package's platform-agnostic
/// contract while letting store tests prove coordination from public calls.
protocol VaultFileCoordinating {
    func coordinateRead<T>(at url: URL, accessor: (URL) throws -> T) throws -> T
    func coordinateWrite<T>(at url: URL, accessor: (URL) throws -> T) throws -> T
}

struct NSFileCoordinatorAccess: VaultFileCoordinating {
    func coordinateRead<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try accessor(coordinatedURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw CocoaError(.fileReadUnknown)
        }
        return try result.get()
    }

    func coordinateWrite<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result { try accessor(coordinatedURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try result.get()
    }
}

/// Read/write access to vault-relative files, scoped to the active vault's
/// security-scoped URL. Every `_heimdal/**` lens and the generic markdown
/// renderer go through this one seam.
struct VaultFileStore {
    private enum FileSnapshot {
        case missing
        case contents(String)

        var hash: String? {
            guard case .contents(let text) = self else { return nil }
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private enum WriteResult: Equatable {
        case written
        case stale
    }

    private static let maximumStaleWriteRetries = 3

    let rootURL: URL
    private let coordinator: VaultFileCoordinating
    private let atomicWriter: (String, URL) throws -> Void

    init(
        rootURL: URL,
        coordinator: VaultFileCoordinating = NSFileCoordinatorAccess(),
        atomicWriter: @escaping (String, URL) throws -> Void = { text, url in
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    ) {
        self.rootURL = rootURL
        self.coordinator = coordinator
        self.atomicWriter = atomicWriter
    }

    func read(_ relativePath: String) throws -> String {
        try withReadAccess(relativePath) {
            let snapshot = try readSnapshot(relativePath)
            guard case .contents(let text) = snapshot else {
                throw VaultFileStoreError.notFound(relativePath)
            }
            return text
        }
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
            results[relativePath] = Result {
                let snapshot = try readSnapshot(relativePath)
                guard case .contents(let text) = snapshot else {
                    throw VaultFileStoreError.notFound(relativePath)
                }
                return text
            }
        }
        return results
    }

    func write(_ text: String, to relativePath: String) throws {
        try withWriteAccess(relativePath) {
            let url = VaultPath.resolve(relativePath, in: rootURL)
            try coordinator.coordinateWrite(at: url) { coordinatedURL in
                try prepareParentDirectory(for: coordinatedURL)
                try atomicWriter(text, coordinatedURL)
            }
        }
    }

    /// Lists both folders and `.md` files directly inside `relativeDirectory`
    /// (empty string = vault root), for the visual vault browser.
    func listEntries(in relativeDirectory: String) throws -> [VaultEntry] {
        try withReadAccess(relativeDirectory) {
            let url = VaultPath.resolve(relativeDirectory, in: rootURL)
            return try coordinator.coordinateRead(at: url) { coordinatedURL in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: coordinatedURL.path)) ?? []
                return names
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                    .compactMap { name -> VaultEntry? in
                        var isDirectory: ObjCBool = false
                        let childURL = coordinatedURL.appendingPathComponent(name)
                        let exists = FileManager.default.fileExists(
                            atPath: childURL.path,
                            isDirectory: &isDirectory
                        )
                        guard exists, isDirectory.boolValue || name.hasSuffix(".md") else { return nil }
                        let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
                        return VaultEntry(
                            id: relativePath,
                            name: name,
                            relativePath: relativePath,
                            isDirectory: isDirectory.boolValue
                        )
                    }
            }
        }
    }

    /// Reads, merges, and writes the document while cooperating with iCloud's
    /// coordinator. The hash re-check is advisory (the contract's residual
    /// TOCTOU window remains), but it never emits a version known to be stale.
    func readModifyWrite(
        _ relativePath: String,
        mutate: (inout FrontmatterDocument) -> Void
    ) throws {
        try withWriteAccess(relativePath) {
            let url = VaultPath.resolve(relativePath, in: rootURL)
            for _ in 0..<Self.maximumStaleWriteRetries {
                let snapshot = try readSnapshot(relativePath)
                var document: FrontmatterDocument
                switch snapshot {
                case .missing:
                    document = FrontmatterDocument(frontmatter: YAMLMap(), body: "")
                case .contents(let text):
                    document = try FrontmatterDocument.parse(text)
                }
                mutate(&document)

                let result = try writeIfUnchanged(
                    document.rendered(),
                    relativePath: relativePath,
                    to: url,
                    expectedHash: snapshot.hash
                )
                if result == .written {
                    return
                }
            }
            throw VaultFileStoreError.staleWriteContention(relativePath)
        }
    }

    private func readSnapshot(_ relativePath: String) throws -> FileSnapshot {
        let url = VaultPath.resolve(relativePath, in: rootURL)
        do {
            return try coordinator.coordinateRead(at: url) { coordinatedURL in
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                    return .missing
                }
                return .contents(try String(contentsOf: coordinatedURL, encoding: .utf8))
            }
        } catch {
            throw VaultFileStoreError.readFailed(relativePath, error)
        }
    }

    private func writeIfUnchanged(
        _ text: String,
        relativePath: String,
        to url: URL,
        expectedHash: String?
    ) throws -> WriteResult {
        do {
            return try coordinator.coordinateWrite(at: url) { coordinatedURL in
                let currentSnapshot: FileSnapshot
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    currentSnapshot = .contents(try String(contentsOf: coordinatedURL, encoding: .utf8))
                } else {
                    currentSnapshot = .missing
                }
                guard currentSnapshot.hash == expectedHash else { return .stale }
                try prepareParentDirectory(for: coordinatedURL)
                try atomicWriter(text, coordinatedURL)
                return .written
            }
        } catch {
            throw VaultFileStoreError.writeFailed(relativePath, error)
        }
    }

    private func withReadAccess<T>(_ relativePath: String, body: () throws -> T) throws -> T {
        guard rootURL.startAccessingSecurityScopedResource() else {
            throw VaultFileStoreError.readFailed(relativePath, CocoaError(.fileReadNoPermission))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        return try body()
    }

    private func withWriteAccess<T>(_ relativePath: String, body: () throws -> T) throws -> T {
        guard rootURL.startAccessingSecurityScopedResource() else {
            throw VaultFileStoreError.writeFailed(relativePath, CocoaError(.fileWriteNoPermission))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        return try body()
    }

    private func prepareParentDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
