import Foundation

/// A markdown note: YAML frontmatter (delimited by `---` lines) plus a body.
///
/// Round-trips unknown frontmatter fields untouched, so a client that only
/// understands a handful of fields on a note (e.g. `weights` on
/// `interests.md`) never clobbers the fields another writer — the Python
/// backend, Obsidian — owns.
public struct FrontmatterDocument: Equatable {
    public var frontmatter: YAMLMap
    public var body: String

    public init(frontmatter: YAMLMap, body: String) {
        self.frontmatter = frontmatter
        self.body = body
    }

    public enum ParseError: Error {
        case missingFrontmatter
    }

    public static func parse(_ text: String) throws -> FrontmatterDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else { throw ParseError.missingFrontmatter }
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else { throw ParseError.missingFrontmatter }
        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0 == "---" }) else {
            throw ParseError.missingFrontmatter
        }
        let frontmatterLines = lines[1..<closingIndex]
        let bodyLines = lines[(closingIndex + 1)...]
        let frontmatterText = frontmatterLines.joined(separator: "\n")
        let parsed = try YAMLCodec.parse(frontmatterText)
        guard case .map(let map) = parsed else {
            throw ParseError.missingFrontmatter
        }
        var body = bodyLines.joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        return FrontmatterDocument(frontmatter: map, body: body)
    }

    public func rendered() -> String {
        let yaml = YAMLCodec.serialize(.map(frontmatter))
        var text = "---\n"
        text += yaml
        text += "---\n"
        if !body.isEmpty {
            text += "\n" + body
            if !body.hasSuffix("\n") { text += "\n" }
        }
        return text
    }

    /// Records the Bifrost direct-filesystem writer on a note without
    /// disturbing any unrelated frontmatter owned by another writer.
    public mutating func applyBifrostProvenance(writtenAt: String) {
        var provenance = frontmatter["agent_provenance"]?.mapValue ?? YAMLMap()
        provenance["author"] = .string("bifrost-ios")
        provenance["written_at"] = .string(writtenAt)
        provenance["origin"] = .string("direct-fs")
        frontmatter["agent_provenance"] = .map(provenance)
    }
}
