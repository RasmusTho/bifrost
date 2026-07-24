import Foundation
import SwiftTreeSitter

extension ParsedYAML {
    /// YAML aliases bind to the nearest preceding anchor definition with the
    /// same name. Anchor spellings are not globally unique.
    func aliasConsumers(
        boundTo anchor: SwiftTreeSitter.Node,
        named name: Substring
    ) -> [SwiftTreeSitter.Node] {
        let anchors = referenceNodes(type: "anchor", prefix: "&", named: name)
        return referenceNodes(type: "alias", prefix: "*", named: name).filter { alias in
            let preceding = anchors.filter { $0.range.location < alias.range.location }
            guard let binding = preceding.max(by: {
                $0.range.location < $1.range.location
            }) else {
                return false
            }
            return NSEqualRanges(binding.range, anchor.range)
        }
    }

    private func referenceNodes(
        type: String,
        prefix: Character,
        named name: Substring
    ) -> [SwiftTreeSitter.Node] {
        descendants(of: syntaxRoot, matching: type).filter {
            referenceName(of: $0, prefix: prefix) == name
        }
    }

    private func descendants(
        of node: SwiftTreeSitter.Node,
        matching type: String
    ) -> [SwiftTreeSitter.Node] {
        var matches = node.nodeType == type ? [node] : []
        for index in 0..<node.namedChildCount {
            if let child = node.namedChild(at: index) {
                matches.append(contentsOf: descendants(of: child, matching: type))
            }
        }
        return matches
    }

    private func referenceName(
        of node: SwiftTreeSitter.Node,
        prefix: Character
    ) -> Substring? {
        guard let range = Range(node.range, in: source) else { return nil }
        let spelling = source[range]
        guard spelling.first == prefix else { return nil }
        return spelling.dropFirst()
    }
}
