import Foundation
import SwiftTreeSitter

private struct YAMLReferenceSpelling {
    let range: NSRange
    let prefix: Character
    let name: String
}

extension ParsedYAML {
    static func semanticSource(
        from source: String,
        syntaxRoot: SwiftTreeSitter.Node
    ) -> String? {
        let references = collectReferences(from: syntaxRoot, source: source)
        var names = Set(references.map(\.name))
        var replacements: [String: String] = [:]
        var nextByWidth: [Int: Int] = [:]
        for reference in references where replacements[reference.name] == nil {
            let utf16Width = max(1, reference.name.utf16.count)
            guard let candidate = availableCandidate(
                utf16Width: utf16Width,
                names: names,
                nextByWidth: &nextByWidth
            ) else { return nil }
            names.insert(candidate)
            replacements[reference.name] = candidate
        }

        var normalized = source
        for reference in references.sorted(by: { $0.range.location > $1.range.location }) {
            guard let range = Range(reference.range, in: normalized),
                  let replacement = replacements[reference.name] else {
                continue
            }
            normalized.replaceSubrange(range, with: "\(reference.prefix)\(replacement)")
        }
        return normalized
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

    private static func availableCandidate(
        utf16Width: Int,
        names: Set<String>,
        nextByWidth: inout [Int: Int]
    ) -> String? {
        let start = nextByWidth[utf16Width, default: 0]
        guard let capacity = candidateCapacity(for: utf16Width) else { return nil }
        for ordinal in start..<capacity {
            guard let candidate = asciiCandidate(width: utf16Width, ordinal: ordinal) else {
                return nil
            }
            nextByWidth[utf16Width] = ordinal + 1
            if !names.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func candidateCapacity(for width: Int) -> Int? {
        let alphabetSize = width == 1 ? oneCharacterAlphabet.count : digitAlphabet.count
        return (0..<max(1, width - 1)).reduce(1) { capacity, _ in
            guard capacity <= Int.max / alphabetSize else { return 0 }
            return capacity * alphabetSize
        }
    }

    private static func asciiCandidate(width: Int, ordinal: Int) -> String? {
        if width == 1 {
            guard ordinal < oneCharacterAlphabet.count else { return nil }
            return String(bytes: [oneCharacterAlphabet[ordinal]], encoding: .utf8)
        }
        var bytes = Array(repeating: UInt8(ascii: "x"), count: width)
        bytes[0] = UInt8(ascii: "b")
        var remaining = ordinal
        for offset in stride(from: width - 1, through: 1, by: -1) {
            bytes[offset] = digitAlphabet[remaining % digitAlphabet.count]
            remaining /= digitAlphabet.count
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static let oneCharacterAlphabet = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".utf8
    )
    private static let digitAlphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
}
