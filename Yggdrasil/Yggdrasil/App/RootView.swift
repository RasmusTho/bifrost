import Foundation
import SwiftUI
import YggdrasilCore

/// DEBUG-only launch configuration for deterministic UI journeys. Every
/// override requires the explicit `-ui-testing` marker, so shipping builds
/// continue through the normal auth and visual vault-picker paths.
struct UITestLaunchConfiguration {
    enum FixtureKind: Equatable {
        case canvas
        case uat
    }

    let arguments: [String]

    static var current: UITestLaunchConfiguration {
        UITestLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
    }

    var authInitialState: AuthGate.State? {
        guard isEnabled, arguments.contains("-ui-testing-auth-unlocked") else { return nil }
        return .unlocked
    }

    var holdsAuthenticationGate: Bool {
        isEnabled && arguments.contains("-ui-testing-auth-locked")
    }

    var fixtureKind: FixtureKind? {
        guard isEnabled else { return nil }
        if arguments.contains("-ui-testing-uat-fixture") { return .uat }
        if arguments.contains("-ui-testing-mimer-shell") { return .canvas }
        return nil
    }

    var fixtureIdentifier: String? {
        guard fixtureKind == .uat,
              let flagIndex = arguments.firstIndex(of: "-ui-testing-uat-fixture"),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        return arguments[flagIndex + 1]
    }

    /// DEBUG-only scripted hub for the composed transfer-queue journey: down for
    /// the first query, answering afterwards. `nil` in release, so the shipping
    /// build always uses the real status source.
    var scriptedTransferQueueHub: TransferQueueStatusSource? {
        guard isEnabled, arguments.contains("-ui-testing-transfer-queue") else { return nil }
        return ScriptedHubStatusSource()
    }

    /// DEBUG-only seeding of one outbox item so the journey has something to
    /// watch advance. Returns the capture identity it seeded.
    @discardableResult
    func seedTransferQueueFixtureIfNeeded() -> String? {
        guard isEnabled, arguments.contains("-ui-testing-transfer-queue") else { return nil }
        let store = TransferOutboxStore()
        if let existing = try? store.loadAll(), !existing.isEmpty {
            return existing.first?.captureID
        }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-queue-fixture-\(UUID().uuidString).m4a")
        guard (try? Data("fixture-audio".utf8).write(to: source)) != nil else { return nil }
        let seeded = try? store.enqueue(
            finalizedMediaURL: source,
            capturedAt: Date(),
            deviceID: "ui-test-device"
        )
        guard let seeded else { return nil }
        // Receipt persisted so the journey starts from a locally-evidenced
        // state the hub can then report progress on.
        try? store.persistReceipt(
            DurableAcceptanceReceipt(
                receiptID: "ui-test-receipt",
                captureID: seeded.captureID,
                contentSHA256: seeded.envelope.contentSHA256,
                admittedAt: Date()
            ),
            for: seeded.captureID
        )
        return seeded.captureID
    }

    private var isEnabled: Bool {
#if DEBUG
        arguments.contains("-ui-testing")
#else
        false
#endif
    }
}

/// Routes: auth gate → vault pick → Mimer-iPhone shell. This is the entire
/// "thin host shell" the Issue asks for — everything past auth/vault-pick is
/// a hosted client (Mimer-iPhone today).
struct RootView: View {
    @StateObject private var authGate: AuthGate
    @StateObject private var vaultManager = VaultManager()
    private let heimdalSessionModel: CaptureSessionModel
    private let testLaunchConfiguration: UITestLaunchConfiguration

    init(
        authGateInitialState: AuthGate.State = .locked,
        heimdalSessionModel: CaptureSessionModel,
        testLaunchConfiguration: UITestLaunchConfiguration = .current
    ) {
        _authGate = StateObject(
            wrappedValue: AuthGate(
                initialState: authGateInitialState,
                suppressAutomaticAuthentication: testLaunchConfiguration.holdsAuthenticationGate
            )
        )
        self.heimdalSessionModel = heimdalSessionModel
        self.testLaunchConfiguration = testLaunchConfiguration
    }

