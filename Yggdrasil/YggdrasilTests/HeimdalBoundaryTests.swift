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
    private static let nonCodePattern = try? NSRegularExpression(
        pattern: #"(?s)/\*.*?\*/|//[^\r\n]*|\"(?:\\.|[^\"\\])*\""#
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
        guard let nonCodePattern else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return nonCodePattern.stringByReplacingMatches(in: source, range: range, withTemplate: " ")
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
