import Foundation
import XCTest
import YggdrasilCore
@testable import Yggdrasil

@MainActor
final class CanvasAppendWriteTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasAppendWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testAnnotationAppendsSingleBlockPreservingContent() async throws {
        let path = "Projects/target.md"
        let originalBody = "# Target\n\nExisting bytes stay put.\n"
        let original = "---\ntitle: Target\n---\n\n\(originalBody)"
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        try original.write(to: tempDirectory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let store = VaultFileStore(rootURL: tempDirectory)

        try await MimerCanvasAppend.appendBlock(
            to: path,
            block: MimerCanvasAppend.annotationBlock("check the June numbers"),
            using: store
        )

        let saved = try await store.read(path)
        let savedDocument = try FrontmatterDocument.parse(saved)
        XCTAssertTrue(savedDocument.body.hasPrefix(originalBody))
        XCTAssertEqual(saved.components(separatedBy: "> [!note] Annotation").count - 1, 1)
        XCTAssertTrue(saved.contains("> check the June numbers"))
    }

    func testDropAppendsPromotionBlockWithRelativeLink() async throws {
        let path = "Projects/target.md"
        let store = VaultFileStore(rootURL: tempDirectory)
        try await store.write("---\ntitle: Target\n---\n\n# Target\n", to: path)
        let promotion = MimerCanvasPromotion(relativePath: "People/Acme AB.md", snippet: "Acme AB")

        XCTAssertEqual(promotion.plainTextRepresentation, "[[People/Acme AB]]\nAcme AB")

        try await MimerCanvasAppend.appendBlock(
            to: path,
            block: MimerCanvasAppend.promotionBlock(promotion),
            using: store
        )

        let saved = try await store.read(path)
        XCTAssertTrue(saved.contains("[[People/Acme AB]] — Acme AB"))
    }

    func testGesturesShareCoordinatedAppendSeam() async throws {
        let coordinator = RecordingCoordinator()
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: coordinator)
        let path = "Projects/target.md"
        try await store.write("---\ntitle: Target\n---\n\n# Target\n", to: path)
        coordinator.operations = []
        let draft = MimerCanvasAppendDraft(fileStore: store)
        draft.annotationText = "annotation"

        let annotationSaved = await draft.submitAnnotation(to: path)
        XCTAssertTrue(annotationSaved)
        let promotionSaved = await draft.submitPromotion(
            MimerCanvasPromotion(relativePath: "Projects/source.md", snippet: "source"),
            to: path
        )
        XCTAssertTrue(promotionSaved)

        XCTAssertEqual(coordinator.operations, [.read, .write, .read, .write])
    }

    func testFailedWriteSurfacesErrorAndRetainsText() async throws {
        let path = "Projects/target.md"
        let original = "---\ntitle: Target\n---\n\n# Target\n"
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        try original.write(to: tempDirectory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: AppendFailingCoordinator())
        let draft = MimerCanvasAppendDraft(fileStore: store)
        draft.annotationText = "Keep this visible"

        let saved = await draft.submitAnnotation(to: path)
        XCTAssertFalse(saved)
        XCTAssertEqual(draft.annotationText, "Keep this visible")
        XCTAssertEqual(draft.failureText, "Keep this visible")
        XCTAssertNotNil(draft.failureMessage)
        XCTAssertEqual(try String(contentsOf: tempDirectory.appendingPathComponent(path)), original)
    }
}

private final class AppendFailingCoordinator: VaultFileCoordinating, @unchecked Sendable {
    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        try accessor(url)
    }

    func coordinateWrite<T: Sendable>(at _: URL, accessor _: @Sendable (URL) throws -> T) throws -> T {
        throw CocoaError(.fileWriteNoPermission)
    }
}
