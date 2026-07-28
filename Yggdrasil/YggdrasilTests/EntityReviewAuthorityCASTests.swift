import XCTest
import YggdrasilCore
@testable import Yggdrasil

final class EntityReviewAuthorityCASTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let reviewURL: URL
        let coordinator: RecordingCoordinator
        let store: VaultFileStore
        let model: MimerEntityCompareModel
    }

    private enum MutationAction {
        case merge
        case reject
        case undo
    }

    @MainActor
    func testConcurrentDecisionBlocksMergeWithoutWriting() async throws {
        try await assertConcurrentDecisionBlocksMutation(
            action: .merge,
            concurrentDecision: """
              - queue_entry_id: queue-1
                action: reject
                from_id: mention-1
                into_id: ""
                decided_at: 2026-07-28T09:00:01Z
            """
        )
    }

    @MainActor
    func testConcurrentDecisionBlocksRejectWithoutWriting() async throws {
        try await assertConcurrentDecisionBlocksMutation(
            action: .reject,
            concurrentDecision: """
              - queue_entry_id: queue-1
                action: merge
                from_id: mention-1
                into_id: ent:anna
                decided_at: 2026-07-28T09:00:01Z
            """
        )
    }

    @MainActor
    func testConcurrentDecisionBlocksUndoWithoutWriting() async throws {
        try await assertConcurrentDecisionBlocksMutation(
            action: .undo,
            concurrentDecision: """
              - queue_entry_id: queue-1
                action: reject
                from_id: mention-1
                into_id: ""
                decided_at: 2026-07-28T09:00:01Z
            """
        )
    }

    @MainActor
    func testNewerEquivalentDecisionRowBlocksMergeWithoutWriting() async throws {
        try await assertConcurrentDecisionBlocksMutation(
            action: .merge,
            concurrentDecision: """
              - queue_entry_id: queue-1
                action: undo
                decided_at: 2026-07-28T09:00:01Z
            """
        )
    }

    @MainActor
    func testNewerEquivalentDecisionRowBlocksRejectWithoutWriting() async throws {
        try await assertConcurrentDecisionBlocksMutation(
            action: .reject,
            concurrentDecision: """
              - queue_entry_id: queue-1
                action: undo
                decided_at: 2026-07-28T09:00:01Z
            """
        )
    }

    @MainActor
    func testNewerEquivalentDecisionRowBlocksUndoWithoutWriting() async throws {
        try await assertConcurrentDecisionBlocksMutation(
            action: .undo,
            concurrentDecision: """
              - queue_entry_id: queue-1
                action: merge
                from_id: mention-1
                into_id: ent:anna
                decided_at: 2026-07-28T09:00:01Z
            """
        )
    }

    @MainActor
    func testSameQueueIDRequeueBlocksMergeWithoutWriting() async throws {
        try await assertSameQueueIDRequeueBlocksMutation(action: .merge)
    }

    @MainActor
    func testSameQueueIDRequeueBlocksRejectWithoutWriting() async throws {
        try await assertSameQueueIDRequeueBlocksMutation(action: .reject)
    }

    @MainActor
    func testSameQueueIDRequeueBlocksUndoWithoutWriting() async throws {
        try await assertSameQueueIDRequeueBlocksMutation(action: .undo)
    }
}

extension EntityReviewAuthorityCASTests {
    @MainActor
    private func assertConcurrentDecisionBlocksMutation(
        action: MutationAction,
        concurrentDecision: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await prepare(action, in: fixture.model)
        let replacement = """
        ---
        pending:
          - queue_entry_id: queue-1
            mention_id: mention-1
            surface_form: "Anna"
            resolution: ambiguous
            confidence: 0.71
            candidate_entity_ids: [ent:anna]
        decisions:
        \(concurrentDecision)
        ---
        """
        try replacement.write(to: fixture.reviewURL, atomically: true, encoding: .utf8)
        let beforeAction = try await fixture.store.read(HeimdalPaths.entityReview)

        await perform(action, in: fixture.model)
        let afterAction = try await fixture.store.read(HeimdalPaths.entityReview)

        XCTAssertEqual(
            afterAction,
            beforeAction,
            "a fresh latest-decision mismatch must be a byte-identical no-write",
            file: file,
            line: line
        )
        assertStaleAuthorityFailure(fixture.model, file: file, line: line)
    }

