import Foundation
import XCTest
import YggdrasilCore
@testable import Yggdrasil

@MainActor
final class DeviceRegistrationTests: XCTestCase {
    func testFirstRunCreatesDeviceNoteWithProvenance() async throws {
        let vault = try makeVault()
        let deviceID = "device-123"
        try write(
            """
            ---
            grants:
              - grant_ref: self-record-grant
                scope: self_record
                granted_at: 2026-07-27
            ---
            """ + "\n",
            to: HeimdalPaths.consent,
            in: vault
        )
        let model = DeviceRegistrationModel(
            fileStore: VaultFileStore(rootURL: vault),
            deviceID: deviceID,
            deviceLabel: "Rasmus’s iPhone"
        )

        await model.register()

        let text = try String(contentsOf: vault.appendingPathComponent(HeimdalPaths.device(id: deviceID)))
        let document = try FrontmatterDocument.parse(text)
        XCTAssertEqual(document.frontmatter.keys, ["device_id", "label", "consent_grant_ref", "agent_provenance"])
        XCTAssertEqual(document.frontmatter["device_id"]?.stringValue, deviceID)
        XCTAssertEqual(document.frontmatter["label"]?.stringValue, "Rasmus’s iPhone")
        XCTAssertEqual(document.frontmatter["consent_grant_ref"]?.stringValue, "self-record-grant")
        XCTAssertEqual(document.frontmatter["agent_provenance"]?.mapValue?["author"]?.stringValue, "bifrost-ios")
    }

    func testExistingNotePreservedOnRelaunch() async throws {
        let vault = try makeVault()
        let deviceID = "device-preserve"
        let path = HeimdalPaths.device(id: deviceID)
        let existing = """
        ---
        device_id: (deviceID)
        label: Human chosen label
        consent_grant_ref: human-grant
        capture_gap_log:
          - kept-by-hub
        ---

        Existing device body.
        """
        try write(existing, to: path, in: vault)
        let model = DeviceRegistrationModel(
            fileStore: VaultFileStore(rootURL: vault),
            deviceID: deviceID,
            deviceLabel: "App default label"
        )

        await model.load()
        await model.register()

        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent(path)), existing)
    }

    func testNoGrantMeansNoFabricatedRef() async throws {
        let vault = try makeVault()
        let deviceID = "device-no-grant"
        try write("---\ngrants: []\n---\n", to: HeimdalPaths.consent, in: vault)
        let model = DeviceRegistrationModel(
            fileStore: VaultFileStore(rootURL: vault),
            deviceID: deviceID,
            deviceLabel: "Truthful phone"
        )

        await model.register()

        let text = try String(contentsOf: vault.appendingPathComponent(HeimdalPaths.device(id: deviceID)))
        let document = try FrontmatterDocument.parse(text)
        XCTAssertNil(document.frontmatter["consent_grant_ref"])
        guard case let .loaded(snapshot) = model.state else {
            return XCTFail("Expected a loaded registration state")
        }
        XCTAssertNil(snapshot.standingGrant)
        XCTAssertTrue(snapshot.isRegistered)
    }

    private func makeVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceRegistrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return vault
    }

    private func write(_ text: String, to relativePath: String, in vault: URL) throws {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
