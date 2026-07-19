import XCTest

final class HeimdalBoundaryTests: XCTestCase {
    func testHeimdalSourcesImportNoMimerInternals() throws {
        let fileManager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Yggdrasil/Heimdal")
        let sourceFiles = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        XCTAssertFalse(sourceFiles.isEmpty)
        for file in sourceFiles {
            let source = try String(contentsOf: file)
            XCTAssertFalse(source.contains("import Mimer"), "\(file.lastPathComponent) imports Mimer")
            XCTAssertFalse(source.contains("MimerShellView"), "\(file.lastPathComponent) references a Mimer type")
        }
    }
}
