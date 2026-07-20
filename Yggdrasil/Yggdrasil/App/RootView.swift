import SwiftUI

/// Routes: auth gate → vault pick → Mimer-iPhone shell. This is the entire
/// "thin host shell" the Issue asks for — everything past auth/vault-pick is
/// a hosted client (Mimer-iPhone today).
struct RootView: View {
    @StateObject private var authGate: AuthGate
    @StateObject private var vaultManager = VaultManager()

    init(authGateInitialState: AuthGate.State = .locked) {
        _authGate = StateObject(wrappedValue: AuthGate(initialState: authGateInitialState))
    }

    var body: some View {
        Group {
            if authGate.state != .unlocked {
                AuthGateView(gate: authGate)
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-mimer-shell") {
                // UI tests exercise the client layout against an ephemeral,
                // read-only test root. This bypasses only the visual picker;
                // it does not create a bookmark or alter vault data flows.
                MimerShellView(vaultURL: mimerTestingVaultURL())
            } else if let vaultURL = vaultManager.activeVaultURL {
                TabView {
                    MimerShellView(vaultURL: vaultURL)
                        .tabItem { Label("Mimer", systemImage: "book.closed") }
                    HeimdalShellView()
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
                    HeimdalShellView()
                        .tabItem { Label("Heimdal", systemImage: "waveform") }
                }
            }
        }
    }
}

/// Test-only fixture setup keeps UI tests independent of a human vault. The
/// canvas itself still uses only the normal read/list store calls against this
/// temporary directory.
private func mimerTestingVaultURL() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MimerCanvasUITestVault")
    guard ProcessInfo.processInfo.arguments.contains("-ui-testing-mimer-fixture") else { return root }
    let projects = root.appendingPathComponent("Projects")
    let note = projects.appendingPathComponent("fixture.md")
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
    return root
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
