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
                MimerShellView(vaultURL: fixtureVaultURL)
            } else if let vaultURL = vaultManager.activeVaultURL {
                TabView {
                    MimerShellView(vaultURL: vaultURL)
                        .tabItem { Label("Mimer", systemImage: "book.closed") }
                    HeimdalShellView(sessionModel: heimdalSessionModel)
                        .tabItem { Label("Heimdal", systemImage: "waveform") }
                }
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
    return root
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
    let consentFixture = """
    ---
    grants:
      - grant_ref: fixture-grant
        scope: fixture consent
        basis: test fixture
        granted_at: 2026-07-26
    ---
    """ + "\n"
    return [
        HeimdalPaths.attention(for: Date()): "---\ncounts:\n  fixture_attention: 1\n---\n",
        HeimdalPaths.interests: "---\nweights:\n  fixture_interest: 0.5\n---\n",
        HeimdalPaths.watchlist: "---\nwatched:\n  - fixture watch\n---\n",
        HeimdalPaths.never: "---\nnever:\n  - fixture never\n---\n",
        HeimdalPaths.entityReview: entityReviewFixture,
        HeimdalPaths.consent: consentFixture,
        HeimdalPaths.settings: "---\nretention_window_days: 45\n---\n",
        "_heimdal/uat-roundtrip.md": "# UAT fixture note\n\nInitial fixture content.\n"
    ]
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
