import XCTest

final class HeimdalBoundaryTests: XCTestCase {
    func testHeimdalSourcesImportNoMimerInternals() throws {
        let scanner = try makeScanner()
        let sourceFiles = try swiftFiles(in: sourceRoot.appendingPathComponent("Heimdal"))

        XCTAssertFalse(sourceFiles.isEmpty)
        for file in sourceFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let violations = scanner.violations(in: source)
            XCTAssertTrue(
                violations.isEmpty,
                "\(file.lastPathComponent) references Mimer internals: \(violations.sorted())"
            )
        }
    }

    func testBoundaryScannerRejectsEveryDeclaredMimerTypeFixture() throws {
        let scanner = try makeScanner()

        XCTAssertFalse(scanner.prohibitedTypeNames.isEmpty)
        for typeName in scanner.prohibitedTypeNames {
            let fixture = "let prohibitedReference = \(typeName).self"
            XCTAssertEqual(scanner.violations(in: fixture), [typeName])
        }
    }

    func testBoundaryScannerRejectsMimerImportFixture() throws {
        let scanner = try makeScanner()
        XCTAssertEqual(scanner.violations(in: "import Mimer"), ["import Mimer"])
    }

    func testBoundaryScannerRejectsInterpolatedMimerTypeFixture() throws {
        let scanner = try makeScanner()
        let fixture = "let diagnostic = \"\\(MimerShellView.self)\""

        XCTAssertEqual(scanner.violations(in: fixture), ["MimerShellView"])
    }

    func testBoundaryScannerIgnoresCommentsAndStringLiterals() throws {
        let scanner = try makeScanner()
        let fixture = """
        // MimerShellView is named only in documentation.
        let explanatoryText = "MimerShellView"
        struct HeimdalLocalType {}
        """

        XCTAssertTrue(scanner.violations(in: fixture).isEmpty)
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Yggdrasil")
    }

    private func makeScanner() throws -> HeimdalBoundaryScanner {
        let mimerSources = try swiftFiles(in: sourceRoot.appendingPathComponent("Mimer"))
        return try HeimdalBoundaryScanner(mimerSourceFiles: mimerSources)
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            XCTFail("Could not enumerate Swift sources at \(directory.path)")
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}

private struct HeimdalBoundaryScanner {
    let prohibitedTypeNames: Set<String>

    private static let declarationPattern = try? NSRegularExpression(
        pattern: #"\b(?:actor|class|enum|protocol|struct|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )
    private static let identifierPattern = try? NSRegularExpression(
        pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#
    )
    private static let importPattern = try? NSRegularExpression(
        pattern: #"\bimport(?:\s+(?:class|enum|func|protocol|struct|typealias|var))?\s+"#
            + #"Mimer(?:\.[A-Za-z_][A-Za-z0-9_]*)*"#
    )
    init(mimerSourceFiles: [URL]) throws {
        var names = Set<String>()
        for file in mimerSourceFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            names.formUnion(Self.capturedIdentifiers(in: Self.codeOnly(source), using: Self.declarationPattern))
        }
        prohibitedTypeNames = names
    }

    func violations(in source: String) -> Set<String> {
        let code = Self.codeOnly(source)
        var violations = Set<String>()
        if Self.hasMatch(in: code, using: Self.importPattern) {
            violations.insert("import Mimer")
        }
        let identifiers = Self.capturedIdentifiers(in: code, using: Self.identifierPattern, captureGroup: 0)
        violations.formUnion(identifiers.intersection(prohibitedTypeNames))
        return violations
    }

    private static func codeOnly(_ source: String) -> String {
        let characters = Array(source)
        var index = 0
        return scanCode(in: characters, index: &index, interpolationDepth: nil)
    }

