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

    func replacement(spelling: String) -> String {
        switch style {
        case .alias, .block, .plain:
            return spelling
        case .singleQuoted:
            return "'\(spelling)'"
        case .doubleQuoted:
            return "\"\(spelling)\""
        }
    }
}
