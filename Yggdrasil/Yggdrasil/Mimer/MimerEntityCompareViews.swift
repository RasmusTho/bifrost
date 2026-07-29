import SwiftUI
import YggdrasilCore

struct MimerEntityQueueView: View {
    @ObservedObject var model: MimerEntityCompareModel

    var body: some View {
        List {
            if let loadError = model.loadError {
                Text(loadError).foregroundStyle(.red)
            }
            if model.isLoading, model.pending.isEmpty {
                ProgressView("Loading entity review")
            } else if model.pending.isEmpty {
                YggEmptyState(
                    systemImage: "checkmark.circle",
                    title: "Queue Clear",
                    message: "No entity mentions waiting for confirmation."
                )
            } else {
                ForEach(model.pending) { entry in
                    Button {
                        model.selectEntry(entry.id)
                    } label: {
                        queueRow(entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mimer.entity.queue.\(entry.id)")
                }
            }
        }
        .navigationTitle("Entity Review")
        .task {
            if model.pending.isEmpty { await model.load() }
        }
    }

    private func queueRow(_ entry: EntityReviewEntry) -> some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
            HStack {
                Text(entry.surfaceForm)
                    .font(YggTheme.Typography.sectionHeader)
                Spacer()
                if model.selectedEntryID == entry.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(YggTheme.Color.accent)
                }
            }
            HStack {
                Text(confidenceDescription(entry.confidence))
                Spacer()
                Text("\(entry.candidateEntityIDs.count) candidates")
            }
            .font(YggTheme.Typography.caption)
            .foregroundStyle(YggTheme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func confidenceDescription(_ confidence: Double?) -> String {
        guard let confidence else { return "Confidence unavailable" }
        let band: String
        switch confidence {
        case ..<0.6:
            band = "low"
        case 0.9...:
            band = "high"
        default:
            band = "review"
        }
        return "\(Int(confidence * 100))% · \(band) band"
    }
}

struct MimerEntityCompareDetailView: View {
    @ObservedObject var model: MimerEntityCompareModel

    var body: some View {
        Group {
            if let entry = model.selectedEntry {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: YggTheme.Spacing.md) {
                        mentionCard(entry)
                        candidateColumn
                    }
                    .padding(YggTheme.Spacing.md)
                    Divider()
                    actionBar
                        .padding(YggTheme.Spacing.md)
                }
                .navigationTitle(entry.surfaceForm)
            } else {
                YggEmptyState(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: "Select a Mention",
                    message: "Choose a pending entity mention to compare candidates."
                )
            }
        }
    }

    private func mentionCard(_ entry: EntityReviewEntry) -> some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
            Label("Mention context", systemImage: "text.quote")
                .font(YggTheme.Typography.sectionHeader)
            Text(entry.surfaceForm)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("mimer.entity.mention.surface")
            LabeledContent("mention_id", value: entry.mentionId)
            LabeledContent("resolution", value: entry.resolution)
            if let confidence = entry.confidence {
                LabeledContent("confidence", value: "\(Int(confidence * 100))%")
            }
            Spacer()
        }
        .padding(YggTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(YggTheme.Color.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.card))
    }

    private var candidateColumn: some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
            HStack {
                Label("Candidate notes", systemImage: "person.2")
                    .font(YggTheme.Typography.sectionHeader)
                Spacer()
                Text("\(model.candidates.count)")
                    .foregroundStyle(YggTheme.Color.textSecondary)
            }
            ScrollView {
                LazyVStack(spacing: YggTheme.Spacing.sm) {
                    ForEach(model.candidates) { candidate in
                        candidateCard(candidate)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func candidateCard(_ candidate: MimerEntityCandidate) -> some View {
        Button {
            model.selectCandidate(candidate.entityID)
        } label: {
            candidateCardContent(candidate)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mimer.entity.candidate.\(candidate.entityID)")
    }

    private func candidateCardContent(_ candidate: MimerEntityCandidate) -> some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
            candidateHeader(candidate)
            if let kind = candidate.kind {
                Text([kind, candidate.lifecycle].compactMap { $0 }.joined(separator: " · "))
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(YggTheme.Color.textSecondary)
            }
            candidateAvailability(candidate)
        }
        .padding(YggTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            model.selectedCandidateID == candidate.entityID
                ? YggTheme.Color.accent.opacity(0.12)
                : YggTheme.Color.secondaryBackground
        )
        .overlay {
            RoundedRectangle(cornerRadius: YggTheme.Radius.card)
                .stroke(
                    model.selectedCandidateID == candidate.entityID
                        ? YggTheme.Color.accent
                        : YggTheme.Color.divider
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: YggTheme.Radius.card))
    }

    private func candidateHeader(_ candidate: MimerEntityCandidate) -> some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.label)
                    .font(YggTheme.Typography.sectionHeader)
                Spacer()
                if model.selectedCandidateID == candidate.entityID {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(YggTheme.Color.accent)
                }
            }
            Text(candidate.entityID)
                .font(YggTheme.Typography.caption.monospaced())
                .foregroundStyle(YggTheme.Color.textSecondary)
        }
    }

    @ViewBuilder
    private func candidateAvailability(_ candidate: MimerEntityCandidate) -> some View {
        switch candidate.availability {
        case .note:
            MarkdownRendererView(text: candidate.markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .missing:
            Label("No note yet", systemImage: "doc.badge.ellipsis")
                .foregroundStyle(YggTheme.Color.textSecondary)
        case .unreadable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(YggTheme.Color.warning)
        }
    }

    private var actionBar: some View {
        HStack(spacing: YggTheme.Spacing.sm) {
            Text(model.decisionStatus)
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
                .accessibilityIdentifier("mimer.entity.decision.state")
            Spacer()
            Button("Undo") { Task { await model.undo() } }
                .buttonStyle(.bordered)
                .disabled(!model.canUndo)
                .accessibilityIdentifier("mimer.entity.undo")
            Button("Reject") { Task { await model.reject() } }
                .buttonStyle(.bordered)
                .disabled(!model.canReject)
                .accessibilityIdentifier("mimer.entity.reject")
            Button("Merge") { Task { await model.merge() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canMerge)
                .accessibilityIdentifier("mimer.entity.merge")
        }
    }
}

struct MimerLensContentView: View {
    let lens: MimerLens
    let fileStore: VaultFileStore

    @ViewBuilder
    var body: some View {
        switch lens {
        case .today:
            AttentionLensView(fileStore: fileStore)
        case .interests:
            InterestsLensView(fileStore: fileStore)
        case .entities:
            EntityConfirmLensView(fileStore: fileStore)
        case .consent:
            ConsentLensView(fileStore: fileStore)
        case .vault:
            NavigationStack {
                NoteBrowserView(fileStore: fileStore)
            }
        case .settings:
            SettingsLensView(fileStore: fileStore)
        }
    }
}
