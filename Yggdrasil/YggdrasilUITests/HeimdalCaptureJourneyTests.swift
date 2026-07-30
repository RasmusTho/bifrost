import XCTest
import UIKit

/// HCAP-09 composed capture journeys, recomposed against the CDLM foundation.
///
/// These replace an earlier set written against the HCAP-03 watched-folder lane,
/// where placement was the terminal event and the client deleted its original
/// afterwards. CDLM-03 retired those semantics — placement is no longer the end
/// of the story, and nothing is deleted until the hub's durable-acceptance
/// receipt is persisted on the device — so a journey ending at "delivered" would
/// now assert a contract the system does not have.
///
/// ## Journey isolation
///
/// The outbox and capture staging are durable and shared across launches, which
/// is exactly what made the earlier attempt's journeys pass individually and
/// fail as a suite. Every journey here launches with `-ui-testing-reset-outbox`
/// and `-ui-testing-reset-capture-staging` and its own fixture identity, so no
/// journey can observe another's leftovers.
///
/// ## What is deliberately not automated here
///
/// Starting the microphone is not driveable from XCUITest in this environment:
/// `AVAudioApplication.requestRecordPermission` raises a system alert that
/// interruption monitors handle unreliably, and pre-granting via
/// `simctl privacy` does not survive the install `xcodebuild test` performs.
/// Attempts to drive it produced a journey that passed once and not
/// reproducibly, which is worse than not claiming it at all.
///
/// So these journeys seed a finalized capture into the outbox and prove what
/// this slice's scope refresh is actually about — durable custody,
/// receipt-gated release, and disk-rebuilt truth. That a recording *starts and
/// finalizes* is covered by `CaptureRecorderTests` at the unit level and by the
/// operator device walkthrough, which is where this issue puts truths only real
/// hardware can prove.
final class HeimdalCaptureJourneyTests: XCTestCase {
    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
    }

    // MARK: - Journey 1

    /// Capture and durable custody: a finalized capture is retained in the
    /// outbox as `pending locally`, and only once the hub's receipt is persisted
    /// does it advance — the arc that replaced delete-after-placement.
    func testCaptureAndDurableCustodyJourney() throws {
        let app = launch(extraArguments: [
            "-ui-testing-seed-pending-capture",
            "-ui-testing-outbox-accepting"
        ])

        // The capture is accounted for in the queue, and it is *not* gone: the
        // watched-folder lane would have deleted it by now.
        openQueueTab(in: app)
        let state = firstQueueState(in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 20), "A finalized capture must appear in the durable queue.")
        XCTAssertEqual(
            state.label, "pending locally",
            "Before any hub receipt the only truthful state is pending locally."
        )

        // Drive the transfer. The hub admits, the receipt persists, and only
        // then may the original be released — the coordinator refuses otherwise.
        app.buttons["transferQueue.refresh"].tap()
        let advanced = NSPredicate(format: "label == %@ OR label == %@", "backend durably received", "complete")
        expectation(for: advanced, evaluatedWith: state)
        waitForExpectations(timeout: 30)
    }

    // MARK: - Journey 2

    /// Identity, health, and the queue surface: register → consent and
    /// registration shown → the health panel and gap-log readout are observable
    /// → the queue surface reports the same world truthfully, and says so when
    /// the hub is not answering.
    ///
    /// Forcing a real `delivery_failed_aged` gap needs a live capture failing
    /// delivery, so that step moves to the walkthrough; what is asserted here is
    /// that the gap-log readout and health panel exist and are honest.
    func testIdentityHealthAndQueueJourney() throws {
        let app = launch(extraArguments: [
            "-ui-testing-seed-pending-capture",
            "-ui-testing-capture-folder-unbound",
            "-ui-testing-fast-gap-threshold"
        ])
        navigateToHeimdalTab(in: app)

        // JC: the consent grant surfaces, and registration is truthful.
        XCTAssertTrue(app.staticTexts["Standing grant: fixture consent"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["heimdal.registration.register"].exists)
        app.buttons["heimdal.registration.register"].tap()
        let registered = app.descendants(matching: .any)
            .matching(identifier: "heimdal.registration.registered")
            .firstMatch
        XCTAssertTrue(registered.waitForExistence(timeout: 20), "JC must show the device as registered.")

        let gapCount = scrollTo(identifier: "heimdal.registration.gapLogCount", in: app)
        XCTAssertTrue(gapCount.exists, "The device note's gap-log count must be observable.")

        // JD: the live health panel is runtime state and always present.
        XCTAssertTrue(scrollTo(identifier: "heimdal.health.phase", in: app).exists)
        XCTAssertTrue(scrollTo(identifier: "heimdal.health.queueDepth", in: app).exists)

        // The queue surface reports the same world. With no hub answering it
        // must say so rather than showing an optimistic state.
        openQueueTab(in: app)
        let unreachable = app.descendants(matching: .any)
            .matching(identifier: "transferQueue.hubUnreachable")
            .firstMatch
        XCTAssertTrue(
            unreachable.waitForExistence(timeout: 20),
            "An unanswering hub must be stated on the queue surface, not hidden."
        )
        XCTAssertFalse(
            app.staticTexts["backend durably received"].exists,
            "No item may claim durable acceptance while the hub has answered nothing."
        )
    }

    // MARK: - Journey 3

    /// Recovery and disk-rebuilt truth: relaunch mid-queue → the queue is
    /// rebuilt from disk alone, the original is still there, and no state is
    /// fabricated by the restart.
    func testRecoveryAndDiskRebuiltTruthJourney() throws {
        let fixture = UUID().uuidString
        let app = launch(fixture: fixture, extraArguments: ["-ui-testing-seed-pending-capture"])
        openQueueTab(in: app)
        let before = firstQueueState(in: app)
        XCTAssertTrue(before.waitForExistence(timeout: 20))
        let stateBeforeRelaunch = before.label
        XCTAssertEqual(stateBeforeRelaunch, "pending locally")

        // Relaunch into the same fixture *without* resetting the outbox, so the
        // queue must come back from disk rather than from a fresh fixture.
        app.terminate()
        // No seeding and no reset on relaunch: whatever appears must come from
        // disk, not from a fixture being re-created.
        let relaunched = launch(fixture: fixture, resetsOutbox: false)
        openQueueTab(in: relaunched)

        let after = firstQueueState(in: relaunched)
        XCTAssertTrue(after.waitForExistence(timeout: 20), "The queue must rebuild from disk alone after relaunch.")
        XCTAssertEqual(
            after.label, stateBeforeRelaunch,
            "A relaunch must reproduce the durable state exactly — neither losing the item nor advancing it."
        )
        XCTAssertFalse(
            relaunched.staticTexts["backend durably received"].exists,
            "A restart must never fabricate durable acceptance the hub never granted."
        )
    }

    // MARK: - Launch and navigation

    private func launch(
        fixture: String = UUID().uuidString,
        resetsOutbox: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = [
            "-ui-testing",
            "-ui-testing-auth-unlocked",
            "-ui-testing-uat-fixture",
            fixture,
            "-ui-testing-reset-capture-staging"
        ]
        if resetsOutbox { arguments.append("-ui-testing-reset-outbox") }
        app.launchArguments += arguments + extraArguments
        app.launch()
        return app
    }

    /// Navigates to the Heimdal tab across the compact iPhone tab bar and the
    /// floating iPad one. Kept local rather than reaching into another test
    /// file's helpers, so this suite owns its own navigation.
    private func navigateToHeimdalTab(in app: XCUIApplication) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Heimdal"))
            .firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Heimdal"].waitForExistence(timeout: 20))
    }

    private func openQueueTab(in app: XCUIApplication) {
        let tab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Queue"))
            .firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
    }

    private func firstQueueState(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transferQueue.state."))
            .firstMatch
    }

    /// `heimdal.registration.gapLogCount` and the health rows live inside a
    /// `List` and can sit below the initially rendered viewport; XCUITest
    /// matches only rendered cells.
    private func scrollTo(identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if element.exists { return element }
        for _ in 0..<6 {
            if element.exists { return element }
            app.swipeUp()
        }
        _ = element.waitForExistence(timeout: 5)
        return element
    }
}
