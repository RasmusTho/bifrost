import Yams

struct SemanticSource {
    let mapping: Yams.Node.Mapping
    let pairIndex: Int
}

enum SemanticMapping {
    enum Lookup {
        case found(SemanticSource)
        case absent
        case invalid
    }

    private struct Entry {
        let source: SemanticSource
        let key: Yams.Node
    }

    static func isProvenanceMapping(_ mapping: Yams.Node.Mapping) -> Bool {
        mapping.tag.rawValue != Tag.Name.set.rawValue
    }

    static func effectiveSource(
        named name: String,
        in mapping: Yams.Node.Mapping
    ) -> Lookup {
        var activeMappings: Set<MappingIdentity> = []
        guard let entries = flattenedEntries(
            in: mapping,
            activeMappings: &activeMappings
        ) else {
            return .invalid
        }
        guard let source = entries
            .reversed()
            .first(where: { $0.key.scalar?.string == name })?
            .source else {
            return .absent
        }
        return .found(source)
    }

    private static func flattenedEntries(
        in mapping: Yams.Node.Mapping,
        activeMappings: inout Set<MappingIdentity>
    ) -> [Entry]? {
        let identity = MappingIdentity(mapping)
        guard activeMappings.insert(identity).inserted else { return nil }
        defer { activeMappings.remove(identity) }
        var merged: [Entry] = []
        var direct: [Entry] = []

        for (index, pair) in mapping.enumerated() {
            if pair.key.tag.rawValue == Tag.Name.merge.rawValue {
                switch pair.value {
                case .mapping(let mergedMapping):
                    guard let entries = flattenedEntries(
                        in: mergedMapping,
                        activeMappings: &activeMappings
                    ) else {
                        return nil
                    }
                    merged.append(contentsOf: entries)
                case .sequence(let sequence):
                    for item in sequence.reversed() {
                        guard case .mapping(let mergedMapping) = item,
                              let entries = flattenedEntries(
                                  in: mergedMapping,
                                  activeMappings: &activeMappings
                              ) else {
                            return nil
                        }
                        merged.append(contentsOf: entries)
                    }
                default:
                    return nil
                }
            } else {
                direct.append(
                    Entry(
                        source: SemanticSource(mapping: mapping, pairIndex: index),
                        key: pair.key
                    )
                )
            }
        }

        return merged + direct
    }
}

struct MappingIdentity: Hashable {
    let line: Int
    let column: Int
    let count: Int

    init(_ mapping: Yams.Node.Mapping) {
        line = mapping.mark?.line ?? -1
        column = mapping.mark?.column ?? -1
        count = mapping.count
    }
}
