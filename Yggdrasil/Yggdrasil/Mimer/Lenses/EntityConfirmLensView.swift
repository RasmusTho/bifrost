import SwiftUI
import YggdrasilCore

/// A17 lens: score-banded entity review queue with a reversible merge/reject
/// action — the side-by-side confirmation surface the ADR calls out as the
/// app's clearest win over Obsidian.
struct EntityConfirmLensView: View {
    let fileStore: VaultFileStore

    @State private var pending: [EntityReviewEntry] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                LensScaffold.errorBanner(loadError)
                if pending.isEmpty {
                    YggEmptyState(
                        systemImage: "checkmark.circle",
                        title: "Queue Clear",
                        message: "No entity mentions waiting for confirmation."
                    )
                } else {
                    ForEach(pending) { entry in
                        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
                            Text(entry.surfaceForm).font(.body.weight(.semibold))
                            if let confidence = entry.confidence {
                                Text("confidence \(Int(confidence * 100))%")
                                    .font(YggTheme.Typography.caption)
                                    .foregroundStyle(YggTheme.Color.textSecondary)
                            }
                            if !entry.candidateEntityIDs.isEmpty {
                                Text("Candidates: \(entry.candidateEntityIDs.joined(separator: ", "))")
                                    .font(YggTheme.Typography.caption)
                            }
                            HStack {
                                Button("Merge") { decide(entry, action: "merge") }
                                    .buttonStyle(.borderedProminent)
                                Button("Reject") { decide(entry, action: "reject") }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, YggTheme.Spacing.xs)
                    }
                }
            }
            .navigationTitle("Entities")
            .onAppear(perform: load)
        }
    }

    private func load() {
        Task { @MainActor in
            do {
                let text = try await fileStore.read(HeimdalPaths.entityReview)
                pending = EntityReviewNote(document: try FrontmatterDocument.parse(text)).pending
                loadError = nil
            } catch VaultFileStoreError.notFound(_) {
                pending = []
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func decide(_ entry: EntityReviewEntry, action: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        // Only "merge" has a real target; "reject" has none — falling back to
        // mentionId there would record a self-merge instead of a dismissal.
        let intoId = action == "merge" ? (entry.candidateEntityIDs.first ?? entry.mentionId) : ""
        Task { @MainActor in
            do {
                try await fileStore.readModifyWrite(HeimdalPaths.entityReview) { document in
                    var note = EntityReviewNote(document: document)
                    note.addDecision(
                        queueEntryId: entry.id,
                        action: action,
                        fromId: entry.mentionId,
                        intoId: intoId,
                        decidedAt: timestamp
                    )
                    document = note.document
                }
                loadError = nil
                load()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
