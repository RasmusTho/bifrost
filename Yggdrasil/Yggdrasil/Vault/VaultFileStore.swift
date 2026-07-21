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
protocol VaultFileCoordinating: Sendable {
    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T
    func coordinateWrite<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T
}

struct NSFileCoordinatorAccess: VaultFileCoordinating {
    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
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

    func coordinateWrite<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
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

private enum VaultWriteProvenance {
    typealias TimestampProvider = @Sendable () throws -> String

    private enum InjectionError: LocalizedError {
        case unsafeFrontmatter

        var errorDescription: String? {
            "The note frontmatter could not be tagged without changing foreign YAML."
        }
    }

    static func applying(
        to text: String,
        relativePath: String,
        timestampProvider: TimestampProvider,
        failureLogger: @Sendable (String) -> Void
    ) -> String {
        do {
            return try injecting(into: text, writtenAt: timestampProvider())
        } catch {
            logFailure(error, relativePath: relativePath, failureLogger: failureLogger)
            return text
        }
    }

    private static func injecting(into text: String, writtenAt: String) throws -> String {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        let provenanceLines = [
            "agent_provenance:",
            "  author: bifrost-ios",
            "  written_at: \(writtenAt)",
            "  origin: direct-fs"
        ]

        guard text.hasPrefix("---\(newline)") else {
            return (["---"] + provenanceLines + ["---", "", text]).joined(separator: newline)
        }

        var lines = text.components(separatedBy: newline)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw InjectionError.unsafeFrontmatter
        }

        let candidates = lines[1..<closingIndex].indices.filter { index in
            let line = lines[index]
            guard line.first?.isWhitespace != true else { return false }
            return line.contains("agent_provenance")
        }
        guard candidates.count <= 1 else { throw InjectionError.unsafeFrontmatter }

        if let startIndex = candidates.first {
            guard lines[startIndex].hasPrefix("agent_provenance:") else {
                throw InjectionError.unsafeFrontmatter
            }
            let remainder = lines[startIndex].dropFirst("agent_provenance:".count)
                .trimmingCharacters(in: .whitespaces)
            guard remainder.isEmpty else {
                throw InjectionError.unsafeFrontmatter
            }
            let endIndex = try replacementEnd(in: lines, after: startIndex, before: closingIndex)
            lines.replaceSubrange(startIndex..<endIndex, with: provenanceLines)
        } else {
            try insert(provenanceLines, into: &lines, before: closingIndex)
        }
        return lines.joined(separator: newline)
    }
    private static func replacementEnd(in lines: [String], after start: Int, before closing: Int) throws -> Int {
        var end = start + 1
        while end < closing {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                throw InjectionError.unsafeFrontmatter
            }
            if line.first?.isWhitespace == true {
                end += 1
                continue
            }
            guard trimmed != "-", !trimmed.hasPrefix("- ") else {
                throw InjectionError.unsafeFrontmatter
            }
            break
        }
        return end
    }

    private static func insert(_ provenance: [String], into lines: inout [String], before closingIndex: Int) throws {
        guard acceptsBlockMappingInsertion(lines[1..<closingIndex]) else {
            throw InjectionError.unsafeFrontmatter
        }
        lines.insert(contentsOf: provenance, at: closingIndex)
    }

    private static func acceptsBlockMappingInsertion(_ lines: ArraySlice<String>) -> Bool {
        var sawMappingEntry = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true {
                guard sawMappingEntry else { return false }
                continue
            }
            guard isPlainBlockMappingEntry(line) else { return false }
            sawMappingEntry = true
        }
        return true
    }

    private static func isPlainBlockMappingEntry(_ line: String) -> Bool {
        guard let separator = line.indices.first(where: { index in
            guard line[index] == ":", index != line.startIndex, !line.hasPrefix("- ") else { return false }
            let next = line.index(after: index)
            return next == line.endIndex || line[next].isWhitespace
        }) else { return false }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && key.allSatisfy { character in
            character.isLetter || character.isNumber || character.isWhitespace || "_-.".contains(character)
        }
    }

    @discardableResult
    static func apply(
        to document: inout FrontmatterDocument,
        relativePath: String,
        timestampProvider: TimestampProvider,
        failureLogger: @Sendable (String) -> Void
    ) -> Bool {
        do {
            document.applyBifrostProvenance(writtenAt: try timestampProvider())
            return true
        } catch {
            logFailure(error, relativePath: relativePath, failureLogger: failureLogger)
            return false
        }
    }

    private static func logFailure(
        _ error: Error,
        relativePath: String,
        failureLogger: @Sendable (String) -> Void
    ) {
        let message = "Bifrost provenance tagging failed for \(relativePath); "
            + "writing note without provenance: \(error.localizedDescription)"
        failureLogger(message)
    }
}

