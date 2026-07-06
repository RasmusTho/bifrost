import Foundation

/// A vault chosen by the user via a visual folder pick (never a typed path).
/// `bookmarkData` is a security-scoped bookmark (`URL.bookmarkData` on
/// iOS/iPadOS) so the app can regain access across launches without asking
/// the user to re-pick or type a path.
public struct VaultReference: Codable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let bookmarkData: Data
    public let lastOpenedAt: Date
    /// The resolved folder path at the time this reference was minted, used
    /// only to tell two distinct folders with the same leaf name apart —
    /// never shown to the user or typed by them.
    public let resolvedPath: String

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        lastOpenedAt: Date,
        resolvedPath: String
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = lastOpenedAt
        self.resolvedPath = resolvedPath
    }
}

/// Resolves vault-relative paths (`_heimdal/interests.md`) against a vault
/// root, without ever asking the user to type one.
public enum VaultPath {
    public static func resolve(_ relativePath: String, in rootURL: URL) -> URL {
        var url = rootURL
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }
}