    var body: some View {
        Group {
            if authGate.state != .unlocked {
                AuthGateView(gate: authGate)
            } else if let fixtureVaultURL = testFixtureVaultURL {
                // UI tests use an ephemeral fixture root. This bypasses only
                // the visual picker; it does not create a bookmark or alter
                // production vault data flows.
                shell(vaultURL: fixtureVaultURL)
            } else if let vaultURL = vaultManager.activeVaultURL {
                shell(vaultURL: vaultURL)
                .toolbarBackground(.visible, for: .tabBar)
                .safeAreaInset(edge: .top) {
                    VaultSwitcherBar(vaultManager: vaultManager)
                }
            } else {
                TabView {
                    VaultPickerView(vaultManager: vaultManager)
                        .tabItem { Label("Mimer", systemImage: "book.closed") }
                    HeimdalShellView(sessionModel: heimdalSessionModel)
                        .tabItem { Label("Heimdal", systemImage: "waveform") }
                }
            }
        }
    }

    private func shell(vaultURL: URL) -> some View {
        TabView {
            MimerShellView(vaultURL: vaultURL)
                .tabItem { Label("Mimer", systemImage: "book.closed") }
            HeimdalShellView(
                sessionModel: heimdalSessionModel,
                fileStore: VaultFileStore(rootURL: vaultURL)
            )
            .tabItem { Label("Heimdal", systemImage: "waveform") }
            TransferQueueHost(
                store: TransferOutboxStore(),
                statusSource: testLaunchConfiguration.scriptedTransferQueueHub
                    ?? UnreachableHubStatusSource()
            )
            .tabItem { Label("Queue", systemImage: "tray.full") }
        }
    }

    private var testFixtureVaultURL: URL? {
#if DEBUG
        guard let fixtureKind = testLaunchConfiguration.fixtureKind else { return nil }
        return mimerTestingVaultURL(for: fixtureKind, fixtureIdentifier: testLaunchConfiguration.fixtureIdentifier)
#else
        nil
#endif
    }
}

/// Test-only fixture setup keeps UI tests independent of a human vault. The
/// client still uses only the normal read/list/write store calls against this
/// temporary directory.
private func mimerTestingVaultURL(
    for fixtureKind: UITestLaunchConfiguration.FixtureKind,
    fixtureIdentifier: String?
) -> URL {
    switch fixtureKind {
    case .canvas:
        return canvasTestingVaultURL()
    case .uat:
        return uatTestingVaultURL(identifier: fixtureIdentifier ?? "default")
    }
}

private func canvasTestingVaultURL() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimerCanvasUITestVault")
    let projects = root.appendingPathComponent("Projects")
    let note = projects.appendingPathComponent("fixture.md")
    let sourceNote = projects.appendingPathComponent("source.md")
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let fixture = """
    ---
    uuid: fixture-uuid
    origin: ui-test
    agent_provenance:
      author: bifrost-ios
    ---

    # Fixture note
    """ + "\n"
    try? Data(fixture.utf8).write(to: note, options: .atomic)
    try? Data("---\ntitle: Source\n---\n\n# Source note\n".utf8).write(to: sourceNote, options: .atomic)
    writeCanvasEntityFixture(to: root)
    return root
}

private func writeCanvasEntityFixture(to root: URL) {
    let files = [
        // Three pending rows deliberately cover 0/1/2 candidate shapes so
        // composed journeys and slice tests can exercise every compare
        // surface (empty candidate column, single-candidate merge, and the
        // ambiguous two-candidate case) without inventing new fixture files.
        "_heimdal/entities/review.md": """
        ---
        pending:
          - queue_entry_id: entity-compare-fixture
            mention_id: mention:anna
            surface_form: "Anna"
            resolution: ambiguous
            confidence: 0.71
            candidate_entity_ids: [ent:anna, ent:missing]
          - queue_entry_id: entity-compare-fixture-single
            mention_id: mention:bob
            surface_form: "Bob"
            resolution: ambiguous
            confidence: 0.65
            candidate_entity_ids: [ent:anna]
          - queue_entry_id: entity-compare-fixture-none
            mention_id: mention:orphan
            surface_form: "Orphan"
            resolution: ambiguous
            confidence: 0.4
            candidate_entity_ids: []
        decisions: []
        ---

        Fixture review note.
        """ + "\n",
        "_heimdal/register/ent-anna.md": """
        ---
        entity_id: ent:anna
        label: Anna Andersson
        kind: person
        lifecycle: canonical
        ---

        # Anna Andersson

        Canonical candidate context.
        """ + "\n"
    ]
    for (relativePath, contents) in files {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(contents.utf8).write(to: url, options: .atomic)
    }
}

