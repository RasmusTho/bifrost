import Foundation
import XCTest
@testable import HeimdalMacObserver

@MainActor
final class HeimdalMacObserverSmokeTests: XCTestCase {
    private let appIdentifier = "com.example.Editor"

    func testCadenceMetadataAndNoSampleWhenIdleOrLocked() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controls = FakeScreenControls(snapshot: makeSnapshot())
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        let shipping = FakeScreenShipping(buffer: buffer)
        let coordinator = makeCoordinator(controls: controls, capture: capture, shipping: shipping, buffer: buffer)

        capture.isIdle = true
        await coordinator.runCycle()
        capture.isIdle = false
        capture.isLocked = true
        await coordinator.runCycle()

        let idleSummary = await buffer.summary()
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertEqual(controls.callCount, 0)
        XCTAssertEqual(idleSummary.pendingCount, 0)
        XCTAssertTrue(shipping.entries.isEmpty)

        capture.isLocked = false
        await coordinator.runCycle()

        XCTAssertEqual(capture.captureCount, 1)
        XCTAssertEqual(coordinator.status.phase, .observing)
        guard let payload = shipping.entries.first?.payload,
              let bundle = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let raw = bundle["raw"] as? [String: Any] else {
            return XCTFail("The admitted request must contain a raw screen frame bundle.")
        }
        XCTAssertEqual(raw["cadence_seconds"] as? Double, 12.5)
        XCTAssertEqual(raw["app_bundle_id"] as? String, appIdentifier)
        XCTAssertNotNil(raw["captured_at"] as? String)
        XCTAssertNotNil(raw["frame_png_base64"] as? String)
        capture.isLocked = true
        coordinator.refreshVisibleState()
        XCTAssertEqual(coordinator.status.phase, .idle)
        capture.isLocked = false
        coordinator.refreshVisibleState()
        XCTAssertEqual(coordinator.status.phase, .starting)
    }

    func testExcludedAppNeverCapturedBeforeBufferOrTransport() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controls = FakeScreenControls(snapshot: makeSnapshot(excluded: true, capturePermitted: false))
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        let shipping = FakeScreenShipping(buffer: buffer)
        let coordinator = makeCoordinator(controls: controls, capture: capture, shipping: shipping, buffer: buffer)

        await coordinator.runCycle()
        let excludedSummary = await buffer.summary()
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertEqual(excludedSummary.pendingCount, 0)
        XCTAssertTrue(shipping.entries.isEmpty)
        XCTAssertTrue(coordinator.status.phase.title.contains("Paused"))
    }

    func testPauseIsDurableAndTotal() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queued = ScreenQueueEntry(
            appIdentifier: appIdentifier,
            binding: makeSnapshot().binding,
            payload: Data("previous-frame".utf8)
        )
        try await buffer.enqueue(queued, maximum: 4)
        let initialIdentityList = await buffer.identities()
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        let shipping = FakeScreenShipping(buffer: buffer)
        let paused = makeSnapshot(paused: true, capturePermitted: false)
        let firstControls = FakeScreenControls(snapshot: paused)
        let firstCoordinator = makeCoordinator(
            controls: firstControls,
            capture: capture,
            shipping: shipping,
            buffer: buffer
        )
        await firstCoordinator.runCycle()
        let firstPausedIdentities = await buffer.identities()
        XCTAssertEqual(
            firstCoordinator.status.phase,
            .paused("The host controls are paused, degraded, or missing required accepted settings.")
        )
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertTrue(shipping.entries.isEmpty)
        XCTAssertEqual(firstPausedIdentities, initialIdentityList)

        let restartedControls = FakeScreenControls(snapshot: paused)
        let restartedCoordinator = makeCoordinator(
            controls: restartedControls,
            capture: capture,
            shipping: shipping,
            buffer: buffer
        )
        await restartedCoordinator.runCycle()
        let restartedIdentities = await buffer.identities()
        XCTAssertEqual(restartedCoordinator.status.phase.title, "Paused")
        XCTAssertEqual(restartedIdentities, initialIdentityList)
    }

    func testMissingControlsFailPausedAndPreserveBuffer() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queued = ScreenQueueEntry(
            appIdentifier: appIdentifier,
            binding: makeSnapshot().binding,
            payload: Data("previous-frame".utf8)
        )
        try await buffer.enqueue(queued, maximum: 4)
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        let shipping = FakeScreenShipping(buffer: buffer)
        let controls = FakeScreenControls(snapshot: nil)
        controls.shouldFail = true
        let coordinator = makeCoordinator(controls: controls, capture: capture, shipping: shipping, buffer: buffer)
        await coordinator.runCycle()

        XCTAssertEqual(coordinator.status.phase.title, "Paused")
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertTrue(shipping.entries.isEmpty)
        let pendingIdentities = await buffer.identities()
        XCTAssertEqual(pendingIdentities, [queued.contentIdentity])
        XCTAssertThrowsError(try ScreenControlSnapshot.decode(Data("{}".utf8), expectedApplication: appIdentifier))
    }

    func testBoundedDurableBufferAndOldestEvictionCount() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = makeSnapshot().binding
        let first = ScreenQueueEntry(appIdentifier: appIdentifier, binding: binding, payload: Data("first".utf8))
        let second = ScreenQueueEntry(appIdentifier: appIdentifier, binding: binding, payload: Data("second".utf8))
        let third = ScreenQueueEntry(appIdentifier: appIdentifier, binding: binding, payload: Data("third".utf8))

        try await buffer.enqueue(first, maximum: 2)
        try await buffer.enqueue(second, maximum: 2)
        try await buffer.enqueue(third, maximum: 2)

        let boundedIdentities = await buffer.identities()
        let boundedSummary = await buffer.summary()
        XCTAssertEqual(boundedIdentities, [second.contentIdentity, third.contentIdentity])
        XCTAssertEqual(boundedSummary, ScreenBufferSummary(pendingCount: 2, oldestEvictionCount: 1))

        let restored = try DurableScreenBuffer(directoryURL: directory)
        let restoredIdentities = await restored.identities()
        let restoredSummary = await restored.summary()
        XCTAssertEqual(restoredIdentities, [second.contentIdentity, third.contentIdentity])
        XCTAssertEqual(restoredSummary, ScreenBufferSummary(pendingCount: 2, oldestEvictionCount: 1))
    }

    func testBackfillPreservesIdentityAndRequiresDurableAcknowledgement() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controls = FakeScreenControls(snapshot: makeSnapshot())
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        capture.frameToCapture = nil
        let shipping = FakeScreenShipping(buffer: buffer)
        shipping.failedAttempts = 1
        let coordinator = makeCoordinator(controls: controls, capture: capture, shipping: shipping, buffer: buffer)

        capture.frameToCapture = makeFrame()
        await coordinator.runCycle()
        let pendingAfterFailure = await buffer.identities()
        XCTAssertEqual(pendingAfterFailure.count, 1)
        XCTAssertEqual(shipping.entries.first?.contentIdentity, pendingAfterFailure.first)

        shipping.invalidAcknowledgement = true
        capture.frameToCapture = nil
        await coordinator.runCycle()
        let pendingAfterInvalidAcknowledgement = await buffer.identities()
        XCTAssertEqual(pendingAfterInvalidAcknowledgement, pendingAfterFailure)

        shipping.invalidAcknowledgement = false
        await coordinator.runCycle()
        XCTAssertEqual(shipping.entries.map(\.contentIdentity), [
            pendingAfterFailure[0],
            pendingAfterFailure[0],
            pendingAfterFailure[0]
        ])
        XCTAssertEqual(shipping.entries[0].payload, shipping.entries[1].payload)
        XCTAssertEqual(shipping.entries[1].payload, shipping.entries[2].payload)
        let acknowledgedSummary = await buffer.summary()
        XCTAssertEqual(acknowledgedSummary.pendingCount, 0)
    }

    func testVaultBindingChangePreservesPendingQueueAndPauses() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldBinding = makeSnapshot().binding
        let queued = ScreenQueueEntry(
            appIdentifier: appIdentifier,
            binding: oldBinding,
            payload: Data("previous-vault-frame".utf8)
        )
        try await buffer.enqueue(queued, maximum: 4)
        let controls = FakeScreenControls(snapshot: makeSnapshot(vaultIdentifier: "vault-2"))
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        let shipping = FakeScreenShipping(buffer: buffer)
        let coordinator = makeCoordinator(controls: controls, capture: capture, shipping: shipping, buffer: buffer)

        await coordinator.runCycle()

        XCTAssertEqual(coordinator.status.phase.title, "Paused")
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertTrue(shipping.entries.isEmpty)
        let pendingIdentities = await buffer.identities()
        XCTAssertEqual(pendingIdentities, [queued.contentIdentity])
    }

    func testControlReadFailureWhileDrainingStopsCaptureAndPreservesQueue() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queued = ScreenQueueEntry(
            appIdentifier: appIdentifier,
            binding: makeSnapshot().binding,
            payload: Data("previous-frame".utf8)
        )
        try await buffer.enqueue(queued, maximum: 4)
        let controls = FakeScreenControls(snapshot: makeSnapshot())
        controls.failingCallNumbers = [2]
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        let shipping = FakeScreenShipping(buffer: buffer)
        let coordinator = makeCoordinator(controls: controls, capture: capture, shipping: shipping, buffer: buffer)

        await coordinator.runCycle()

        XCTAssertEqual(controls.callCount, 2)
        XCTAssertEqual(coordinator.status.phase.title, "Paused")
        XCTAssertEqual(capture.captureCount, 0)
        XCTAssertTrue(shipping.entries.isEmpty)
        let pendingIdentities = await buffer.identities()
        XCTAssertEqual(pendingIdentities, [queued.contentIdentity])
    }

    func testRegistersSensorAndShipsConformingBundleBeforeFirstAdmit() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controls = FakeScreenControls(snapshot: makeSnapshot())
        let capture = FakeScreenCapture(appIdentifier: appIdentifier)
        let shipping = FakeScreenShipping(buffer: buffer)
        let coordinator = makeCoordinator(controls: controls, capture: capture, shipping: shipping, buffer: buffer)

        await coordinator.runCycle()

        XCTAssertEqual(shipping.pendingCountAtAdmission, [1])
        guard let payload = shipping.entries.first?.payload,
              let bundle = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sensor = bundle["sensor"] as? [String: String] else {
            return XCTFail("The first POST must contain the registered sensor identity.")
        }
        XCTAssertEqual(sensor["adapter"], ScreenSensorIdentity.adapter)
        XCTAssertEqual(sensor["version"], "v1")
        XCTAssertEqual(sensor["machine"], "test-machine-id")
        XCTAssertEqual(bundle["scope"] as? String, "screen_always_on")
        XCTAssertEqual(bundle["bundle_shape"] as? String, "raw_capture_bundle")
        XCTAssertEqual(bundle["capture_chain"] as? [String], ["screen_capture_post", "heimdal_macos_screen_observer"])
        let admittedSummary = await buffer.summary()
        XCTAssertEqual(admittedSummary.pendingCount, 0)
    }

}

