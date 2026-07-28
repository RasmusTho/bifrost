import Foundation
import XCTest
import YggdrasilCore
@testable import Yggdrasil

@MainActor
final class DeviceRegistrationTests: XCTestCase {
    func testFirstRunCreatesDeviceNoteWithProvenance() async throws {
        let vault = try makeVault()
        let deviceID = "device-123"
        // Mirrors the hub readout shape (`app.heimdal.consent_surface.GrantReadout`):
        // grants are ordered oldest-first by ledger sequence, and `basis` — not
        // `scope` — carries `self_record`. The leading `place_optin` row is what
        // an unfiltered `grants.first` would bind.
        try write(
            """
            ---
            grants:
              - grant_ref: place-optin-grant
                basis: place_optin
                scope: place:kitchen
                granted_at: 2026-07-20T09:00:00+00:00
                expiry: null
              - grant_ref: self-record-grant
                basis: self_record
                scope: device+adapter:v1-voice-memo
                granted_at: 2026-07-27T08:00:00+00:00
                expiry: null
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
        device_id: \(deviceID)
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
        // Both shapes that carry no standing self-record grant: the empty
        // mirror, and a populated mirror whose grants are all other bases. The
        // second is the case an empty-array-only fixture never reaches.
        let consentFixtures: [(name: String, contents: String)] = [
            (name: "empty-grants", contents: "---\ngrants: []\n---\n"),
            (
                name: "no-self-record-grant",
                contents: """
                ---
                grants:
                  - grant_ref: place-optin-grant
                    basis: place_optin
                    scope: place:kitchen
                    granted_at: 2026-07-20T09:00:00+00:00
                  - grant_ref: session-optin-grant
                    basis: session_optin
                    scope: session:standup
                    granted_at: 2026-07-21T09:00:00+00:00
                ---
                """ + "\n"
            )
        ]

        for fixture in consentFixtures {
            let vault = try makeVault()
            let deviceID = "device-no-grant-\(fixture.name)"
            try write(fixture.contents, to: HeimdalPaths.consent, in: vault)
            let model = DeviceRegistrationModel(
                fileStore: VaultFileStore(rootURL: vault),
                deviceID: deviceID,
                deviceLabel: "Truthful phone"
            )

            await model.register()

            let text = try String(contentsOf: vault.appendingPathComponent(HeimdalPaths.device(id: deviceID)))
            let document = try FrontmatterDocument.parse(text)
            XCTAssertNil(document.frontmatter["consent_grant_ref"], "\(fixture.name) fabricated a grant ref")
            guard case let .loaded(snapshot) = model.state else {
                return XCTFail("Expected a loaded registration state for \(fixture.name)")
            }
            XCTAssertNil(snapshot.standingGrant, "\(fixture.name) reported a standing grant")
            XCTAssertTrue(snapshot.isRegistered, "\(fixture.name) did not register")
        }
    }

    /// The standing grant is the active `self_record` row, wherever it sits in
    /// the oldest-first mirror — not simply the first element.
    func testStandingGrantSelectsActiveSelfRecordGrantNotFirst() async throws {
        let vault = try makeVault()
        let deviceID = "device-selects-active"
        try write(
            """
            ---
            grants:
              - grant_ref: place-optin-grant
                basis: place_optin
                scope: place:kitchen
                granted_at: 2026-07-18T09:00:00+00:00
              - grant_ref: expired-self-record-grant
                basis: self_record
                scope: device+adapter:v0-voice-memo
                granted_at: 2026-07-19T09:00:00+00:00
                expiry: 2026-07-20T09:00:00+00:00
              - grant_ref: active-self-record-grant
                basis: self_record
                scope: device+adapter:v1-voice-memo
                granted_at: 2026-07-21T09:00:00+00:00
                expiry: null
            ---
            """ + "\n",
            to: HeimdalPaths.consent,
            in: vault
        )
        let model = DeviceRegistrationModel(
            fileStore: VaultFileStore(rootURL: vault),
            deviceID: deviceID,
            deviceLabel: "Selective phone"
        )

        await model.register()

        guard case let .loaded(snapshot) = model.state else {
            return XCTFail("Expected a loaded registration state")
        }
        XCTAssertEqual(snapshot.standingGrant?.grantRef, "active-self-record-grant")
        XCTAssertEqual(snapshot.standingGrant?.basis, "self_record")

        let text = try String(contentsOf: vault.appendingPathComponent(HeimdalPaths.device(id: deviceID)))
        let document = try FrontmatterDocument.parse(text)
        XCTAssertEqual(document.frontmatter["consent_grant_ref"]?.stringValue, "active-self-record-grant")
    }

    /// A mirror whose only `self_record` rows are expired or revoked has no
    /// standing grant, and nothing may be bound into the device note.
    func testExpiredOrRevokedGrantIsNotStanding() async throws {
        for fixture in Self.lapsedConsentFixtures {
            let vault = try makeVault()
            let deviceID = "device-lapsed-\(fixture.name)"
            try write(fixture.contents, to: HeimdalPaths.consent, in: vault)
            let model = DeviceRegistrationModel(
                fileStore: VaultFileStore(rootURL: vault),
                deviceID: deviceID,
                deviceLabel: "Lapsed phone"
            )

            await model.register()

            guard case let .loaded(snapshot) = model.state else {
                return XCTFail("Expected a loaded registration state for \(fixture.name)")
            }
            XCTAssertNil(snapshot.standingGrant, "\(fixture.name) grant was treated as standing")

            let text = try String(contentsOf: vault.appendingPathComponent(HeimdalPaths.device(id: deviceID)))
            let document = try FrontmatterDocument.parse(text)
            XCTAssertNil(
                document.frontmatter["consent_grant_ref"],
                "\(fixture.name) bound a lapsed grant ref into the device note"
            )
        }
    }

    /// Consent mirrors whose only `self_record` rows cannot be stood behind:
    /// lapsed by expiry, lapsed by a revocation row, and one whose expiry
    /// cannot be parsed (so activity is unverifiable and must fail closed).
    private static let lapsedConsentFixtures: [(name: String, contents: String)] = [
        (
            name: "expired",
            contents: """
            ---
            grants:
              - grant_ref: expired-self-record-grant
                basis: self_record
                scope: device+adapter:v1-voice-memo
                granted_at: 2026-07-01T09:00:00+00:00
                expiry: 2026-07-10T09:00:00+00:00
            ---
            """ + "\n"
        ),
        (
            name: "revoked",
            contents: """
            ---
            grants:
              - grant_ref: revoked-self-record-grant
                basis: self_record
                scope: device+adapter:v1-voice-memo
                granted_at: 2026-07-01T09:00:00+00:00
                expiry: null
              - grant_ref: revocation-row
                basis: revocation
                revokes_grant_ref: revoked-self-record-grant
                granted_at: 2026-07-05T09:00:00+00:00
            ---
            """ + "\n"
        ),
        (
            name: "unverifiable-expiry",
            contents: """
            ---
            grants:
              - grant_ref: unparseable-expiry-grant
                basis: self_record
                scope: device+adapter:v1-voice-memo
                granted_at: 2026-07-01T09:00:00+00:00
                expiry: "sometime next spring"
            ---
            """ + "\n"
        )
    ]

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
