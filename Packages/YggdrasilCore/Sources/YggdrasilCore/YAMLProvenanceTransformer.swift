import Foundation
import SwiftTreeSitter
import TreeSitterYAML
import Yams

public enum YAMLProvenanceSanitizationOutcome: Equatable, Sendable {
    case neutralizedStaleAttribution
    case unchangedNoActiveProvenance
    case unverifiable
}

public struct YAMLProvenanceSanitization: Equatable, Sendable {
    public let text: String
    public let outcome: YAMLProvenanceSanitizationOutcome

    public var neutralizedStaleAttribution: Bool {
        outcome == .neutralizedStaleAttribution
    }
}

/// Performs lossless provenance-key custody for arbitrary valid YAML.
///
/// Yams/libYAML is the semantic authority (including tags, aliases, and merge
/// keys). Tree-sitter YAML is the concrete-source authority. A mutation is
/// emitted only when both parsers agree on one exact source token.
public enum YAMLProvenanceTransformer {
    private static let activeName = "agent_provenance"
    private static let neutralName = "former_writer_attribution"

    /// Inserts fresh provenance into any valid root YAML mapping without
    /// reserializing its existing bytes.
    public static func insertingProvenance(
        into text: String,
        writtenAt: String
    ) -> String? {
        guard let document = YAMLFrontmatterSlice(text: text) else { return nil }
        let frontmatter = String(text[document.frontmatterRange])
        guard let parsed = ParsedYAML(source: frontmatter),
              let updatedFrontmatter = parsed.insertingRootProvenance(
                  newline: document.newline,
                  writtenAt: writtenAt
              ),
              let verified = ParsedYAML(source: updatedFrontmatter),
              case .mapping(let verifiedRoot) = verified.semanticRoot,
              SemanticMapping.isProvenanceMapping(verifiedRoot),
              case .found = SemanticMapping.effectiveSource(
                  named: activeName,
                  in: verifiedRoot
              ) else {
            return nil
        }
        return text.replacingCharacters(
            in: document.frontmatterRange,
            with: updatedFrontmatter
        )
    }

    /// Preserves every prior writer value under a neutral audit key before
    /// inserting current provenance for richer valid-YAML shapes.
    public static func upsertingProvenance(
        into text: String,
        writtenAt: String
    ) -> String? {
        let sanitization = sanitizingFallback(text)
        guard sanitization.outcome != .unverifiable else { return nil }
        return insertingProvenance(into: sanitization.text, writtenAt: writtenAt)
    }

    public static func sanitizingFallback(_ text: String) -> YAMLProvenanceSanitization {
        guard let document = YAMLFrontmatterSlice(text: text) else {
            return YAMLProvenanceSanitization(text: text, outcome: .unverifiable)
        }
        return sanitizingFrontmatter(in: text, document: document)
    }

    private static func sanitizingFrontmatter(
        in text: String,
        document: YAMLFrontmatterSlice
    ) -> YAMLProvenanceSanitization {
        let originalFrontmatter = String(text[document.frontmatterRange])
        var frontmatter = originalFrontmatter
        var neutralized = false
        var remainingEdits: Int?

        while true {
            guard let parsed = ParsedYAML(source: frontmatter),
                  case .mapping(let rootMapping) = parsed.semanticRoot,
                  SemanticMapping.isProvenanceMapping(rootMapping) else {
                return YAMLProvenanceSanitization(text: text, outcome: .unverifiable)
            }

            if remainingEdits == nil {
                remainingEdits = parsed.concreteMappingPairCount + 1
            }

            let lookup = SemanticMapping.effectiveSource(
                named: activeName,
                in: rootMapping
            )
            if case .invalid = lookup {
                return YAMLProvenanceSanitization(text: text, outcome: .unverifiable)
            }
            guard case .found(let activeSource) = lookup else {
                let outcome: YAMLProvenanceSanitizationOutcome = neutralized
                    ? .neutralizedStaleAttribution
                    : .unchangedNoActiveProvenance
                let updated = text.replacingCharacters(
                    in: document.frontmatterRange,
                    with: frontmatter
                )
                return YAMLProvenanceSanitization(text: updated, outcome: outcome)
            }

            guard let editsLeft = remainingEdits, editsLeft > 0,
                  !parsed.keyHasSharedAnchor(activeSource),
                  let keyToken = parsed.uniqueConcreteKeyToken(for: activeSource) else {
                return YAMLProvenanceSanitization(text: text, outcome: .unverifiable)
            }

            let replacementName = availableNeutralName(among: parsed.semanticKeyNames)
            guard let replacement = keyToken.replacement(
                spelling: replacementName,
                in: frontmatter
            ) else {
                return YAMLProvenanceSanitization(text: text, outcome: .unverifiable)
            }
            guard let sourceRange = Range(keyToken.range, in: frontmatter) else {
                return YAMLProvenanceSanitization(text: text, outcome: .unverifiable)
            }

            frontmatter.replaceSubrange(sourceRange, with: replacement)
            neutralized = true
            remainingEdits = editsLeft - 1
        }
    }

