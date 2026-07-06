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
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
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
        do {
            let text = try fileStore.read(HeimdalPaths.entityReview)
            pending = EntityReviewNote(document: try FrontmatterDocument.parse(text)).pending
            loadError = nil
        } catch VaultFileStoreError.notFound {
            pending = []
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func decide(_ entry: EntityReviewEntry, action: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let candidate = entry.candidateEntityIDs.first ?? entry.mentionId
        do {
            try fileStore.readModifyWrite(HeimdalPaths.entityReview) { document in
                var note = EntityReviewNote(document: document)
                note.addDecision(
                    queueEntryId: entry.id,
                    action: action,
                    fromId: entry.mentionId,
                    intoId: candidate,
                    decidedAt: timestamp
                )
                document = note.document
            }
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
