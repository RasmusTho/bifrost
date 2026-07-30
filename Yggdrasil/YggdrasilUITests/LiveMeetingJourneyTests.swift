import XCTest
import UIKit

/// The composed CDLM-09 journey on the iPad destination: record → disconnect →
/// reconnect → end.
///
/// The hub is scripted (unreachable for the first read, answering afterwards)
/// because `KD-4384-RAWKEY` means no live hub can answer today.
final class LiveMeetingJourneyTests: XCTestCase {
    func testMeetingWithReconnectJourney() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only meeting surface verification")

        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing",
            "-ui-testing-auth-unlocked",
            "-ui-testing-uat-fixture",
            UUID().uuidString,
            "-ui-testing-live-meeting"
        ]
        app.launch()

        let meetingTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Meeting"))
            .firstMatch
        XCTAssertTrue(meetingTab.waitForExistence(timeout: 15))
        meetingTab.tap()

        // Both regions exist and are structurally distinct.
        let aiRegion = app.descendants(matching: .any).matching(identifier: "meeting.region.ai").firstMatch
        let userRegion = app.descendants(matching: .any).matching(identifier: "meeting.region.user").firstMatch
        XCTAssertTrue(aiRegion.waitForExistence(timeout: 10))
        XCTAssertTrue(userRegion.waitForExistence(timeout: 10))

        // Disconnected: the AI region says so rather than looking current.
        let stale = app.descendants(matching: .any).matching(identifier: "meeting.ai.stale").firstMatch
        XCTAssertTrue(stale.waitForExistence(timeout: 10), "An unanswering hub must be stated, not hidden.")

        // The user can still write, and the note is visible immediately.
        let editor = app.textFields["meeting.user.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("my note during the meeting")
        app.buttons["meeting.user.save"].tap()

        let note = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.user.note."))
            .firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "A note must be visible the moment it is written.")

        // Reconnect: reconciliation renders as a new revision.
        app.buttons["meeting.reconnect"].tap()
        let revision = app.descendants(matching: .any).matching(identifier: "meeting.ai.revision").firstMatch
        XCTAssertTrue(revision.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label != %@", "Revision 0"), evaluatedWith: revision)
        waitForExpectations(timeout: 15)

        // End: the final view reports three artifacts.
        app.buttons["meeting.end"].tap()
        let artifacts = app.descendants(matching: .any).matching(identifier: "meeting.final.artifacts").firstMatch
        XCTAssertTrue(artifacts.waitForExistence(timeout: 15))
        XCTAssertTrue(artifacts.label.contains("Notes 1"), "The user's note must survive into the final view.")
    }
}