    private static func availableNeutralName(among occupiedNames: Set<String>) -> String {
        guard occupiedNames.contains(neutralName) else { return neutralName }
        var suffix = 2
        while occupiedNames.contains("\(neutralName)_\(suffix)") {
            suffix += 1
        }
        return "\(neutralName)_\(suffix)"
    }
}

struct ParsedYAML {
    let source: String
    let semanticRoot: Yams.Node
    let syntaxRoot: SwiftTreeSitter.Node
    let semanticKeyNames: Set<String>
    let concreteMappingPairCount: Int

    init?(source: String) {
        do {
            let parser = SwiftTreeSitter.Parser()
            try parser.setLanguage(Language(language: tree_sitter_yaml()))
            guard let tree = parser.parse(source),
                  let syntaxRoot = tree.rootNode,
                  !syntaxRoot.hasError else {
                return nil
            }

            // libYAML (used by Yams) accepts a narrower anchor-name grammar
            // than YAML 1.2. Normalize only reference spellings in the
            // semantic input; all concrete-source proof and mutations still
            // use the original source and the original syntax tree.
            let semanticSource = Self.semanticSource(
                from: source,
                syntaxRoot: syntaxRoot
            )
            guard let semanticRoot = try Yams.compose(yaml: semanticSource) else {
                return nil
            }

            self.source = source
            self.semanticRoot = semanticRoot
            self.syntaxRoot = syntaxRoot
            semanticKeyNames = Self.collectSemanticKeyNames(in: semanticRoot)
            concreteMappingPairCount = Self.countConcreteMappingPairs(in: syntaxRoot)
        } catch {
            return nil
        }
    }

}

private extension ParsedYAML {
    func uniqueConcreteKeyToken(for source: SemanticSource) -> YAMLConcreteKeyToken? {
        guard source.pairIndex < source.mapping.count,
              let mappingNode = uniqueSyntaxMapping(for: source.mapping) else { return nil }
        let pairs = syntaxPairs(in: mappingNode)
        let pair = pairs[source.pairIndex]
        guard let keyNode = pair.child(byFieldName: "key") else { return nil }
        return concreteKeyToken(in: keyNode)
    }

    func insertingRootProvenance(newline: String, writtenAt: String) -> String? {
        if case .mapping(let rootMapping) = semanticRoot {
            guard SemanticMapping.isProvenanceMapping(rootMapping),
                  case .absent = SemanticMapping.effectiveSource(
                named: "agent_provenance",
                in: rootMapping
            ) else {
                return nil
            }
            if let mappingNode = uniqueSyntaxMapping(for: rootMapping),
               let inserted = YAMLProvenanceSourceInserter.insert(
                   into: source,
                   mappingNode: mappingNode,
                   mappingIsEmpty: rootMapping.isEmpty,
                   newline: newline,
                   writtenAt: writtenAt
               ) {
                return inserted
            }
            guard rootMapping.isEmpty else {
                return nil
            }
        } else {
            guard let scalar = semanticRoot.scalar,
                  scalar.tag.rawValue == Tag.Name.map.rawValue,
                  scalar.string.isEmpty else {
                return nil
            }
        }
        return YAMLProvenanceSourceInserter.materializeTaggedEmptyMapping(
            from: source,
            newline: newline,
            writtenAt: writtenAt
        )
    }