    private static func scanCode(
        in characters: [Character],
        index: inout Int,
        interpolationDepth: Int?
    ) -> String {
        var code = ""
        var depth = interpolationDepth

        while index < characters.count {
            if matches("//", in: characters, at: index) {
                skipLineComment(in: characters, index: &index)
                code.append(" ")
            } else if matches("/*", in: characters, at: index) {
                skipBlockComment(in: characters, index: &index)
                code.append(" ")
            } else if let delimiter = stringDelimiter(in: characters, at: index) {
                index = delimiter.contentStart
                code += scanString(in: characters, index: &index, delimiter: delimiter)
                code.append(" ")
            } else if depth != nil, characters[index] == "(" {
                depth? += 1
                code.append(characters[index])
                index += 1
            } else if let currentDepth = depth, characters[index] == ")" {
                if currentDepth == 1 {
                    index += 1
                    return code
                }
                depth = currentDepth - 1
                code.append(characters[index])
                index += 1
            } else {
                code.append(characters[index])
                index += 1
            }
        }
        return code
    }

    private static func scanString(
        in characters: [Character],
        index: inout Int,
        delimiter: StringDelimiter
    ) -> String {
        var interpolatedCode = ""
        while index < characters.count {
            if matchesClosingDelimiter(delimiter, in: characters, at: index) {
                index += delimiter.quoteCount + delimiter.hashCount
                return interpolatedCode
            }
            if matchesInterpolationStart(delimiter, in: characters, at: index) {
                index += 2 + delimiter.hashCount
                interpolatedCode += scanCode(in: characters, index: &index, interpolationDepth: 1)
                interpolatedCode.append(" ")
            } else if delimiter.hashCount == 0, characters[index] == "\\" {
                index = min(index + 2, characters.count)
            } else {
                index += 1
            }
        }
        return interpolatedCode
    }

    private static func skipLineComment(in characters: [Character], index: inout Int) {
        index += 2
        while index < characters.count, characters[index] != "\n" {
            index += 1
        }
    }

    private static func skipBlockComment(in characters: [Character], index: inout Int) {
        var depth = 1
        index += 2
        while index < characters.count, depth > 0 {
            if matches("/*", in: characters, at: index) {
                depth += 1
                index += 2
            } else if matches("*/", in: characters, at: index) {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
    }

    private static func stringDelimiter(in characters: [Character], at index: Int) -> StringDelimiter? {
        var cursor = index
        while cursor < characters.count, characters[cursor] == "#" {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "\"" else { return nil }

        let hashCount = cursor - index
        let quoteCount = matches("\"\"\"", in: characters, at: cursor) ? 3 : 1
        return StringDelimiter(
            hashCount: hashCount,
            quoteCount: quoteCount,
            contentStart: cursor + quoteCount
        )
    }

    private static func matchesClosingDelimiter(
        _ delimiter: StringDelimiter,
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard repeatedCharacter("\"", count: delimiter.quoteCount, matches: characters, at: index) else {
            return false
        }
        return repeatedCharacter(
            "#",
            count: delimiter.hashCount,
            matches: characters,
            at: index + delimiter.quoteCount
        )
    }

    private static func matchesInterpolationStart(
        _ delimiter: StringDelimiter,
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard index < characters.count, characters[index] == "\\" else { return false }
        guard repeatedCharacter("#", count: delimiter.hashCount, matches: characters, at: index + 1) else {
            return false
        }
        let parenthesisIndex = index + 1 + delimiter.hashCount
        return parenthesisIndex < characters.count && characters[parenthesisIndex] == "("
    }

    private static func repeatedCharacter(
        _ character: Character,
        count: Int,
        matches characters: [Character],
        at index: Int
    ) -> Bool {
        guard index + count <= characters.count else { return false }
        return characters[index..<(index + count)].allSatisfy { $0 == character }
    }

    private static func matches(_ token: String, in characters: [Character], at index: Int) -> Bool {
        let tokenCharacters = Array(token)
        guard index + tokenCharacters.count <= characters.count else { return false }
        return Array(characters[index..<(index + tokenCharacters.count)]) == tokenCharacters
    }

    private static func hasMatch(in source: String, using pattern: NSRegularExpression?) -> Bool {
        guard let pattern else { return false }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return pattern.firstMatch(in: source, range: range) != nil
    }

    private static func capturedIdentifiers(
        in source: String,
        using pattern: NSRegularExpression?,
        captureGroup: Int = 1
    ) -> Set<String> {
        guard let pattern else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match in
            guard let captureRange = Range(match.range(at: captureGroup), in: source) else { return nil }
            return String(source[captureRange])
        })
    }
}

private struct StringDelimiter {
    let hashCount: Int
    let quoteCount: Int
    let contentStart: Int
}
