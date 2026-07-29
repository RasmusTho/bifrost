import Foundation
import SwiftTreeSitter

/// Appends one item to a direct root sequence while preserving every existing
/// source byte. Yams proves the semantic target and tree-sitter supplies the
/// concrete insertion range; unsupported or ambiguous YAML fails closed.
public enum YAMLSourcePreservingArrayAppender {
    public static func appending(
        _ item: YAMLValue,
        toRootSequenceNamed name: String,
        in text: String
    ) -> String? {
        guard let document = YAMLFrontmatterSlice(text: text) else { return nil }
        let frontmatter = String(text[document.frontmatterRange])
        guard let parsed = ParsedYAML(source: frontmatter),
              let sequence = parsed.directRootSequence(named: name) else {
            return nil
        }

        guard let updatedFrontmatter = appending(
            item,
            toSequenceIn: sequence.pair,
            sequenceIsEmpty: sequence.itemCount == 0,
            frontmatter: frontmatter,
            newline: document.newline
        ),
              let verified = ParsedYAML(source: updatedFrontmatter),
              let verifiedSequence = verified.directRootSequence(named: name),
              verifiedSequence.itemCount == sequence.itemCount + 1 else {
            return nil
        }

        return text.replacingCharacters(
            in: document.frontmatterRange,
            with: updatedFrontmatter
        )
    }

    private static func appending(
        _ item: YAMLValue,
        toSequenceIn pair: SwiftTreeSitter.Node,
        sequenceIsEmpty: Bool,
        frontmatter: String,
        newline: String
    ) -> String? {
        let blockSequences = descendants(of: pair, matching: "block_sequence")
        let flowSequences = descendants(of: pair, matching: "flow_sequence")
        if blockSequences.count == 1, flowSequences.isEmpty {
            return appendingToBlockSequence(
                item,
                sequenceNode: blockSequences[0],
                frontmatter: frontmatter,
                newline: newline
            )
        }
        if sequenceIsEmpty, flowSequences.count == 1, blockSequences.isEmpty {
            return materializingEmptyFlowSequence(
                item,
                sequenceNode: flowSequences[0],
                pairNode: pair,
                frontmatter: frontmatter,
                newline: newline
            )
        }
        return nil
    }

    private static func appendingToBlockSequence(
        _ item: YAMLValue,
        sequenceNode: SwiftTreeSitter.Node,
        frontmatter: String,
        newline: String
    ) -> String? {
        guard let sequenceRange = Range(sequenceNode.range, in: frontmatter) else { return nil }
        let indentation = lineIndentation(at: sequenceRange.lowerBound, in: frontmatter)
        let itemText = indentedSequenceItem(item, indentation: indentation, newline: newline)
        let insertionIndex = lineEnd(after: sequenceRange.upperBound, in: frontmatter)
        var updated = frontmatter
        updated.insert(contentsOf: newline + itemText, at: insertionIndex)
        return updated
    }

    private static func materializingEmptyFlowSequence(
        _ item: YAMLValue,
        sequenceNode: SwiftTreeSitter.Node,
        pairNode: SwiftTreeSitter.Node,
        frontmatter: String,
        newline: String
    ) -> String? {
        guard let sequenceRange = Range(sequenceNode.range, in: frontmatter),
              let pairRange = Range(pairNode.range, in: frontmatter),
              frontmatter[sequenceRange].trimmingCharacters(in: .whitespaces) == "[]" else {
            return nil
        }
        let lineEndIndex = lineEnd(after: sequenceRange.upperBound, in: frontmatter)
        guard frontmatter[sequenceRange.upperBound..<lineEndIndex]
            .trimmingCharacters(in: .whitespaces)
            .isEmpty else {
            return nil
        }
        let indentation = lineIndentation(at: pairRange.lowerBound, in: frontmatter) + 2
        let itemText = indentedSequenceItem(item, indentation: indentation, newline: newline)
        var updated = frontmatter
        updated.replaceSubrange(sequenceRange, with: newline + itemText)
        return updated
    }

    private static func indentedSequenceItem(
        _ item: YAMLValue,
        indentation: Int,
        newline: String
    ) -> String {
        let padding = String(repeating: " ", count: indentation)
        return YAMLCodec.serializeSequence([item])
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n")
            .map { padding + $0 }
            .joined(separator: newline)
    }

    private static func lineIndentation(
        at index: String.Index,
        in text: String
    ) -> Int {
        let lineStart = text[..<index].lastIndex(of: "\n").map {
            text.index(after: $0)
        } ?? text.startIndex
        return text[lineStart..<index].prefix { $0 == " " }.count
    }

    private static func lineEnd(
        after index: String.Index,
        in text: String
    ) -> String.Index {
        text[index...].firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? text.endIndex
    }

    private static func descendants(
        of node: SwiftTreeSitter.Node,
        matching type: String
    ) -> [SwiftTreeSitter.Node] {
        var matches: [SwiftTreeSitter.Node] = []
        if node.nodeType == type {
            matches.append(node)
        }
        for index in 0..<node.namedChildCount {
            if let child = node.namedChild(at: index) {
                matches.append(contentsOf: descendants(of: child, matching: type))
            }
        }
        return matches
    }
}