    func keyHasSharedAnchor(_ source: SemanticSource) -> Bool {
        guard source.pairIndex < source.mapping.count,
              let mappingNode = uniqueSyntaxMapping(for: source.mapping),
              case .mapping(let rootMapping) = semanticRoot,
              let dependencyMappings = SemanticMapping.mergeDependencyMappings(
                  containing: source,
                  in: rootMapping
              ) else {
            return true
        }

        for dependencyMapping in dependencyMappings {
            guard let dependencyNode = uniqueSyntaxMapping(for: dependencyMapping) else {
                return true
            }
            if mappingHasForeignAliasConsumer(dependencyNode) {
                return true
            }
        }
        let pairs = syntaxPairs(in: mappingNode)
        guard source.pairIndex < pairs.count,
              let keyNode = pairs[source.pairIndex].child(byFieldName: "key") else {
            return true
        }
        let anchors = descendants(of: keyNode, matching: ["anchor"])
        guard !anchors.isEmpty else { return false }
        guard anchors.count == 1,
              let anchorName = referenceName(of: anchors[0], prefix: "&") else {
            return true
        }
        return !aliasConsumers(boundTo: anchors[0], named: anchorName).isEmpty
    }

    private func mappingHasForeignAliasConsumer(
        _ mappingNode: SwiftTreeSitter.Node
    ) -> Bool {
        guard let container = mappingNode.parent,
              container.nodeType == "block_node" || container.nodeType == "flow_node" else {
            return true
        }
        let anchors = descendants(of: container, matching: ["anchor"]).filter {
            !NSLocationInRange($0.range.location, mappingNode.range)
        }
        guard !anchors.isEmpty else { return false }
        guard anchors.count == 1,
              let anchorName = referenceName(of: anchors[0], prefix: "&") else {
            return true
        }
        let consumers = aliasConsumers(boundTo: anchors[0], named: anchorName)
        guard !consumers.isEmpty else { return false }
        guard case .mapping(let rootMapping) = semanticRoot,
              let mergeMarks = SemanticMapping.reachableMergeKeyMarks(in: rootMapping) else {
            return true
        }
        let mergeOffsets = mergeMarks.compactMap(utf16Offset)
        guard mergeOffsets.count == mergeMarks.count else { return true }

        return consumers.contains { consumer in
            guard let pair = nearestSyntaxPair(containing: consumer),
                  let keyNode = pair.child(byFieldName: "key") else {
                return true
            }
            return !mergeOffsets.contains {
                NSLocationInRange($0, keyNode.range)
            }
        }
    }

    private func concreteKeyToken(in keyNode: SwiftTreeSitter.Node) -> YAMLConcreteKeyToken? {
        let aliases = descendants(of: keyNode, matching: ["alias"])
        if aliases.count == 1 {
            return YAMLConcreteKeyToken(range: aliases[0].range, style: .alias)
        }
        guard aliases.isEmpty else { return nil }

        let scalars = descendants(
            of: keyNode,
            matching: [
                "block_scalar",
                "plain_scalar",
                "single_quote_scalar",
                "double_quote_scalar"
            ]
        )
        guard scalars.count == 1, let type = scalars[0].nodeType else { return nil }
        let style: YAMLConcreteKeyToken.Style
        switch type {
        case "block_scalar":
            style = .block
        case "plain_scalar":
            style = .plain
        case "single_quote_scalar":
            style = .singleQuoted
        case "double_quote_scalar":
            style = .doubleQuoted
        default:
            return nil
        }
        return YAMLConcreteKeyToken(range: scalars[0].range, style: style)
    }

    private func uniqueSyntaxMapping(for mapping: Yams.Node.Mapping) -> SwiftTreeSitter.Node? {
        let candidates = allSyntaxMappings(in: syntaxRoot).filter {
            syntaxPairs(in: $0).count == mapping.count
        }
        if let firstMark = mapping.first?.key.mark,
           let firstOffset = utf16Offset(for: firstMark) {
            let firstKeyMatches = candidates.filter { mappingNode in
                guard let firstConcreteKey = syntaxPairs(in: mappingNode)
                    .first?
                    .child(byFieldName: "key") else {
                    return false
                }
                return NSLocationInRange(firstOffset, firstConcreteKey.range)
            }
            if firstKeyMatches.count == 1 {
                return firstKeyMatches[0]
            }
        }
        if let mappingMark = mapping.mark,
           let mappingOffset = utf16Offset(for: mappingMark) {
            let containerMatches = candidates.compactMap { candidate -> (
                node: SwiftTreeSitter.Node,
                range: NSRange
            )? in
                guard let parent = candidate.parent,
                      parent.nodeType == "block_node" || parent.nodeType == "flow_node",
                      NSLocationInRange(mappingOffset, parent.range) else {
                    return nil
                }
                return (candidate, parent.range)
            }
            if let containerMatch = uniqueNarrowest(containerMatches) {
                return containerMatch
            }

            let mappingMatches = candidates.compactMap { candidate -> (
                node: SwiftTreeSitter.Node,
                range: NSRange
            )? in
                guard NSLocationInRange(mappingOffset, candidate.range) else { return nil }
                return (candidate, candidate.range)
            }
            if let mappingMatch = uniqueNarrowest(mappingMatches) {
                return mappingMatch
            }
        }
        return nil
    }