private func uatTestingVaultURL(identifier: String) -> URL {
    let safeIdentifier = identifier.unicodeScalars.filter { scalar in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
    }
    let fixtureDirectoryName = String(String.UnicodeScalarView(safeIdentifier))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "YggdrasilUATUITestVault-\(fixtureDirectoryName.isEmpty ? "default" : fixtureDirectoryName)"
    )
    let marker = root.appendingPathComponent(".seeded")
    guard !FileManager.default.fileExists(atPath: marker.path) else { return root }

    do {
        for (relativePath, contents) in uatFixtureFiles() {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try Data().write(to: marker, options: .atomic)
    } catch {
        assertionFailure("Couldn't create the UI-test fixture vault: \(error)")
    }
    return root
}

private func uatFixtureFiles() -> [String: String] {
    let entityReviewFixture = """
    ---
    pending:
      - queue_entry_id: fixture-entry
        mention_id: fixture-mention
        surface_form: "Fixture Entity"
        resolution: pending
        confidence: 0.9
    decisions: []
    ---
    """ + "\n"
    var files = [
        HeimdalPaths.attention(for: Date()): "---\ncounts:\n  fixture_attention: 1\n---\n",
        HeimdalPaths.interests: "---\nweights:\n  fixture_interest: 0.5\n---\n",
        HeimdalPaths.watchlist: "---\nwatched:\n  - fixture watch\n---\n",
        HeimdalPaths.never: "---\nnever:\n  - fixture never\n---\n",
        HeimdalPaths.entityReview: entityReviewFixture,
        HeimdalPaths.consent: standingGrantConsentFixture(),
        HeimdalPaths.settings: "---\nretention_window_days: 45\n---\n",
        "_heimdal/uat-roundtrip.md": "# UAT fixture note\n\nInitial fixture content.\n"
    ]
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("-ui-testing-no-consent") {
        files.removeValue(forKey: HeimdalPaths.consent)
    } else if arguments.contains("-ui-testing-consent-no-active-grant") {
        files[HeimdalPaths.consent] = noActiveGrantConsentFixture()
    }
    return files
}

/// Mirrors the hub readout: oldest-first by ledger sequence, with `basis`
/// carrying the grant kind. The leading `place_optin` row is the decoy an
/// unfiltered `grants.first` would surface as the standing grant.
private func standingGrantConsentFixture() -> String {
    """
    ---
    grants:
      - grant_ref: fixture-place-optin
        scope: fixture place opt-in
        basis: place_optin
        granted_at: 2026-07-20
      - grant_ref: fixture-grant
        scope: fixture consent
        basis: self_record
        granted_at: 2026-07-26
        expiry: null
    ---
    """ + "\n"
}

/// Grants present, but none of them an active self-record grant: an unrelated
/// basis, an expired self-record grant, and a revoked one.
private func noActiveGrantConsentFixture() -> String {
    """
    ---
    grants:
      - grant_ref: fixture-place-optin
        scope: fixture place opt-in
        basis: place_optin
        granted_at: 2026-07-20
      - grant_ref: fixture-expired-self-record
        scope: fixture expired consent
        basis: self_record
        granted_at: 2026-07-01
        expiry: 2026-07-10T00:00:00+00:00
      - grant_ref: fixture-revoked-self-record
        scope: fixture revoked consent
        basis: self_record
        granted_at: 2026-07-02
        expiry: null
      - grant_ref: fixture-revocation
        basis: revocation
        revokes_grant_ref: fixture-revoked-self-record
        granted_at: 2026-07-03
    ---
    """ + "\n"
}

private struct VaultSwitcherBar: View {
    @ObservedObject var vaultManager: VaultManager

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
            Text(vaultManager.activeVaultReference?.displayName ?? "Vault")
                .font(YggTheme.Typography.caption)
                .lineLimit(1)
            Spacer()
            Button("Switch") { vaultManager.closeVault() }
                .font(YggTheme.Typography.caption)
        }
        .padding(.horizontal, YggTheme.Spacing.md)
        .padding(.vertical, YggTheme.Spacing.xs)
        .background(YggTheme.Color.secondaryBackground)
    }
}
