import XCTest
@testable import YggdrasilCore

final class HeimdalNotesTests: XCTestCase {
    func testEntityReviewAddDecisionIsIdempotent() throws {
        let text = """
        ---
        pending:
          - queue_entry_id: q1
            mention_id: m1
            surface_form: "Alice"
            resolution: candidate
            confidence: 0.82
        decisions: []
        ---
        """
        let doc = try FrontmatterDocument.parse(text)
        var note = EntityReviewNote(document: doc)
        XCTAssertEqual(note.pending.count, 1)
        XCTAssertEqual(note.pending[0].surfaceForm, "Alice")

        note.addDecision(queueEntryId: "q1", action: "merge", fromId: "e1", intoId: "e2", decidedAt: "2026-07-06T00:00:00Z")
        note.addDecision(queueEntryId: "q1", action: "merge", fromId: "e1", intoId: "e2", decidedAt: "2026-07-06T00:00:01Z")

        let decisions = note.document.frontmatter["decisions"]?.arrayValue ?? []
        XCTAssertEqual(decisions.count, 1, "duplicate decision for the same queue entry + action must not be appended twice")
    }

    func testAttentionOverrideAppendPreservesCountsAndReasons() throws {
        let text = """
        ---
        overrides: []
        counts:
          attended:interested: 4
        reasons:
          - interested
        ---
        """
        let doc = try FrontmatterDocument.parse(text)
        var note = AttentionNote(document: doc)
        note.addOverride(AttentionOverride(
            itemId: "item-1",
            originalDecision: "skipped",
            overriddenDecision: "attended",
            note: "reconsidered",
            overriddenAt: "2026-07-06T08:00:00Z"
        ))
        XCTAssertEqual(note.overrides.count, 1)
        XCTAssertEqual(note.counts.first?.key, "attended:interested")
        XCTAssertEqual(note.counts.first?.count, 4)
    }

    func testConsentNoteIsReadOnlyView() throws {
        let text = """
        ---
        grants:
          - grant_ref: g1
            basis: self_record
            scope: voice_memo
            granted_at: 2026-07-01T00:00:00Z
        withhold_span_review:
          enabled: false
        retention_erasure:
          supported: false
        ---
        """
        let doc = try FrontmatterDocument.parse(text)
        let note = ConsentNote(document: doc)
        XCTAssertEqual(note.grants.count, 1)
        XCTAssertEqual(note.grants[0].basis, "self_record")
        XCTAssertFalse(note.withholdReviewEnabled)
        XCTAssertFalse(note.retentionErasureSupported)
    }

    func testListNoteAppendsBodyLineWithoutClobberingExisting() throws {
        let text = """
        ---
        watched: []
        last_synced: 2026-07-01T00:00:00Z
        ---

        - [2026-07-01T00:00:00Z] source=chat target='old.com' | prior entry
        """
        let doc = try FrontmatterDocument.parse(text)
        var note = ListNote.watchlist(document: doc)
        note.addEntry("new.com", source: "chat", target: "new.com", note: "added via Mimer", timestamp: "2026-07-06T09:00:00Z")

        XCTAssertEqual(note.entries, ["new.com"])
        XCTAssertTrue(note.document.body.contains("prior entry"))
        XCTAssertTrue(note.document.body.contains("added via Mimer"))
    }
}
