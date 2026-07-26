import Foundation
import SwiftTreeSitter

private struct YAMLReferenceSpelling {
    let range: NSRange
    let prefix: Character
    let name: String
}

private struct YAMLSemanticColumnEdit {
    let line: Int
    let originalColumn: Int
    let originalLength: Int
    let semanticLength: Int
}

struct YAMLSemanticSource {
    let text: String
    private let editsByLine: [Int: [YAMLSemanticColumnEdit]]

    fileprivate init(
        text: String,
        edits: [YAMLSemanticColumnEdit]
    ) {
        self.text = text
        editsByLine = Dictionary(grouping: edits, by: \.line)
            .mapValues { $0.sorted { $0.originalColumn < $1.originalColumn } }
    }

    func originalColumn(line: Int, semanticColumn: Int) -> Int? {
        guard line > 0, semanticColumn > 0 else { return nil }
        var accumulatedDelta = 0
        for edit in editsByLine[line, default: []] {
            let semanticStart = edit.originalColumn + accumulatedDelta
            let semanticEnd = semanticStart + edit.semanticLength
            if semanticColumn < semanticStart {
                break
            }
            if semanticColumn == semanticStart {
                return edit.originalColumn
            }
            if semanticColumn < semanticEnd {
                return nil
            }
            accumulatedDelta += edit.semanticLength - edit.originalLength
        }
        return semanticColumn - accumulatedDelta
    }
}

extension ParsedYAML {
    static func semanticSource(
        from source: String,
        syntaxRoot: SwiftTreeSitter.Node
    ) -> YAMLSemanticSource? {
        let references = collectReferences(from: syntaxRoot, source: source)
        var replacements: [String: String] = [:]
        for reference in references where replacements[reference.name] == nil {
            guard let replacement = candidate(ordinal: replacements.count) else {
                return nil
            }
            replacements[reference.name] = replacement
        }

        var edits: [YAMLSemanticColumnEdit] = []
        for reference in references {
            guard let range = Range(reference.range, in: source),
                  let replacement = replacements[reference.name],
                  let position = scalarPosition(at: range.lowerBound, in: source) else {
                return nil
            }
            edits.append(
                YAMLSemanticColumnEdit(
                    line: position.line,
                    originalColumn: position.column,
                    originalLength: source[range].unicodeScalars.count,
                    semanticLength: 1 + replacement.unicodeScalars.count
                )
            )
        }

        var normalized = source
        for reference in references.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(reference.range, in: normalized),
                  let replacement = replacements[reference.name] else {
                return nil
            }
            normalized.replaceSubrange(range, with: "\(reference.prefix)\(replacement)")
        }
        return YAMLSemanticSource(text: normalized, edits: edits)
    }

    private static func collectReferences(
        from node: SwiftTreeSitter.Node,
        source: String
    ) -> [YAMLReferenceSpelling] {
        var references: [YAMLReferenceSpelling] = []
        if node.nodeType == "anchor" || node.nodeType == "alias",
           let range = Range(node.range, in: source),
           let prefix = source[range].first,
           prefix == "&" || prefix == "*",
           !source[range].dropFirst().isEmpty {
            references.append(
                YAMLReferenceSpelling(
                    range: node.range,
                    prefix: prefix,
                    name: String(source[range].dropFirst())
                )
            )
        }
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index) else { continue }
            references.append(contentsOf: collectReferences(from: child, source: source))
        }
        return references
    }

    private static func scalarPosition(
        at target: String.Index,
        in source: String
    ) -> (line: Int, column: Int)? {
        guard let scalarTarget = target.samePosition(in: source.unicodeScalars) else {
            return nil
        }
        var line = 1
        var column = 1
        var index = source.unicodeScalars.startIndex
        while index < scalarTarget {
            let scalar = source.unicodeScalars[index]
            index = source.unicodeScalars.index(after: index)
            if scalar == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }

    private static func candidate(ordinal: Int) -> String? {
        var value = ordinal
        var digits: [UInt8] = []
        repeat {
            digits.append(candidateAlphabet[value % candidateAlphabet.count])
            value /= candidateAlphabet.count
        } while value > 0
        return String(
            bytes: [UInt8(ascii: "x")] + digits.reversed(),
            encoding: .utf8
        )
    }

    private static let candidateAlphabet = Array(
        "0123456789abcdefghijklmnopqrstuvwxyz".utf8
    )
}