/// Read/write access to vault-relative files, scoped to the active vault's
/// security-scoped URL. Every `_heimdal/**` lens and the generic markdown
/// renderer go through this one seam.
struct VaultFileStore: Sendable {
    private enum FileSnapshot: Sendable {
        case missing
        case contents(String)

        var hash: String? {
            guard case .contents(let text) = self else { return nil }
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private enum WriteResult: Equatable, Sendable {
        case written
        case stale
    }

    private static let maximumStaleWriteRetries = 3
    private static let ioQueue = DispatchQueue(label: "com.rasmustho.bifrost.vault-file-store")

    let rootURL: URL
    private let coordinator: VaultFileCoordinating
    private let provenanceTimestampProvider: @Sendable () throws -> String
    private let provenanceFailureLogger: @Sendable (String) -> Void

    init(
        rootURL: URL,
        coordinator: VaultFileCoordinating = NSFileCoordinatorAccess(),
        provenanceTimestampProvider: @escaping @Sendable () throws -> String = { Date().ISO8601Format() },
        provenanceFailureLogger: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.rootURL = rootURL
        self.coordinator = coordinator
        self.provenanceTimestampProvider = provenanceTimestampProvider
        self.provenanceFailureLogger = provenanceFailureLogger
    }

    /// Public vault I/O never runs on SwiftUI's main actor. Security-scoped
    /// access starts and stops on the same serial executor as coordination.
    func read(_ relativePath: String) async throws -> String {
        try await performIO {
            try withReadAccess(relativePath) {
                let snapshot = try readSnapshot(relativePath)
                guard case .contents(let text) = snapshot else {
                    throw VaultFileStoreError.notFound(relativePath)
                }
                return text
            }
        }
    }

    /// Reads several vault-relative files under a single security-scoped
    /// access session, so independent reads (e.g. a lens loading multiple
    /// notes at once) don't each pay for their own start/stop of scoped
    /// access. Each path's outcome is reported independently.
    func readMany(_ relativePaths: [String]) async -> [String: Result<String, Error>] {
        await performIO {
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
    }

    func write(_ text: String, to relativePath: String) async throws {
        try await performIO {
            try withWriteAccess(relativePath) {
                let url = VaultPath.resolve(relativePath, in: rootURL)
                try coordinator.coordinateWrite(at: url) { coordinatedURL in
                    try prepareParentDirectory(for: coordinatedURL)
                    let taggedText = VaultWriteProvenance.applying(
                        to: text,
                        relativePath: relativePath,
                        timestampProvider: provenanceTimestampProvider,
                        failureLogger: provenanceFailureLogger
                    )
                    try Self.atomicReplace(taggedText, at: coordinatedURL)
                }
            }
        }
    }

    /// Lists both folders and `.md` files directly inside `relativeDirectory`
    /// (empty string = vault root), for the visual vault browser.
    func listEntries(in relativeDirectory: String) async throws -> [VaultEntry] {
        try await performIO {
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
    }

    /// Returns the file-system modification date for a vault-relative note.
    /// This is deliberately an on-demand read, not a client-side index.
    func modificationDate(of relativePath: String) async throws -> Date? {
        try await performIO {
            try withReadAccess(relativePath) {
                let url = VaultPath.resolve(relativePath, in: rootURL)
                return try coordinator.coordinateRead(at: url) { coordinatedURL in
                    guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                        throw VaultFileStoreError.notFound(relativePath)
                    }
                    return try coordinatedURL.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                }
            }
        }
    }

    /// Reads, merges, and writes the document while cooperating with iCloud's
    /// coordinator. The hash re-check is advisory (the contract's residual
    /// TOCTOU window remains), but it never emits a version known to be stale.
    func readModifyWrite(
        _ relativePath: String,
        mutate: @escaping @Sendable (inout FrontmatterDocument) -> Void
    ) async throws {
        try await performIO {
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
                    VaultWriteProvenance.apply(
                        to: &document,
                        relativePath: relativePath,
                        timestampProvider: provenanceTimestampProvider,
                        failureLogger: provenanceFailureLogger
                    )

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
                try Self.atomicReplace(text, at: coordinatedURL)
                return .written
            }
        } catch {
            throw VaultFileStoreError.writeFailed(relativePath, error)
        }
    }

    private func withReadAccess<T: Sendable>(
        _ relativePath: String,
        body: @Sendable () throws -> T
    ) throws -> T {
        guard rootURL.startAccessingSecurityScopedResource() else {
            throw VaultFileStoreError.readFailed(relativePath, CocoaError(.fileReadNoPermission))
        }
        defer { rootURL.stopAccessingSecurityScopedResource() }
        return try body()
    }

    private func withWriteAccess<T: Sendable>(
        _ relativePath: String,
        body: @Sendable () throws -> T
    ) throws -> T {
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

    private func performIO<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performIO<T: Sendable>(_ operation: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private static func atomicReplace(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
