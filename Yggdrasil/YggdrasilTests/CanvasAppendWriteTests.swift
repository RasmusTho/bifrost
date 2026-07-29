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

    func testPromotionKeepsPendingAnnotationDraft() async throws {
        let path = "Projects/target.md"
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        try "---\ntitle: Target\n---\n\n# Target\n".write(
            to: tempDirectory.appendingPathComponent(path), atomically: true, encoding: .utf8
        )
        let store = VaultFileStore(rootURL: tempDirectory)
        let draft = MimerCanvasAppendDraft(fileStore: store)
        draft.annotationText = "pending, unsaved annotation"

        let promotionSaved = await draft.submitPromotion(
            MimerCanvasPromotion(relativePath: "People/Acme AB.md", snippet: "Acme AB"),
            to: path
        )

        XCTAssertTrue(promotionSaved)
        XCTAssertEqual(draft.annotationText, "pending, unsaved annotation")
    }

    func testAnnotationTargetsComposedNoteAfterSelectionChange() async throws {
        let noteA = "Projects/noteA.md"
        let noteB = "Projects/noteB.md"
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        for path in [noteA, noteB] {
            try "---\ntitle: \(path)\n---\n\n# \(path)\n".write(
                to: tempDirectory.appendingPathComponent(path), atomically: true, encoding: .utf8
            )
        }
        let store = VaultFileStore(rootURL: tempDirectory)
        let draft = MimerCanvasAppendDraft(fileStore: store)
        let coordinator = MimerCanvasDetailCoordinator(fileStore: store)

        // The composer is opened against noteA...
        coordinator.beginAnnotationComposition(for: noteA)
        draft.annotationText = "composed while looking at noteA"
        // ...then the human's selection moves to noteB before they commit.
        coordinator.selectionChanged()
        // If the human were to open the Annotate action again for the newly
        // selected note, the already-pending draft's target must not move.
        coordinator.beginAnnotationComposition(for: noteB)
        // The composer must still target noteA (INV-B2-3): never silently
        // retargeted to whatever is now selected.
        let targetPath = coordinator.composedAnnotationPath
        XCTAssertEqual(targetPath, noteA)

        let saved = await draft.submitAnnotation(to: targetPath ?? noteB)

        XCTAssertTrue(saved)
        let savedNoteA = try await store.read(noteA)
        let savedNoteB = try await store.read(noteB)
        XCTAssertTrue(savedNoteA.contains("composed while looking at noteA"))
        XCTAssertFalse(savedNoteB.contains("composed while looking at noteA"))
    }

    func testStaleRefreshDoesNotReplaceNewerSelection() async throws {
        let noteA = "Projects/noteA.md"
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        try "---\ntitle: noteA\n---\n\n# noteA\n".write(
            to: tempDirectory.appendingPathComponent(noteA), atomically: true, encoding: .utf8
        )
        let slowCoordinator = SlowReadCoordinator(delay: 0.3)
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: slowCoordinator)
        let coordinator = MimerCanvasDetailCoordinator(fileStore: store)

        var appliedNote: MimerCanvasNote?
        let refreshTask = Task {
            await coordinator.refresh(
                path: noteA,
                currentSelectedPath: { "Projects/noteB.md" },
                applyRefreshedNote: { refreshed in appliedNote = refreshed }
            )
        }

        // Simulate the human moving their selection to a different note
        // while the append's post-write refresh for noteA is still in
        // flight reading from disk.
        try await Task.sleep(nanoseconds: 50_000_000)
        coordinator.selectionChanged()
        await refreshTask.value

        XCTAssertNil(appliedNote, "a stale refresh for a no-longer-selected note must not apply")
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

/// A read coordinator that sleeps before returning, so tests can reliably
/// land a state change (e.g. a selection change) while a read is in flight.
private final class SlowReadCoordinator: VaultFileCoordinating, @unchecked Sendable {
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        Thread.sleep(forTimeInterval: delay)
        return try accessor(url)
    }

    func coordinateWrite<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        try accessor(url)
    }
}
