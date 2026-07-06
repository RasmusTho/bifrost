import SwiftUI

/// Routes: auth gate → vault pick → Mimer-iPhone shell. This is the entire
/// "thin host shell" the Issue asks for — everything past auth/vault-pick is
/// a hosted client (Mimer-iPhone today).
struct RootView: View {
    @StateObject private var authGate = AuthGate()
    @StateObject private var vaultManager = VaultManager()

    var body: some View {
        Group {
            if authGate.state != .unlocked {
                AuthGateView(gate: authGate)
            } else if let vaultURL = vaultManager.activeVaultURL {
                MimerShellView(vaultURL: vaultURL)
                    .toolbarBackground(.visible, for: .tabBar)
                    .safeAreaInset(edge: .top) {
                        VaultSwitcherBar(vaultManager: vaultManager)
                    }
            } else {
                VaultPickerView(vaultManager: vaultManager)
            }
        }
    }
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
