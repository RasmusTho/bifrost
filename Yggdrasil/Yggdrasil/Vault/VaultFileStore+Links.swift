import Foundation
import YggdrasilCore

/// What a note's `[[link]]` or `![[embed]]` target resolved to.
struct VaultLinkResolution: Equatable, Sendable {
    enum Kind: String, Sendable {
        case note
        case asset
    }

    let path: String
    let kind: Kind
}

/// On-demand link resolution and binary reads for the note renderer.
///
/// Resolution walks the vault once per call and keeps nothing afterwards:
/// the client still holds no vault index (the `.md` vault stays the only
/// source of record). Matching follows Obsidian: an exact vault path, then a
/// path relative to the linking note, then the shortest path whose file name
/// matches, preferring files nearest the linking note.
extension VaultFileStore {
    /// Folders Obsidian and the system keep for themselves.
    private static let skippedDirectories: Set<String> = [".obsidian", ".trash", ".git", ".Trash"]

    func resolveLinks(_ targets: [String], from notePath: String) async -> [String: VaultLinkResolution] {
        let wanted = Array(Set(targets.filter { !$0.isEmpty }))
        guard !wanted.isEmpty else { return [:] }
        let files = (try? await allFilePaths()) ?? []
        return Self.resolve(wanted, from: notePath, among: files)
    }

    /// Raw bytes of a vault file (images, audio, PDFs). Refuses paths that
    /// would leave the vault.
    func readData(_ relativePath: String) async throws -> Data {
        guard Self.isContained(relativePath) else { throw VaultFileStoreError.notFound(relativePath) }
        return try await performIO {
            try withReadAccess(relativePath) {
                let url = VaultPath.resolve(relativePath, in: rootURL)
                return try coordinator.coordinateRead(at: url) { coordinatedURL in
                    guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                        throw VaultFileStoreError.notFound(relativePath)
                    }
                    return try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                }
            }
        }
    }

    /// Every file in the vault as a vault-relative path (transient).
    func allFilePaths() async throws -> [String] {
        try await performIO {
            try withReadAccess("") {
                try coordinator.coordinateRead(at: rootURL) { coordinatedURL in
                    Self.enumerateFiles(under: coordinatedURL)
                }
            }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    static func isContained(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return !parts.isEmpty && !parts.contains("..") && !parts.contains(".") && !relativePath.hasPrefix("/")
    }

    static func enumerateFiles(under root: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }
        let rootComponents = root.standardizedFileURL.pathComponents.count
        var paths: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) || name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            guard !name.hasPrefix("."), values?.isRegularFile != false else { continue }
            let components = url.standardizedFileURL.pathComponents.dropFirst(rootComponents)
            paths.append(components.joined(separator: "/"))
        }
        return paths
    }

    static func resolve(
        _ targets: [String],
        from notePath: String,
        among files: [String]
    ) -> [String: VaultLinkResolution] {
        let lowered = Dictionary(files.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var byName: [String: [String]] = [:]
        for file in files {
            let name = (file as NSString).lastPathComponent.lowercased()
            byName[name, default: []].append(file)
            if name.hasSuffix(".md") {
                byName[String(name.dropLast(3)), default: []].append(file)
            }
        }
        let noteDirectory = (notePath as NSString).deletingLastPathComponent
        var result: [String: VaultLinkResolution] = [:]
        for target in targets {
            guard let path = match(target, noteDirectory: noteDirectory, lowered: lowered, byName: byName) else {
                continue
            }
            result[target] = VaultLinkResolution(path: path, kind: path.lowercased().hasSuffix(".md") ? .note : .asset)
        }
        return result
    }

    private static func match(
        _ rawTarget: String,
        noteDirectory: String,
        lowered: [String: String],
        byName: [String: [String]]
    ) -> String? {
        let target = rawTarget.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard isContained(target) else { return nil }
        let hasExtension = !(target as NSString).pathExtension.isEmpty
        let candidates = hasExtension ? [target] : [target + ".md", target]
        for candidate in candidates {
            if let exact = lowered[candidate.lowercased()] { return exact }
            if !noteDirectory.isEmpty {
                let relative = (noteDirectory as NSString).appendingPathComponent(candidate)
                if let hit = lowered[(relative as NSString).standardizingPath.lowercased()] { return hit }
            }
        }
        let name = (target as NSString).lastPathComponent.lowercased()
        guard let options = byName[name], !options.isEmpty else { return nil }
        // A path-qualified target (`Folder/Note`) must end with that path.
        let suffixes = candidates.map { $0.lowercased() }
        let suffixMatches = target.contains("/")
            ? options.filter { option in suffixes.contains { option.lowercased().hasSuffix($0) } }
            : options
        let pool = suffixMatches.isEmpty ? options : suffixMatches
        return pool.min { lhs, rhs in
            let left = (sharedPrefix(lhs, noteDirectory), -lhs.split(separator: "/").count, lhs)
            let right = (sharedPrefix(rhs, noteDirectory), -rhs.split(separator: "/").count, rhs)
            if left.0 != right.0 { return left.0 > right.0 }
            if left.1 != right.1 { return left.1 > right.1 }
            return left.2 < right.2
        }
    }

    private static func sharedPrefix(_ path: String, _ directory: String) -> Int {
        let lhs = (path as NSString).deletingLastPathComponent.split(separator: "/")
        let rhs = directory.split(separator: "/")
        return zip(lhs, rhs).prefix { $0 == $1 }.count
    }
}