@MainActor
extension HeimdalMacObserverSmokeTests {
    @objc func testCorruptQueueIdentityFailsClosed() async throws {
        let (directory, buffer) = try makeBuffer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queued = ScreenQueueEntry(
            appIdentifier: appIdentifier,
            binding: makeSnapshot().binding,
            payload: Data("queued-frame".utf8)
        )
        try await buffer.enqueue(queued, maximum: 4)

        let queueURL = directory.appendingPathComponent("screen-buffer.json")
        let data = try Data(contentsOf: queueURL)
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try XCTUnwrap(snapshot["entries"] as? [[String: Any]])
        entries[0]["content_identity"] = "corrupt-identity"
        snapshot["entries"] = entries
        let corrupted = try JSONSerialization.data(withJSONObject: snapshot)
        try corrupted.write(to: queueURL, options: [.atomic])

        XCTAssertThrowsError(try DurableScreenBuffer(directoryURL: directory))
    }

    @objc func testControlResponseParsesBindingAndMappedExclusions() throws {
        let payload = Data(
            """
            {
              "app_id": "com.example.Editor",
              "state": "ready",
              "settings_state": "ok",
              "errors": [],
              "capture_permitted": true,
              "excluded": false,
              "consent_active": true,
              "vault_id": "vault-1",
              "local_instance_id": "instance-1",
              "controls": {
                "screen_paused": false,
                "screen_excluded_apps": [],
                "screen_excluded_scopes": ["private"],
                "screen_scope_app_mapping": {"private": ["com.example.Editor"]},
                "screen_capture_cadence_seconds": 12.5,
                "screen_client_buffer_max": 100
              }
            }
            """.utf8
        )
        let snapshot = try ScreenControlSnapshot.decode(payload, expectedApplication: appIdentifier)
        let expectedBinding = ScreenControlBinding(
            vaultIdentifier: "vault-1",
            localInstanceIdentifier: "instance-1"
        )

        XCTAssertEqual(snapshot.binding, expectedBinding)
        XCTAssertEqual(snapshot.cadenceSeconds, 12.5)
        XCTAssertFalse(snapshot.permitsCapture(for: appIdentifier))
        XCTAssertThrowsError(try ScreenControlSnapshot.decode(payload, expectedApplication: "com.other.App"))
    }

