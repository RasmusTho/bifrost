import XCTest
import UIKit

/// The composed CDLM-05 journey on the iPad destination: a capture that the hub
/// has not yet reported on shows a locally-evidenced state, and only once the
/// hub actually answers does it advance to `complete`.
///
/// The hub is scripted to be unreachable for the first query and to answer
/// afterwards (`-ui-testing-transfer-queue`), which is the offline → complete
/// arc without needing a live hub — necessary today because `KD-4384-RAWKEY`
/// means a real hub refuses every admission.
final class TransferQueueJourneyTests: XCTestCase {
    func testOfflineToCompleteJourney() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only queue surface verification")

        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing",
            "-ui-testing-auth-unlocked",
            "-ui-testing-uat-fixture",
            UUID().uuidString,
            "-ui-testing-transfer-queue",
            // Isolate this journey's durable state. The outbox is shared across
            // launches, so without this reset another journey's seeded item can
            // be the row this one inspects.
            "-ui-testing-reset-outbox"
        ]
        app.launch()

        let queueTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Queue"))
            .firstMatch
        XCTAssertTrue(queueTab.waitForExistence(timeout: 15))
        queueTab.tap()

        let queue = app.descendants(matching: .any).matching(identifier: "transferQueue").firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: 10))

        // The hub did not answer the cold-launch query, so the item renders from
        // local evidence alone and the unreachable hub is visible rather than
        // silently hidden behind an optimistic state.
        let unreachable = app.descendants(matching: .any)
            .matching(identifier: "transferQueue.hubUnreachable")
            .firstMatch
        XCTAssertTrue(unreachable.waitForExistence(timeout: 10), "An unanswering hub must be stated, not hidden.")
        XCTAssertFalse(
            app.staticTexts["complete"].exists,
            "No item may show a hub-derived state before the hub has answered."
        )

        let localState = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transferQueue.state."))
            .firstMatch
        XCTAssertTrue(localState.waitForExistence(timeout: 10))
        XCTAssertEqual(
            localState.label, "backend durably received",
            "The seeded receipt is durable local evidence, so that is the honest starting state."
        )

        // Hub comes up: the next refresh carries real evidence.
        let refresh = app.buttons["transferQueue.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()

        let advanced = NSPredicate(format: "label == %@", "complete")
        expectation(for: advanced, evaluatedWith: localState)
        waitForExpectations(timeout: 15)

        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "transferQueue.hubUnreachable").firstMatch.exists,
            "Once the hub answers, the unreachable notice must clear."
        )
    }
}
