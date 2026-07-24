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
    ) -> String {
        var references: [YAMLReferenceSpelling] = []

        func visit(_ node: SwiftTreeSitter.Node) {
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
                visit(child)
            }
        }
        visit(syntaxRoot)

        var names = Set(references.map(\.name))
        var replacements: [String: String] = [:]
        var next = 0
        for reference in references where replacements[reference.name] == nil {
            var candidate: String
            let length = max(1, reference.name.utf16.count)
            repeat {
                let seed = "b\(next)"
                candidate = String(seed.prefix(length)).padding(
                    toLength: length,
                    withPad: "x",
                    startingAt: 0
                )
                next += 1
            } while names.contains(candidate)
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
}