    @objc func testDurableAcknowledgementParserRejectsIncompleteResponse() throws {
        let valid = Data(
            """
            {
              "record_id": "record-1",
              "content_identity": "host-identity-1",
              "created": true,
              "bundle_shape": "raw_capture_bundle",
              "observation_published": false
            }
            """.utf8
        )
        let acknowledgement = try ScreenControlAPI.decodeDurableAcknowledgement(valid)

        XCTAssertEqual(acknowledgement.recordIdentifier, "record-1")
        XCTAssertEqual(acknowledgement.contentIdentity, "host-identity-1")
        XCTAssertEqual(acknowledgement.bundleShape, "raw_capture_bundle")

        let incomplete = Data("{\"record_id\":\"record-1\",\"observation_published\":false}".utf8)
        XCTAssertThrowsError(try ScreenControlAPI.decodeDurableAcknowledgement(incomplete))
    }
}

private extension HeimdalMacObserverSmokeTests {
    func makeSnapshot(
        paused: Bool = false,
        excluded: Bool = false,
        capturePermitted: Bool = true,
        vaultIdentifier: String = "vault-1",
        localInstanceIdentifier: String = "instance-1"
    ) -> ScreenControlSnapshot {
        ScreenControlSnapshot(
            appIdentifier: appIdentifier,
            state: paused ? "paused" : "ready",
            settingsState: "ok",
            errors: [],
            capturePermitted: capturePermitted,
            excluded: excluded,
            consentActive: !paused,
            vaultIdentifier: vaultIdentifier,
            localInstanceIdentifier: localInstanceIdentifier,
            screenPaused: paused,
            excludedApplications: excluded ? [appIdentifier] : [],
            excludedScopes: [],
            scopeApplications: [:],
            cadenceSeconds: 12.5,
            bufferMaximum: 2
        )
    }

