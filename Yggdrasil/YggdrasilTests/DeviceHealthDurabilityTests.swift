import Foundation
import XCTest
import YggdrasilCore
@testable import Yggdrasil

/// The durable half of the ADR-0049 §2 device-health bend: `capture_gap_log`
/// (append-only, provenance-tagged, deduplicated per gap) and
/// `last_known_snapshot` (field-scoped, change-gated). Split from
/// `DeviceRegistrationTests` to keep both files under the repo's file-length
/// lint budget; this extends the same `DeviceRegistrationTests` case and
/// reuses its `makeVault(...)`/`write(...)` fixtures.
@MainActor
extension DeviceRegistrationTests {
    /// A nameable gap (ADR-0049 §2's durable half) appends exactly one
    /// `capture_gap_log` entry, even when the client reports the same gap
    /// twice (a retried scan, a second scenePhase activation before the
    /// first write lands) — never a duplicate. Provenance and every other
    /// field on the device note survive untouched.
    func testGapEventsAppendToDeviceNoteOnce() async throws {
        let vault = try makeVault()
        let deviceID = "device-gap-log"
        let path = try writeHealthFixture(deviceID: deviceID, in: vault)
        let model = DeviceRegistrationModel(
            fileStore: VaultFileStore(rootURL: vault),
            deviceID: deviceID,
            deviceLabel: "Gap-reporting phone"
        )
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        // The same detected gap, reported twice, then a distinct gap.
        await model.recordGapEvent(kind: DeviceRegistrationModel.GapKind.interruptedNotResumed,
                                    detail: "session abc123", at: at)
        await model.recordGapEvent(kind: DeviceRegistrationModel.GapKind.interruptedNotResumed,
                                    detail: "session abc123", at: at)
        await model.recordGapEvent(kind: DeviceRegistrationModel.GapKind.finalizedByAbandonment,
                                    detail: "recording def456", at: at)

        let document = try readHealthDocument(at: path, in: vault)
        let entries = try XCTUnwrap(document.frontmatter["capture_gap_log"]?.arrayValue)
        XCTAssertEqual(entries.count, 2, "Expected exactly one entry per distinct gap")
        XCTAssertEqual(entries[0].mapValue?["kind"]?.stringValue, "interrupted_not_resumed")
        XCTAssertEqual(entries[0].mapValue?["detail"]?.stringValue, "session abc123")
        XCTAssertNotNil(entries[0].mapValue?["at"]?.stringValue)
        XCTAssertEqual(entries[1].mapValue?["kind"]?.stringValue, "finalized_by_abandonment")
        XCTAssertEqual(entries[1].mapValue?["detail"]?.stringValue, "recording def456")
        assertHealthFixtureFieldsUntouched(document, deviceID: deviceID)
        XCTAssertEqual(document.frontmatter["agent_provenance"]?.mapValue?["author"]?.stringValue, "bifrost-ios")
    }

    /// `last_known_snapshot` updates in place, touches no other field, and is
    /// skipped entirely (byte-for-byte) when the reported snapshot is
    /// unchanged from what the note already holds.
    func testSnapshotUpdateIsFieldScopedAndChangeGated() async throws {
        let vault = try makeVault()
        let deviceID = "device-snapshot"
        let path = try writeHealthFixture(deviceID: deviceID, in: vault)
        let model = DeviceRegistrationModel(
            fileStore: VaultFileStore(rootURL: vault),
            deviceID: deviceID,
            deviceLabel: "Snapshot phone"
        )

        await model.updateLastKnownSnapshot(
            .init(battery: 0.8, queueDepth: 1, recording: true),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let afterFirstWrite = try String(contentsOf: vault.appendingPathComponent(path))
        let firstDocument = try readHealthDocument(at: path, in: vault)
        assertSnapshot(firstDocument, battery: 0.8, queueDepth: 1, recording: true)
        assertHealthFixtureFieldsUntouched(firstDocument, deviceID: deviceID)

        // An unchanged snapshot, reported again later, must not touch the
        // file at all — not even to refresh a provenance timestamp.
        await model.updateLastKnownSnapshot(
            .init(battery: 0.8, queueDepth: 1, recording: true),
            at: Date(timeIntervalSince1970: 1_800_010_000)
        )
        let afterNoOpWrite = try String(contentsOf: vault.appendingPathComponent(path))
        XCTAssertEqual(afterNoOpWrite, afterFirstWrite, "An unchanged snapshot must skip the write entirely")

        // A genuinely changed snapshot does update, still field-scoped.
        await model.updateLastKnownSnapshot(
            .init(battery: 0.5, queueDepth: 0, recording: false),
            at: Date(timeIntervalSince1970: 1_800_020_000)
        )
        let afterChange = try String(contentsOf: vault.appendingPathComponent(path))
        XCTAssertNotEqual(afterChange, afterFirstWrite)
        let changedDocument = try readHealthDocument(at: path, in: vault)
        assertSnapshot(changedDocument, battery: 0.5, queueDepth: 0, recording: false)
        assertHealthFixtureFieldsUntouched(changedDocument, deviceID: deviceID)
    }

    @discardableResult
    private func writeHealthFixture(deviceID: String, in vault: URL) throws -> String {
        let path = HeimdalPaths.device(id: deviceID)
        try write(
            """
            ---
            device_id: \(deviceID)
            label: Human chosen label
            consent_grant_ref: human-grant
            ---

            Existing device body.
            """,
            to: path,
            in: vault
        )
        return path
    }

    private func readHealthDocument(at path: String, in vault: URL) throws -> FrontmatterDocument {
        let text = try String(contentsOf: vault.appendingPathComponent(path))
        return try FrontmatterDocument.parse(text)
    }

    private func assertHealthFixtureFieldsUntouched(_ document: FrontmatterDocument, deviceID: String) {
        XCTAssertEqual(document.frontmatter["device_id"]?.stringValue, deviceID)
        XCTAssertEqual(document.frontmatter["label"]?.stringValue, "Human chosen label")
        XCTAssertEqual(document.frontmatter["consent_grant_ref"]?.stringValue, "human-grant")
        XCTAssertTrue(document.body.contains("Existing device body."))
    }

    private func assertSnapshot(
        _ document: FrontmatterDocument,
        battery: Double,
        queueDepth: Int,
        recording: Bool
    ) {
        let snapshot = document.frontmatter["last_known_snapshot"]?.mapValue
        XCTAssertEqual(snapshot?["battery"]?.doubleValue, battery)
        XCTAssertEqual(snapshot?["queue_depth"]?.intValue, queueDepth)
        XCTAssertEqual(snapshot?["recording"]?.boolValue, recording)
        XCTAssertNotNil(snapshot?["at"]?.stringValue)
    }
}
