import XCTest
import UIKit

/// Composed iPad canvas journeys. These exercise the same MIPAD-01..04
/// ground as `MimerCanvasUITests`, but each test strings several slice-level
/// behaviours together into the single continuous flow a human actually
/// runs on the canvas, rather than proving one behaviour in isolation.
///
/// No new canvas functionality is introduced here; these tests reuse the
/// existing fixture vault and accessibility identifiers exercised by
/// `MimerCanvasUITests`.
final class MimerCanvasJourneyTests: XCTestCase {
    /// Journey: pick the vault lens → see the three-column canvas → drill
    /// into a folder → open a note → confirm the inspector reflects that
    /// note's metadata (including a note that has no uuid/provenance).
    func testBrowseAndReadJourney() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        let app = launchMimerShell(withFixture: true)

        // 1. Pick the vault.
        let vaultLens = app.descendants(matching: .any)["mimer.canvas.lens.vault"]
        XCTAssertTrue(vaultLens.waitForExistence(timeout: 10))
        vaultLens.tap()

        // 2. Confirm the three-column canvas is actually up: sidebar,
        // content column, and detail column all present at once.
        let sidebar = app.descendants(matching: .any)["mimer.canvas.focus.sidebar"]
        let content = app.descendants(matching: .any)["mimer.canvas.content.vault"]
        let detail = app.descendants(matching: .any)["mimer.canvas.detail"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertTrue(detail.exists, "Expected the detail column to render alongside sidebar and content.")

        // 3. Drill into a folder.
        let projects = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.tap()

        // 4. Open a note that has uuid + agent_provenance.
        let note = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects/fixture.md"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        assertRenderedNote("Projects/fixture.md", heading: "Fixture note", in: app)

        // 5. Confirm the inspector reflects that note's metadata.
        let inspectorUUID = app.descendants(matching: .any)["mimer.canvas.inspector.uuid"]
        XCTAssertTrue(inspectorUUID.waitForExistence(timeout: 5))
        XCTAssertTrue(inspectorUUID.label.contains("fixture-uuid"))

        // 6. Open a sibling note that has no uuid/provenance and confirm the
        // inspector honestly reports its absence rather than carrying over
        // the previous note's metadata.
        let plainNote = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects/source.md"]
        XCTAssertTrue(plainNote.waitForExistence(timeout: 5))
        plainNote.tap()
        assertRenderedNote("Projects/source.md", heading: "Source note", in: app)
        // `LabeledContent` composes its own label into the accessibility
        // label, so match on containment rather than equality (as step 5
        // does). Asserting both halves keeps this honest: the inspector must
        // report the absence *and* must no longer be showing the previously
        // selected note's uuid.
        let noUUID = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)",
                                   "No uuid present", "fixture-uuid"),
            object: inspectorUUID
        )
        XCTAssertEqual(XCTWaiter.wait(for: [noUUID], timeout: 5), .completed)
    }

    /// Journey: the regular-width canvas lays out navigation → content →
    /// detail with the inspector trailing the document, and its empty and
    /// provenance states are the shared Yggdrasil components (tone carried as
    /// the VoiceOver value), not per-screen styling.
    func testRegularWidthCanvasUsesSharedHierarchy() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        let app = launchMimerShell(withFixture: true)

        let vaultLens = app.descendants(matching: .any)["mimer.canvas.lens.vault"]
        XCTAssertTrue(vaultLens.waitForExistence(timeout: 10))
        vaultLens.tap()

        let sidebar = app.descendants(matching: .any)["mimer.canvas.focus.sidebar"]
        let content = app.descendants(matching: .any)["mimer.canvas.content.vault"]
        let detail = app.descendants(matching: .any)["mimer.canvas.detail"]
        let inspector = app.descendants(matching: .any)["mimer.canvas.inspector"]
        for column in [sidebar, content, detail, inspector] {
            XCTAssertTrue(column.waitForExistence(timeout: 10), "Missing canvas column \(column)")
        }
        // Side by side, in reading order. On iPadOS 26 the sidebar floats over
        // the leading edge of the content column, so order by centre and by
        // the trailing edges rather than requiring disjoint frames. One point
        // of slack absorbs hairlines.
        let frames = [sidebar, content, detail, inspector].map { "\($0.identifier)=\($0.frame)" }
        XCTAssertLessThan(sidebar.frame.midX, content.frame.midX, "Navigation must lead content: \(frames)")
        XCTAssertLessThan(sidebar.frame.maxX, content.frame.maxX, "Content must show past navigation: \(frames)")
        XCTAssertLessThanOrEqual(content.frame.maxX, detail.frame.minX + 1, "Content must lead detail: \(frames)")
        XCTAssertGreaterThan(inspector.frame.minX, detail.frame.minX, "Inspector trails the document: \(frames)")
        XCTAssertEqual(
            inspector.frame.maxX, detail.frame.maxX, accuracy: 1, "Inspector sits on detail's trailing edge: \(frames)"
        )

        // No selection yet: the detail column shows the shared empty state.
        let detailEmpty = app.descendants(matching: .any)["mimer.canvas.detail.empty"]
        XCTAssertTrue(detailEmpty.waitForExistence(timeout: 5))
        XCTAssertTrue(detailEmpty.label.contains("Select an Item"), detailEmpty.label)
        XCTAssertEqual(detailEmpty.value as? String, "Empty")

        // A note with agent_provenance: the inspector uses the shared marker.
        let projects = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.tap()
        let note = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects/fixture.md"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        let provenance = app.descendants(matching: .any)["mimer.canvas.inspector.provenance"]
        let agentContributed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", "agent-contributed"),
            object: provenance
        )
        XCTAssertEqual(XCTWaiter.wait(for: [agentContributed], timeout: 10), .completed)

        // A filter with no match: the content column shows the shared empty state.
        let filter = app.textFields["mimer.canvas.vault.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.tap()
        filter.typeText("zz-no-such-note")
        let contentEmpty = app.descendants(matching: .any)["mimer.canvas.vault.empty"]
        XCTAssertTrue(contentEmpty.waitForExistence(timeout: 5))
        XCTAssertTrue(contentEmpty.label.contains("No Matching Notes"), contentEmpty.label)
        XCTAssertEqual(contentEmpty.value as? String, "Empty")
    }

    /// Wait for the WebKit renderer's completion signal before asking
    /// XCTest to inspect its accessibility tree. The detail-column note
    /// value changes as soon as selection succeeds, before WebKit finishes
    /// rendering the markdown DOM.
    private func assertRenderedNote(_ path: String, heading: String, in app: XCUIApplication) {
        let renderer = app.descendants(matching: .any)["mimer.note.renderer"]
        XCTAssertTrue(renderer.waitForExistence(timeout: 5), "Expected the note renderer for \(path).")

        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "rendered:\(path)"),
            object: renderer
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rendered], timeout: 15),
            .completed,
            "Expected WebKit to finish rendering \(path) before checking its visible heading."
        )
        XCTAssertTrue(
            app.staticTexts[heading].waitForExistence(timeout: 5),
            "Expected the rendered note to expose its \(heading) heading."
        )
    }

    /// Journey: open the entities source → compare candidates → merge with
    /// an explicitly selected candidate → undo, leaving the queue entry
    /// still pending for a future decision.
    func testEntityDecisionJourney() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only entity compare verification")
        let app = launchMimerShell(withFixture: true)

        // 1. Entities source: open the lens and the pending queue.
        let entitiesLens = app.descendants(matching: .any)["mimer.canvas.lens.entities"]
        XCTAssertTrue(entitiesLens.waitForExistence(timeout: 10))
        entitiesLens.tap()

        let queueEntry = app.descendants(matching: .any)["mimer.entity.queue.entity-compare-fixture"]
        XCTAssertTrue(queueEntry.waitForExistence(timeout: 10))
        queueEntry.tap()

        // 2. Compare: both candidates for the ambiguous mention are visible.
        XCTAssertTrue(app.staticTexts["Anna"].waitForExistence(timeout: 5))
        let existingCandidate = app.descendants(matching: .any)["mimer.entity.candidate.ent:anna"]
        let missingCandidate = app.descendants(matching: .any)["mimer.entity.candidate.ent:missing"]
        XCTAssertTrue(existingCandidate.waitForExistence(timeout: 10))
        XCTAssertTrue(missingCandidate.waitForExistence(timeout: 5))

        // 3. Merge requires an explicit candidate selection before it is
        // enabled, and the decision commits only that selection.
        let merge = app.buttons["mimer.entity.merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        XCTAssertFalse(merge.isEnabled, "Merge must require an explicit candidate selection.")
        existingCandidate.tap()
        XCTAssertTrue(merge.isEnabled)
        merge.tap()

        let decisionState = app.descendants(matching: .any)["mimer.entity.decision.state"]
        let merged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Merge proposed: ent:anna"),
            object: decisionState
        )
        XCTAssertEqual(XCTWaiter.wait(for: [merged], timeout: 10), .completed)

        // 4. Undo reverts the local decision without removing the pending
        // queue entry, so the same mention can be revisited.
        let undo = app.buttons["mimer.entity.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        let undecided = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Undecided locally"),
            object: decisionState
        )
        XCTAssertEqual(XCTWaiter.wait(for: [undecided], timeout: 10), .completed)
        XCTAssertTrue(queueEntry.exists, "The client must not remove the pending queue entry after undo.")
    }

    /// Journey: annotate a note, drag another vault item onto it, and
    /// confirm both the annotation block and the dragged-in block render
    /// together in the composed document.
    func testCurateJourney() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        let app = launchMimerShell(withFixture: true)

        let vaultLens = app.descendants(matching: .any)["mimer.canvas.lens.vault"]
        XCTAssertTrue(vaultLens.waitForExistence(timeout: 10))
        vaultLens.tap()
        let projects = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.tap()

        let target = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects/fixture.md"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()

        // 1. Annotate the open note.
        let annotate = app.buttons["mimer.canvas.annotate"]
        XCTAssertTrue(annotate.waitForExistence(timeout: 5))
        annotate.tap()
        let annotationField = app.textFields["mimer.canvas.annotation.field"]
        XCTAssertTrue(annotationField.waitForExistence(timeout: 5))
        annotationField.tap()
        annotationField.typeText("check the June numbers")
        app.buttons["mimer.canvas.annotation.commit"].tap()
        XCTAssertTrue(app.staticTexts["check the June numbers"].waitForExistence(timeout: 5))

        // 2. Drag another vault item onto the same open note.
        let source = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects/source.md"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let renderedDocument = app.descendants(matching: .any)["mimer.canvas.detail.document"]
        XCTAssertTrue(renderedDocument.waitForExistence(timeout: 5))
        source.press(
            forDuration: 1.0,
            thenDragTo: renderedDocument,
            withVelocity: .slow,
            thenHoldForDuration: 1.5
        )
        assertAccessibilityValueContains(
            "[[Projects/source]] — source.md",
            for: renderedDocument,
            timeout: 15
        )

        // 3. Both blocks must render together: the annotation committed in
        // step 1 must still be present after the drop, alongside the
        // promoted content from step 2.
        XCTAssertTrue(
            app.staticTexts["check the June numbers"].exists,
            "Expected the annotation block to still render after the drop."
        )
        assertAccessibilityValueContains(
            "check the June numbers",
            for: renderedDocument,
            timeout: 5
        )
    }
}

private extension MimerCanvasJourneyTests {
    func assertAccessibilityValueContains(
        _ expectedValue: String,
        for element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", expectedValue),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected accessibility value to contain \(expectedValue), got \(String(describing: element.value)).",
            file: file,
            line: line
        )
    }

    func launchMimerShell(withFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(
                app.wait(for: .notRunning, timeout: 5),
                "Expected the prior app instance to terminate before relaunch."
            )
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        app.launchArguments += ["-ui-testing", "-ui-testing-auth-unlocked", "-ui-testing-mimer-shell"]
        if withFixture {
            app.launchArguments.append("-ui-testing-mimer-fixture")
        }
        app.launch()
        return app
    }
}