    func makeCoordinator(
        controls: FakeScreenControls,
        capture: FakeScreenCapture,
        shipping: FakeScreenShipping,
        buffer: DurableScreenBuffer
    ) -> ScreenObserverCoordinator {
        ScreenObserverCoordinator(
            controls: controls,
            capture: capture,
            shipping: shipping,
            buffer: buffer,
            sensor: ScreenSensorIdentity(machine: "test-machine-id")
        )
    }

    func makeBuffer() throws -> (URL, DurableScreenBuffer) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (directory, try DurableScreenBuffer(directoryURL: directory))
    }

    func makeFrame() -> ScreenFrame {
        ScreenFrame(
            pngData: Data([0x89, 0x50, 0x4e, 0x47]),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            windowIdentifier: 42,
            windowTitle: "Editor"
        )
    }
}

@MainActor
private final class FakeScreenControls: ScreenControlProviding {
    private let snapshot: ScreenControlSnapshot?
    var shouldFail = false
    private(set) var callCount = 0
    var failingCallNumbers: Set<Int> = []

    init(snapshot: ScreenControlSnapshot?) {
        self.snapshot = snapshot
    }

    func controls(for appIdentifier: String) async throws -> ScreenControlSnapshot {
        callCount += 1
        guard !shouldFail, !failingCallNumbers.contains(callCount),
              let snapshot, snapshot.appIdentifier == appIdentifier else {
            throw FakeScreenError.unavailable
        }
        return snapshot
    }
}

@MainActor
private final class FakeScreenCapture: ScreenCaptureProviding {
    private let appIdentifier: String
    var isIdle = false
    var isLocked = false
    var frameToCapture: ScreenFrame? = ScreenFrame(
        pngData: Data([0x89, 0x50, 0x4e, 0x47]),
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
        windowIdentifier: 42,
        windowTitle: "Editor"
    )
    private(set) var captureCount = 0

    init(appIdentifier: String) {
        self.appIdentifier = appIdentifier
    }

    func frontmostApplication() -> ScreenApplication? {
        ScreenApplication(bundleIdentifier: appIdentifier, name: "Editor")
    }

    func isIdleOrLocked() -> Bool {
        isIdle || isLocked
    }

    func captureFrontmostWindow(appIdentifier: String) async throws -> ScreenFrame? {
        guard appIdentifier == self.appIdentifier, !isIdleOrLocked() else { return nil }
        captureCount += 1
        return frameToCapture
    }
}

@MainActor
private final class FakeScreenShipping: ScreenBundleShipping {
    private let buffer: DurableScreenBuffer
    var failedAttempts = 0
    var invalidAcknowledgement = false
    private(set) var entries: [ScreenQueueEntry] = []
    private(set) var pendingCountAtAdmission: [Int] = []

    init(buffer: DurableScreenBuffer) {
        self.buffer = buffer
    }

    func ship(_ entry: ScreenQueueEntry) async throws -> DurableScreenAcknowledgement {
        entries.append(entry)
        pendingCountAtAdmission.append(await buffer.summary().pendingCount)
        if failedAttempts > 0 {
            failedAttempts -= 1
            throw FakeScreenError.unavailable
        }
        if invalidAcknowledgement {
            return DurableScreenAcknowledgement(
                recordIdentifier: "",
                contentIdentity: "host-content-identity",
                bundleShape: "raw_capture_bundle"
            )
        }
        return DurableScreenAcknowledgement(
            recordIdentifier: "record-1",
            contentIdentity: "host-content-identity",
            bundleShape: "raw_capture_bundle"
        )
    }
}

private enum FakeScreenError: Error {
    case unavailable
}
