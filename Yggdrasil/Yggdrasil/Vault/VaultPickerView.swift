import SwiftUI
import YggdrasilCore

/// The vault-selection screen: recent vaults as visual tiles, or "Choose a
/// Vault Folder" which opens the system folder picker. No path typing.
struct VaultPickerView: View {
    @ObservedObject var vaultManager: VaultManager
    @State private var isPickerPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YggTheme.Spacing.lg) {
                    if !vaultManager.recentVaults.isEmpty {
                        YggSectionHeader(title: "Recent Vaults")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: YggTheme.Spacing.md)], spacing: YggTheme.Spacing.md) {
                            ForEach(vaultManager.recentVaults) { reference in
                                Button {
                                    vaultManager.activate(reference)
                                } label: {
                                    VaultTile(reference: reference)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        YggEmptyState(
                            systemImage: "folder.badge.questionmark",
                            title: "No Vault Yet",
                            message: "Pick the Obsidian vault folder you want Yggdrasil to open."
                        )
                    }

                    if let error = vaultManager.lastError {
                        Text(error)
                            .font(YggTheme.Typography.caption)
                            .foregroundStyle(.red)
                    }

                    YggPrimaryButton(title: "Choose a Vault Folder") {
                        isPickerPresented = true
                    }
                }
                .padding(YggTheme.Spacing.md)
            }
            .navigationTitle("Yggdrasil")
            .sheet(isPresented: $isPickerPresented) {
                VaultFolderPicker { url in
                    vaultManager.openVault(at: url)
                    isPickerPresented = false
                }
            }
        }
    }
}

private struct VaultTile: View {
    let reference: VaultReference

    var body: some View {
        YggCard {
            Image(systemName: "folder.fill")
                .font(.system(size: 28))
                .foregroundStyle(YggTheme.Color.accent)
            Text(reference.displayName)
                .font(YggTheme.Typography.body.weight(.medium))
                .lineLimit(1)
            Text(reference.lastOpenedAt, style: .relative)
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
        }
    }
}
