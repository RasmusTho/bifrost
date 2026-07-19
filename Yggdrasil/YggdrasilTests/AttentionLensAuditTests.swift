import XCTest
import YggdrasilCore

final class AttentionLensAuditTests: XCTestCase {
    func testManualOverrideAuditMatchesAction() {
        let override = AttentionOverride.manualOverride(
            itemId: "item-1",
            action: "attended",
            note: "Important today",
            overriddenAt: "2026-07-19T12:00:00Z"
        )

        XCTAssertEqual(override.originalDecision, "unknown")
        XCTAssertEqual(override.overriddenDecision, "attended")
    }
}
