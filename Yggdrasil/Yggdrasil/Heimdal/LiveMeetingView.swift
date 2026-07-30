import SwiftUI

/// The live meeting surface: two structurally separate regions side by side.
///
/// The separation is load-bearing, not decorative. CDLM-07 guarantees on the hub
/// that derived writers cannot touch `user_note` blocks; if this view rendered
/// AI content inside the user region, that guarantee would become a UI lie. The
/// two regions therefore read from two different published properties and share
/// no rendering path.
struct LiveMeetingView: View {
    @ObservedObject var model: LiveMeetingViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // `.accessibilityElement(children: .contain)` is required alongside
            // the identifier: identifying a container on its own collapses it
            // into one opaque element and hides everything inside it, which
            // would make the region assertions pass while the contents were
            // unreachable.
            aiRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("meeting.region.ai")
            Divider()
            userRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("meeting.region.user")
        }
        .navigationTitle("Meeting")
    }

    // MARK: - AI region

    private var aiRegion: some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
            HStack {
                Text("AI uppdaterar löpande")
                    .font(YggTheme.Typography.caption)
                    .accessibilityIdentifier("meeting.ai.title")
                if model.projectionIsStale {
                    Text("(last known)")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                        .accessibilityIdentifier("meeting.ai.stale")
                }
            }
            Text("Revision \(model.projection.revision)")
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
                .accessibilityIdentifier("meeting.ai.revision")

            if !model.projection.missingSequences.isEmpty {
                // Gaps are stated, never smoothed over: a derived understanding
                // built on an incomplete ledger must say so.
                Text("Missing segments: \(model.projection.missingSequences.map(String.init).joined(separator: ", "))")
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("meeting.ai.gaps")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
                    ForEach(model.projection.transcript) { entry in
                        Text(entry.text)
                            .accessibilityIdentifier("meeting.ai.transcript.\(entry.sessionSeq)")
                    }
                    ForEach(model.projection.derivedBlocks) { block in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.text)
                            // Provisionality travels with every derived block.
                            Text("provisional · r\(block.revision) · from \(coverage(block))")
                                .font(YggTheme.Typography.caption)
                                .foregroundStyle(YggTheme.Color.textSecondary)
                                .accessibilityIdentifier("meeting.ai.provisional.\(block.id)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(YggTheme.Spacing.md)
    }

    private func coverage(_ block: DerivedBlock) -> String {
        block.derivedFromSeqs.map(String.init).joined(separator: ",")
    }

    // MARK: - User region

    private var userRegion: some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.sm) {
            Text("Dina anteckningar")
                .font(YggTheme.Typography.caption)
                .accessibilityIdentifier("meeting.user.title")

            // The editor and its controls sit above the notes list so a long
            // list can never push the user's own input surface off-screen.
            TextField("Your note", text: $model.editorText, axis: .vertical)
                .accessibilityIdentifier("meeting.user.editor")
            Button("Save Note") { Task { await model.commitEditorText() } }
                .accessibilityIdentifier("meeting.user.save")

            HStack {
                Button("Reconnect") { Task { await model.reconnect() } }
                    .accessibilityIdentifier("meeting.reconnect")
                Button("End Meeting") { Task { await model.endMeeting() } }
                    .accessibilityIdentifier("meeting.end")
            }

            // Only the user's own blocks are ever rendered here.
            ScrollView {
                VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
                    ForEach(model.userNotes) { note in
                        HStack(alignment: .top) {
                            Text(note.text)
                                .accessibilityIdentifier("meeting.user.note.\(note.noteBlockID)")
                            Spacer()
                            Text(note.isSynced ? "synced" : "pending")
                                .font(YggTheme.Typography.caption)
                                .foregroundStyle(YggTheme.Color.textSecondary)
                                .accessibilityIdentifier("meeting.user.noteState.\(note.noteBlockID)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(YggTheme.Spacing.md)
        .overlay(alignment: .bottom) { finalViewSummary }
    }

    @ViewBuilder
    private var finalViewSummary: some View {
        if let final = model.finalView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting ended")
                    .accessibilityIdentifier("meeting.final")
                Text("Transcript \(final.consolidatedTranscript.count) · "
                    + "Analysis \(final.finalDerivedBlocks.count) · Notes \(final.userNotes.count)")
                    .font(YggTheme.Typography.caption)
                    .accessibilityIdentifier("meeting.final.artifacts")
                if final.needsAttention {
                    Text("Needs attention — missing segments: "
                        + final.needsAttentionSequences.map(String.init).joined(separator: ", "))
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("meeting.final.needsAttention")
                }
            }
            .padding(YggTheme.Spacing.sm)
            .background(YggTheme.Color.secondaryBackground)
        }
    }
}
