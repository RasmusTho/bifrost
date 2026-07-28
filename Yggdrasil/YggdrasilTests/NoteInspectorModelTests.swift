import XCTest
import YggdrasilCore
@testable import Yggdrasil

final class NoteInspectorModelTests: XCTestCase {
    private struct EntityReviewValidationFixture {
        let root: URL
        let reviewURL: URL
        let store: VaultFileStore
        let model: MimerEntityCompareModel
    }

    private enum EntityReviewMutationAction: Equatable {
        case merge
        case reject
        case undo
    }

    func testInspectorFieldsFromFrontmatterAndMissingUuid() throws {
        let inspected = NoteInspectorModel(
            text: """
            ---
            uuid: note-123
            zone: Projects
            origin: human
            agent_provenance:
              author: bifrost-ios
              trace: test-trace
            ---

            # A note
            """,
            modificationDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(inspected.uuid, "note-123")
        XCTAssertEqual(inspected.zone, "Projects")
        XCTAssertEqual(inspected.origin, "human")
        XCTAssertEqual(inspected.agentProvenance["author"], "bifrost-ios")
        XCTAssertEqual(inspected.agentProvenance["trace"], "test-trace")
        XCTAssertNotNil(inspected.modifiedDescription)

        let missingUUID = NoteInspectorModel(text: "# Plain note", modificationDate: nil)
        XCTAssertNil(missingUUID.uuid)
        XCTAssertEqual(missingUUID.uuidDescription, "No uuid present")
    }

    func testCandidateResolutionIncludingMissingNotes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimerEntityCandidateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let existingPath = MimerEntityCandidateResolver.registerPath(for: "ent:anna")
        let existingURL = root.appendingPathComponent(existingPath)
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        entity_id: ent:anna
        label: Anna Andersson
        kind: person
        lifecycle: canonical
        ---

        # Anna Andersson

        Existing canonical context.
        """.write(to: existingURL, atomically: true, encoding: .utf8)

        let candidates = await MimerEntityCandidateResolver.resolve(
            ["ent:anna", "ent:missing"],
            using: VaultFileStore(rootURL: root)
        )

        XCTAssertEqual(candidates.map(\.entityID), ["ent:anna", "ent:missing"])
        XCTAssertEqual(candidates[0].relativePath, "_heimdal/register/ent-anna.md")
        XCTAssertEqual(candidates[0].label, "Anna Andersson")
        XCTAssertEqual(candidates[0].kind, "person")
        XCTAssertEqual(candidates[0].lifecycle, "canonical")
        XCTAssertEqual(candidates[0].availability, .note)
        XCTAssertTrue(candidates[0].markdown.contains("Existing canonical context."))

        XCTAssertEqual(candidates[1].relativePath, "_heimdal/register/ent-missing.md")
        XCTAssertEqual(candidates[1].label, "ent:missing")
        XCTAssertEqual(candidates[1].availability, .missing)
        XCTAssertEqual(candidates[1].markdown, "")
    }
}

extension NoteInspectorModelTests {
    @MainActor
    func testUnsupportedEntityReviewActionFailsClosed() async throws {
        try await assertEntityReviewLoadFailsClosed(
            invalidReview: """
            ---
            pending:
              - queue_entry_id: queue-1
                mention_id: mention-1
                surface_form: "Anna"
                resolution: ambiguous
                confidence: 0.71
                candidate_entity_ids: [ent:anna]
            decisions:
              - queue_entry_id: queue-1
                action: split
                decided_at: 2026-07-28T09:00:00Z
            ---
            """,
            expectedError: "decisions[0] has unsupported action 'split'"
        )
    }

    @MainActor
    func testEntityReviewMergeWithoutIntoIDFailsClosed() async throws {
        try await assertEntityReviewLoadFailsClosed(
            invalidReview: """
            ---
            pending:
              - queue_entry_id: queue-1
                mention_id: mention-1
                surface_form: "Anna"
                resolution: ambiguous
                confidence: 0.71
                candidate_entity_ids: [ent:anna]
            decisions:
              - queue_entry_id: queue-1
                action: merge
                from_id: mention-1
                decided_at: 2026-07-28T09:00:00Z
            ---
            """,
            expectedError: "decisions[0].into_id must be a non-empty string"
        )
    }

    @MainActor
    func testMalformedEntityReviewPendingRowFailsClosed() async throws {
        try await assertEntityReviewLoadFailsClosed(
            invalidReview: """
            ---
            pending:
              - queue_entry_id: queue-1
                surface_form: "Anna"
                resolution: ambiguous
                confidence: 0.71
                candidate_entity_ids: [ent:anna]
            decisions: []
            ---
            """,
            expectedError: "pending[0].mention_id must be a non-empty string"
        )
    }

    @MainActor
    func testInvalidEntityReviewConfidenceFailsClosedBeforePublication() async throws {
        for invalidConfidence in ["1e309", "NaN", "-0.01", "1.01"] {
            try await assertEntityReviewLoadFailsClosed(
                invalidReview: """
                ---
                pending:
                  - queue_entry_id: queue-1
                    mention_id: mention-1
                    surface_form: "Anna"
                    resolution: ambiguous
                    confidence: \(invalidConfidence)
                    candidate_entity_ids: [ent:anna]
                decisions: []
                ---
                """,
                expectedError: "confidence must be finite and between 0 and 1 when present"
            )
        }
    }

    @MainActor
    func testConcurrentDecisionBlocksMergeWithoutWriting() async throws {
        try await assertFreshConcurrentDecisionBlocksMutation(
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
        try await assertFreshConcurrentDecisionBlocksMutation(
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
        try await assertFreshConcurrentDecisionBlocksMutation(
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
    func testFreshUnsupportedEntityReviewActionBlocksMergeWithoutWriting() async throws {
        try await assertFreshInvalidEntityReviewBlocksMutation(
            invalidReview: """
            ---
            pending:
              - queue_entry_id: queue-1
                mention_id: mention-1
                surface_form: "Anna"
                resolution: ambiguous
                confidence: 0.71
                candidate_entity_ids: [ent:anna]
            decisions:
              - queue_entry_id: queue-1
                action: split
                decided_at: 2026-07-28T09:00:00Z
            ---
            """,
            action: .merge,
            expectedError: "decisions[0] has unsupported action 'split'"
        )
    }

    @MainActor
    func testFreshMergeMissingFromIDBlocksMergeWithoutWriting() async throws {
        try await assertFreshInvalidEntityReviewBlocksMutation(
            invalidReview: """
            ---
            pending:
              - queue_entry_id: queue-1
                mention_id: mention-1
                surface_form: "Anna"
                resolution: ambiguous
                confidence: 0.71
                candidate_entity_ids: [ent:anna]
            decisions:
              - queue_entry_id: queue-1
                action: merge
                into_id: ent:anna
                decided_at: 2026-07-28T09:00:00Z
            ---
            """,
            action: .merge,
            expectedError: "decisions[0].from_id must be a non-empty string"
        )
    }

    @MainActor
    func testFreshInvalidUndoShapeBlocksUndoWithoutWriting() async throws {
        try await assertFreshInvalidEntityReviewBlocksMutation(
            invalidReview: """
            ---
            pending:
              - queue_entry_id: queue-1
                mention_id: mention-1
                surface_form: "Anna"
                resolution: ambiguous
                confidence: 0.71
                candidate_entity_ids: [ent:anna]
            decisions:
              - queue_entry_id: queue-1
                action: undo
                from_id: mention-1
                decided_at: 2026-07-28T09:00:00Z
            ---
            """,
            action: .undo,
            expectedError: "action 'undo' must compensate by queue_entry_id only"
        )
    }

    @MainActor
    private func assertEntityReviewLoadFailsClosed(
        invalidReview: String,
        expectedError: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try makeEntityReviewValidationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.model.load()
        fixture.model.selectCandidate("ent:anna")
        XCTAssertTrue(fixture.model.canMerge, file: file, line: line)
        XCTAssertTrue(fixture.model.canReject, file: file, line: line)
        await fixture.model.merge()
        XCTAssertTrue(fixture.model.canUndo, file: file, line: line)

        try invalidReview.write(to: fixture.reviewURL, atomically: true, encoding: .utf8)
        let beforeGuardedActions = try await fixture.store.read(HeimdalPaths.entityReview)
        await fixture.model.load()

        XCTAssertTrue(fixture.model.pending.isEmpty, file: file, line: line)
        XCTAssertNil(fixture.model.selectedEntryID, file: file, line: line)
        XCTAssertNil(fixture.model.effectiveDecision, file: file, line: line)
        XCTAssertFalse(fixture.model.canMerge, file: file, line: line)
        XCTAssertFalse(fixture.model.canReject, file: file, line: line)
        XCTAssertFalse(fixture.model.canUndo, file: file, line: line)
        XCTAssertTrue(
            fixture.model.loadError?.contains(expectedError) == true,
            file: file,
            line: line
        )

        await fixture.model.merge()
        await fixture.model.reject()
        await fixture.model.undo()
        let afterGuardedActions = try await fixture.store.read(HeimdalPaths.entityReview)
        XCTAssertEqual(
            afterGuardedActions,
            beforeGuardedActions,
            "disabled authority-bearing actions must not write",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertFreshInvalidEntityReviewBlocksMutation(
        invalidReview: String,
        action: EntityReviewMutationAction,
        expectedError: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try makeEntityReviewValidationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.model.load()
        fixture.model.selectCandidate("ent:anna")
        switch action {
        case .merge:
            XCTAssertTrue(fixture.model.canMerge, file: file, line: line)
        case .reject:
            XCTAssertTrue(fixture.model.canReject, file: file, line: line)
        case .undo:
            await fixture.model.merge()
            XCTAssertTrue(fixture.model.canUndo, file: file, line: line)
        }

        try invalidReview.write(to: fixture.reviewURL, atomically: true, encoding: .utf8)
        let beforeAction = try await fixture.store.read(HeimdalPaths.entityReview)

        switch action {
        case .merge:
            await fixture.model.merge()
        case .reject:
            await fixture.model.reject()
        case .undo:
            await fixture.model.undo()
        }

        let afterAction = try await fixture.store.read(HeimdalPaths.entityReview)
        XCTAssertEqual(
            afterAction,
            beforeAction,
            "invalid fresh authority must remain byte-identical",
            file: file,
            line: line
        )
        XCTAssertTrue(fixture.model.pending.isEmpty, file: file, line: line)
        XCTAssertNil(fixture.model.selectedEntryID, file: file, line: line)
        XCTAssertNil(fixture.model.effectiveDecision, file: file, line: line)
        XCTAssertFalse(fixture.model.canMerge, file: file, line: line)
        XCTAssertFalse(fixture.model.canReject, file: file, line: line)
        XCTAssertFalse(fixture.model.canUndo, file: file, line: line)
        XCTAssertTrue(
            fixture.model.loadError?.contains(expectedError) == true,
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertFreshConcurrentDecisionBlocksMutation(
        action: EntityReviewMutationAction,
        concurrentDecision: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try makeEntityReviewValidationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.model.load()
        fixture.model.selectCandidate("ent:anna")
        if action == .undo {
            await fixture.model.merge()
            XCTAssertEqual(fixture.model.effectiveDecision, .merge(candidateID: "ent:anna"))
        }

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

        switch action {
        case .merge:
            await fixture.model.merge()
        case .reject:
            await fixture.model.reject()
        case .undo:
            await fixture.model.undo()
        }

        let afterAction = try await fixture.store.read(HeimdalPaths.entityReview)
        XCTAssertEqual(
            afterAction,
            beforeAction,
            "a fresh effective-intent mismatch must be a byte-identical no-write",
            file: file,
            line: line
        )
        XCTAssertTrue(
            fixture.model.loadError?.contains("changed after it was loaded") == true,
            file: file,
            line: line
        )
        assertEntityReviewActionsCleared(fixture.model, file: file, line: line)
    }

    @MainActor
    private func assertEntityReviewActionsCleared(
        _ model: MimerEntityCompareModel,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertTrue(model.pending.isEmpty, file: file, line: line)
        XCTAssertNil(model.selectedEntryID, file: file, line: line)
        XCTAssertNil(model.effectiveDecision, file: file, line: line)
        XCTAssertFalse(model.canMerge, file: file, line: line)
        XCTAssertFalse(model.canReject, file: file, line: line)
        XCTAssertFalse(model.canUndo, file: file, line: line)
    }

    @MainActor
    private func makeEntityReviewValidationFixture() throws -> EntityReviewValidationFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimerEntityReviewValidationTests-\(UUID().uuidString)")
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
        let store = VaultFileStore(rootURL: root)
        let model = MimerEntityCompareModel(
            fileStore: store,
            timestampProvider: { "2026-07-28T09:00:00Z" }
        )
        return EntityReviewValidationFixture(
            root: root,
            reviewURL: reviewURL,
            store: store,
            model: model
        )
    }
}