    @MainActor
    private func assertSameQueueIDRequeueBlocksMutation(
        action: MutationAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await prepare(action, in: fixture.model)
        let replacement = """
        ---
        # Preserve this provenance and source formatting on a failed CAS.
        agent_provenance:
          author: another-writer
          written_at: 2026-07-28T09:00:01Z
          origin: direct-fs
        pending:
          - queue_entry_id: queue-1
            mention_id: mention-2
            surface_form: "Bea"
            resolution: ambiguous
            confidence: 0.42
            candidate_entity_ids: [ent:bea, ent:beatrice]
            queued_at: 2026-07-28T09:00:01Z
        \(decisionsBlock(for: action))
        ---

        Preserve these source bytes exactly.
        """
        try replacement.write(to: fixture.reviewURL, atomically: true, encoding: .utf8)
        let beforeAction = try Data(contentsOf: fixture.reviewURL)
        let writesBeforeAction = writeCount(in: fixture.coordinator)

        await perform(action, in: fixture.model)

        XCTAssertEqual(
            try Data(contentsOf: fixture.reviewURL),
            beforeAction,
            "a same-queue-id requeue must remain a byte-identical no-write",
            file: file,
            line: line
        )
        XCTAssertEqual(
            writeCount(in: fixture.coordinator),
            writesBeforeAction,
            "a failed pending/candidate CAS must not coordinate a write",
            file: file,
            line: line
        )
        assertStaleAuthorityFailure(fixture.model, file: file, line: line)
    }

    @MainActor
    private func prepare(_ action: MutationAction, in model: MimerEntityCompareModel) async {
        await model.load()
        model.selectCandidate("ent:anna")
        if action == .undo {
            await model.merge()
            XCTAssertEqual(model.effectiveDecision, .merge(candidateID: "ent:anna"))
        }
    }

    @MainActor
    private func perform(_ action: MutationAction, in model: MimerEntityCompareModel) async {
        switch action {
        case .merge:
            await model.merge()
        case .reject:
            await model.reject()
        case .undo:
            await model.undo()
        }
    }

    private func decisionsBlock(for action: MutationAction) -> String {
        guard action == .undo else { return "decisions: []" }
        return """
        decisions:
          - queue_entry_id: queue-1
            action: merge
            from_id: mention-1
            into_id: ent:anna
            decided_at: 2026-07-28T09:00:00Z
        """
    }

    private func writeCount(in coordinator: RecordingCoordinator) -> Int {
        coordinator.operations.filter { $0 == .write }.count
    }

    @MainActor
    private func assertStaleAuthorityFailure(
        _ model: MimerEntityCompareModel,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertTrue(
            model.loadError?.contains("changed after it was loaded") == true,
            file: file,
            line: line
        )
        XCTAssertTrue(model.pending.isEmpty, file: file, line: line)
        XCTAssertNil(model.selectedEntryID, file: file, line: line)
        XCTAssertNil(model.effectiveDecision, file: file, line: line)
        XCTAssertFalse(model.canMerge, file: file, line: line)
        XCTAssertFalse(model.canReject, file: file, line: line)
        XCTAssertFalse(model.canUndo, file: file, line: line)
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntityReviewAuthorityCASTests-\(UUID().uuidString)")
        let reviewURL = root.appendingPathComponent(HeimdalPaths.entityReview)
        try FileManager.default.createDirectory(
            at: reviewURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        pending:
          - queue_entry_id: queue-1
            mention_id: mention-1
            surface_form: "Anna"
            resolution: ambiguous
            confidence: 0.71
            candidate_entity_ids: [ent:anna]
        decisions: []
        ---
        """.write(to: reviewURL, atomically: true, encoding: .utf8)
        let coordinator = RecordingCoordinator()
        let store = VaultFileStore(rootURL: root, coordinator: coordinator)
        let model = MimerEntityCompareModel(
            fileStore: store,
            timestampProvider: { "2026-07-28T09:00:00Z" }
        )
        return Fixture(
            root: root,
            reviewURL: reviewURL,
            coordinator: coordinator,
            store: store,
            model: model
        )
    }
}
