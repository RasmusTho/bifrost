import SwiftUI
import YggdrasilCore

/// A17 lens: score-banded entity review queue with a reversible merge/reject
/// action — the side-by-side confirmation surface the ADR calls out as the
/// app's clearest win over Obsidian.
struct EntityConfirmLensView: View {
    let fileStore: VaultFileStore

    @State private var pending: [EntityReviewEntry] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var lastRefreshedAt: Date?
    @State private var selectedCandidateIDs: [String: String] = [:]

    var body: some View {
        YggLensScaffold(
            title: "Entities",
            sourcePath: HeimdalPaths.entityReview,
            isLoading: isLoading,
            loadError: loadError,
            lastRefreshedAt: lastRefreshedAt,
            onRetry: load
        ) {
                Section {
                    if pending.isEmpty {
                        YggEmptyState(
                            systemImage: "checkmark.circle",
                            title: "Queue clear",
                            message: "No entity mentions waiting for confirmation."
                        )
                        .listRowBackground(Color.clear)
                    }
                    ForEach(pending) { entry in
                        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
                            Text(entry.surfaceForm)
                                .font(YggTheme.Typography.sectionHeader)
                            if let confidence = entry.confidence {
                                YggStatusPill(
                                    title: "confidence \(Int(confidence * 100))%",
                                    systemImage: "chart.bar",
                                    kind: .agent
                                )
                            }
                            if entry.candidateEntityIDs.isEmpty {
                                YggBanner(
                                    title: "No merge target",
                                    message: "Reject this mention or wait for another candidate.",
                                    kind: .pending
                                )
                            } else {
                                Text("Choose a candidate")
                                    .font(YggTheme.Typography.caption.weight(.semibold))
                                    .foregroundStyle(YggTheme.Color.textSecondary)
                                ForEach(entry.candidateEntityIDs, id: \.self) { candidateID in
                                    candidateButton(candidateID, for: entry)
                                }
                            }
                            HStack {
                                Button("Merge selected") { decide(entry, action: "merge") }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(selectedCandidateIDs[entry.id] == nil)
                                Button("Reject") { decide(entry, action: "reject") }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, YggTheme.Spacing.xs)
                    }
                }
            }
            .onAppear(perform: load)
    }

    private func load() {
        isLoading = true
        defer {
            isLoading = false
            lastRefreshedAt = Date()
        }
        do {
            let text = try fileStore.read(HeimdalPaths.entityReview)
            pending = EntityReviewNote(document: try FrontmatterDocument.parse(text)).pending
            let pendingIDs = Set(pending.map(\.id))
            selectedCandidateIDs = selectedCandidateIDs.filter { pendingIDs.contains($0.key) }
            loadError = nil
        } catch VaultFileStoreError.notFound {
            pending = []
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func candidateButton(_ candidateID: String, for entry: EntityReviewEntry) -> some View {
        let isSelected = selectedCandidateIDs[entry.id] == candidateID
        Button {
            selectedCandidateIDs[entry.id] = candidateID
        } label: {
            HStack(spacing: YggTheme.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? YggTheme.Color.agent : YggTheme.Color.textSecondary)
                Text(candidateID)
                    .font(YggTheme.Typography.monospaceBody)
                    .foregroundStyle(YggTheme.Color.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, YggTheme.Spacing.sm)
            .padding(.vertical, YggTheme.Spacing.smd)
            .background(isSelected ? YggTheme.Color.agent.opacity(0.14) : YggTheme.Color.secondaryBackground)
            .overlay {
                RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous)
                    .stroke(
                        isSelected ? YggTheme.Color.agent : YggTheme.Color.divider,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Candidate \(candidateID)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func decide(_ entry: EntityReviewEntry, action: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard action == "reject" || selectedCandidateIDs[entry.id] != nil else { return }
        let intoId = action == "merge" ? (selectedCandidateIDs[entry.id] ?? "") : ""
        do {
            try fileStore.readModifyWrite(HeimdalPaths.entityReview) { document in
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
            selectedCandidateIDs[entry.id] = nil
            load()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
