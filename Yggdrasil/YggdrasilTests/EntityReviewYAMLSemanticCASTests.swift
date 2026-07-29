import XCTest
import YggdrasilCore
@testable import Yggdrasil

private final class SemanticInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class EntityReviewYAMLSemanticCASTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let reviewURL: URL
        let coordinator: RecordingCoordinator
        let provenanceInvocations: SemanticInvocationCounter
        let model: MimerEntityCompareModel
    }

    @MainActor
    func testInlineCommentPendingChangeBlocksMergeWithoutWriting() async throws {
        let fixture = try makeFixture(
            source: reviewDocument(
                pendingExtension: "\"foo # note\"",
                decisionExtension: nil
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.model.load()
        fixture.model.selectCandidate("ent:anna")
        try reviewDocument(
            pendingExtension: "foo # note",
            decisionExtension: nil
        ).write(to: fixture.reviewURL, atomically: true, encoding: .utf8)
        let beforeAction = try Data(contentsOf: fixture.reviewURL)

        await fixture.model.merge()

        assertFailClosed(fixture.model)
        try assertNoPublication(fixture, expectedSource: beforeAction)
    }

    @MainActor
    func testInlineCommentDecisionChangeBlocksUndoWithoutWriting() async throws {
        let fixture = try makeFixture(
            source: reviewDocument(
                pendingExtension: nil,
                decisionExtension: "\"foo # note\""
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.model.load()
        XCTAssertTrue(fixture.model.canUndo)
        try reviewDocument(
            pendingExtension: nil,
            decisionExtension: "foo # note"
        ).write(to: fixture.reviewURL, atomically: true, encoding: .utf8)
        let beforeAction = try Data(contentsOf: fixture.reviewURL)

        await fixture.model.undo()

        assertFailClosed(fixture.model)
        try assertNoPublication(fixture, expectedSource: beforeAction)
    }

    @MainActor
    private func makeFixture(source: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntityReviewYAMLSemanticCASTests-\(UUID().uuidString)")
        let reviewURL = root.appendingPathComponent(HeimdalPaths.entityReview)
        try FileManager.default.createDirectory(
            at: reviewURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: reviewURL, atomically: true, encoding: .utf8)
        let coordinator = RecordingCoordinator()
        let provenanceInvocations = SemanticInvocationCounter()
        let store = VaultFileStore(
            rootURL: root,
            coordinator: coordinator,
            provenanceTimestampProvider: {
                provenanceInvocations.increment()
                return "2026-07-28T09:00:00Z"
            }
        )
        return Fixture(
            root: root,
            reviewURL: reviewURL,
            coordinator: coordinator,
            provenanceInvocations: provenanceInvocations,
            model: MimerEntityCompareModel(
                fileStore: store,
                timestampProvider: { "2026-07-28T09:00:00Z" }
            )
        )
    }

    private func reviewDocument(
        pendingExtension: String?,
        decisionExtension: String?
    ) -> String {
        let pendingExtensionLine = pendingExtension.map { "\n    extension: \($0)" } ?? ""
        let decisions = decisionExtension.map {
            """
            decisions:
              - queue_entry_id: queue-1
                action: merge
                from_id: mention-1
                into_id: ent:anna
                decided_at: 2026-07-28T09:00:00Z
                extension: \($0)
            """
        } ?? "decisions: []"
        return """
        ---
        pending:
          - queue_entry_id: queue-1
            mention_id: mention-1
            surface_form: "Anna"
            resolution: ambiguous
            confidence: 0.71
            candidate_entity_ids: [ent:anna]\(pendingExtensionLine)
        \(decisions)
        ---
        """
    }

    private func assertNoPublication(_ fixture: Fixture, expectedSource: Data) throws {
        XCTAssertEqual(try Data(contentsOf: fixture.reviewURL), expectedSource)
        XCTAssertEqual(fixture.coordinator.operations.filter { $0 == .write }.count, 0)
        XCTAssertEqual(fixture.provenanceInvocations.value, 0)
    }

    @MainActor
    private func assertFailClosed(_ model: MimerEntityCompareModel) {
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.selectedEntryID)
        XCTAssertNil(model.effectiveDecision)
        XCTAssertFalse(model.canMerge)
        XCTAssertFalse(model.canReject)
        XCTAssertFalse(model.canUndo)
    }
}