    private func uniqueNarrowest(
        _ candidates: [(node: SwiftTreeSitter.Node, range: NSRange)]
    ) -> SwiftTreeSitter.Node? {
        guard let minimumLength = candidates.map(\.range.length).min() else { return nil }
        let narrowest = candidates.filter { $0.range.length == minimumLength }
        return narrowest.count == 1 ? narrowest[0].node : nil
    }

    private func utf16Offset(for mark: Mark) -> Int? {
        guard mark.line > 0, mark.column > 0 else { return nil }
        var line = 1
        var column = 1
        var scalarIndex = source.unicodeScalars.startIndex

        while scalarIndex < source.unicodeScalars.endIndex {
            if line == mark.line, column == mark.column {
                guard let stringIndex = scalarIndex.samePosition(in: source) else { return nil }
                return source.utf16.distance(
                    from: source.utf16.startIndex,
                    to: stringIndex.samePosition(in: source.utf16) ?? source.utf16.endIndex
                )
            }
            let scalar = source.unicodeScalars[scalarIndex]
            scalarIndex = source.unicodeScalars.index(after: scalarIndex)
            if scalar == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }

        if line == mark.line, column == mark.column {
            return source.utf16.count
        }
        return nil
    }

    private func allSyntaxMappings(in node: SwiftTreeSitter.Node) -> [SwiftTreeSitter.Node] {
        var matches: [SwiftTreeSitter.Node] = []
        if node.nodeType == "block_mapping" || node.nodeType == "flow_mapping" {
            matches.append(node)
        }
        for index in 0..<node.namedChildCount {
            if let child = node.namedChild(at: index) {
                matches.append(contentsOf: allSyntaxMappings(in: child))
            }
        }
        return matches
    }

    private func syntaxPairs(in mapping: SwiftTreeSitter.Node) -> [SwiftTreeSitter.Node] {
        (0..<mapping.namedChildCount).compactMap { index in
            guard let child = mapping.namedChild(at: index),
                  child.nodeType == "block_mapping_pair" || child.nodeType == "flow_pair" else {
                return nil
            }
            return child
        }
    }

    private func descendants(
        of node: SwiftTreeSitter.Node,
        matching types: Set<String>
    ) -> [SwiftTreeSitter.Node] {
        var matches: [SwiftTreeSitter.Node] = []
        if let type = node.nodeType, types.contains(type) {
            matches.append(node)
            return matches
        }
        for index in 0..<node.namedChildCount {
            if let child = node.namedChild(at: index) {
                matches.append(contentsOf: descendants(of: child, matching: types))
            }
        }
        return matches
    }

    private static func collectSemanticKeyNames(in root: Yams.Node) -> Set<String> {
        var names: Set<String> = []
        var visitedMappings: Set<MappingIdentity> = []

        func visit(_ node: Yams.Node) {
            switch node {
            case .mapping(let mapping):
                let identity = MappingIdentity(mapping)
                guard visitedMappings.insert(identity).inserted else { return }
                for pair in mapping {
                    if let keyName = pair.key.scalar?.string {
                        names.insert(keyName)
                    }
                    visit(pair.key)
                    visit(pair.value)
                }
            case .sequence(let sequence):
                for item in sequence {
                    visit(item)
                }
            case .scalar, .alias:
                return
            }
        }

        visit(root)
        return names
    }

    private static func countConcreteMappingPairs(in node: SwiftTreeSitter.Node) -> Int {
        let ownCount = node.nodeType == "block_mapping_pair"
            || node.nodeType == "flow_pair" ? 1 : 0
        return (0..<node.namedChildCount).reduce(ownCount) { count, index in
            guard let child = node.namedChild(at: index) else { return count }
            return count + countConcreteMappingPairs(in: child)
        }
    }
    private func referenceName(of node: SwiftTreeSitter.Node, prefix: Character) -> Substring? {
        guard let range = Range(node.range, in: source) else { return nil }
        let spelling = source[range]
        guard spelling.first == prefix else { return nil }
        return spelling.dropFirst()
    }
}
