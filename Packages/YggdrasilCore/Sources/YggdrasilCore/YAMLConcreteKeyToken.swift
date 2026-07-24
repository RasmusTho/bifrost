import Foundation

struct YAMLConcreteKeyToken {
    enum Style: Equatable {
        case alias
        case block
        case plain
        case singleQuoted
        case doubleQuoted
    }

    let range: NSRange
    let style: Style

    func replacement(spelling: String, in source: String) -> String? {
        switch style {
        case .alias, .plain:
            return spelling
        case .block:
            return replacingBlockScalarContent(with: spelling, in: source)
        case .singleQuoted:
            return "'\(spelling)'"
        case .doubleQuoted:
            return "\"\(spelling)\""
        }
    }

    private func replacingBlockScalarContent(
        with spelling: String,
        in source: String
    ) -> String? {
        guard let sourceRange = Range(range, in: source) else { return nil }
        var token = String(source[sourceRange])
        guard let headerBreak = token.range(of: "\r\n") ?? token.range(of: "\n") else {
            return nil
        }
        let contentStart = headerBreak.upperBound
        let contentRange = contentStart..<token.endIndex
        guard let activeRange = token.range(
            of: "agent_provenance",
            range: contentRange
        ),
        token.range(
            of: "agent_provenance",
            range: activeRange.upperBound..<token.endIndex
        ) == nil else {
            return nil
        }
        token.replaceSubrange(activeRange, with: spelling)
        return token
    }
}
