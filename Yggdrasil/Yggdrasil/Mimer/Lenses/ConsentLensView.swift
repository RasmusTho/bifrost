import SwiftUI
import YggdrasilCore

/// A19 lens: a read-only readout of `consent.md`. Consent is granted through
/// Heimdal's capture flow, not edited here — this client only displays the
/// ledger-derived state so the human can see what's granted.
struct ConsentLensView: View {
    let fileStore: VaultFileStore

    @State private var note: ConsentNote?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
                Section("Grants") {
                    if let grants = note?.grants, !grants.isEmpty {
                        ForEach(Array(grants.enumerated()), id: \.offset) { _, grant in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(grant.scope ?? "unspecified scope").font(.body.weight(.medium))
                                if let basis = grant.basis {
                                    Text("basis: \(basis)")
                                        .font(YggTheme.Typography.caption)
                                        .foregroundStyle(YggTheme.Color.textSecondary)
                                }
                                if let grantedAt = grant.grantedAt {
                                    Text("granted \(grantedAt)")
                                        .font(YggTheme.Typography.caption)
                                        .foregroundStyle(YggTheme.Color.textSecondary)
                                }
                            }
                        }
                    } else {
                        Text("No consent grants recorded yet.")
                            .foregroundStyle(YggTheme.Color.textSecondary)
                    }
                }
                Section("Dormant in v1") {
                    let withholdEnabled = note?.withholdReviewEnabled ?? false
                    Label(
                        withholdEnabled ? "Withhold-review enabled" : "Withhold-review not enabled",
                        systemImage: "eye.slash"
                    )
                    let erasureSupported = note?.retentionErasureSupported ?? false
                    Label(
                        erasureSupported ? "Erasure requests supported" : "Erasure requests not yet supported",
                        systemImage: "trash"
                    )
                    .foregroundStyle(YggTheme.Color.textSecondary)
                }
            }
            .navigationTitle("Consent")
            .onAppear(perform: load)
        }
    }

    private func load() {
        do {
            let text = try fileStore.read(HeimdalPaths.consent)
            note = ConsentNote(document: try FrontmatterDocument.parse(text))
            loadError = nil
        } catch VaultFileStoreError.notFound {
            note = nil
            loadError = "No consent.md yet in this vault."
        } catch {
            loadError = error.localizedDescription
        }
    }
}
