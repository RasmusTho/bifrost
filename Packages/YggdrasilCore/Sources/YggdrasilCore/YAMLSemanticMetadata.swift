import SwiftTreeSitter
import Yams

extension ParsedYAML {
    static func collectSemanticKeyNames(in root: Yams.Node) -> Set<String> {
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

    static func countConcreteMappingPairs(in node: SwiftTreeSitter.Node) -> Int {
        let ownCount = node.nodeType == "block_mapping_pair"
            || node.nodeType == "flow_pair" ? 1 : 0
        return (0..<node.namedChildCount).reduce(ownCount) { count, index in
            guard let child = node.namedChild(at: index) else { return count }
            return count + countConcreteMappingPairs(in: child)
        }
    }
}
