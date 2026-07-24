import Foundation
import SwiftTreeSitter

enum YAMLProvenanceSourceInserter {
    static func materializeTaggedEmptyMapping(
        from source: String,
        newline: String,
        writtenAt: String
    ) -> String {
        let separator = source.hasSuffix(newline) ? "" : newline
        return source + separator + blockProvenance(
            writtenAt: writtenAt,
            indentation: "  ",
            newline: newline
        )
    }

    static func insert(
        into source: String,
        mappingNode: SwiftTreeSitter.Node,
        mappingIsEmpty: Bool,
        newline: String,
        writtenAt: String
    ) -> String? {
        guard let mappingType = mappingNode.nodeType,
              let mappingRange = Range(mappingNode.range, in: source) else {
            return nil
        }
        switch mappingType {
        case "block_mapping":
            return insertBlockProvenance(
                into: source,
                mappingRange: mappingRange,
                newline: newline,
                writtenAt: writtenAt
            )
        case "flow_mapping":
            return insertFlowProvenance(
                into: source,
                mappingNode: mappingNode,
                mappingRange: mappingRange,
                mappingIsEmpty: mappingIsEmpty,
                writtenAt: writtenAt
            )
        default:
            return nil
        }
    }

    private static func insertBlockProvenance(
        into source: String,
        mappingRange: Range<String.Index>,
        newline: String,
        writtenAt: String
    ) -> String? {
        let lineStart = source[..<mappingRange.lowerBound].lastIndex(of: "\n").map {
            source.index(after: $0)
        } ?? source.startIndex
        let indentation = source[lineStart..<mappingRange.lowerBound]
        guard indentation.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        let provenance = blockProvenance(
            writtenAt: writtenAt,
            indentation: String(indentation),
            newline: newline
        )
        var updated = source
        updated.insert(contentsOf: "\(newline)\(provenance)", at: mappingRange.upperBound)
        return updated
    }

    private static func blockProvenance(
        writtenAt: String,
        indentation: String,
        newline: String
    ) -> String {
        [
            "agent_provenance:",
            "  author: bifrost-ios",
            "  written_at: \(writtenAt)",
            "  origin: direct-fs"
        ].map { "\(indentation)\($0)" }.joined(separator: newline)
    }

    private static func insertFlowProvenance(
        into source: String,
        mappingNode: SwiftTreeSitter.Node,
        mappingRange: Range<String.Index>,
        mappingIsEmpty: Bool,
        writtenAt: String
    ) -> String? {
        guard mappingRange.lowerBound < mappingRange.upperBound,
              source[mappingRange.lowerBound] == "{",
              source[source.index(before: mappingRange.upperBound)] == "}" else {
            return nil
        }
        let insertionIndex = source.index(before: mappingRange.upperBound)
        let separator = mappingIsEmpty ? "" : (hasTrailingComma(in: mappingNode) ? " " : ", ")
        let provenance = "agent_provenance: {author: bifrost-ios, "
            + "written_at: \(writtenAt), origin: direct-fs}"
        var updated = source
        updated.insert(contentsOf: "\(separator)\(provenance)", at: insertionIndex)
        return updated
    }

    private static func hasTrailingComma(in mappingNode: SwiftTreeSitter.Node) -> Bool {
        let pairs = (0..<mappingNode.namedChildCount).compactMap {
            mappingNode.namedChild(at: $0)
        }.filter {
            $0.nodeType == "block_mapping_pair" || $0.nodeType == "flow_pair"
        }
        guard let lastPair = pairs.last else { return false }
        return (0..<mappingNode.childCount).contains { index in
            guard let child = mappingNode.child(at: index),
                  child.nodeType == "," else {
                return false
            }
            return child.range.location >= NSMaxRange(lastPair.range)
        }
    }
}
