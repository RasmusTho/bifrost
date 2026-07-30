import SwiftUI

/// The durable transfer queue surface.
///
/// Renders only what `TransferQueueViewModel` derived from evidence. The view
/// makes no state decisions of its own — it has no fallback text that could
/// imply progress, and every hub-derived row that is not known to be current
/// carries a visible staleness marker.
struct TransferQueueView: View {
    @ObservedObject var model: TransferQueueViewModel

    var body: some View {
        List {
            Section("Transfer Queue") {
                if model.items.isEmpty {
                    Text("No captures in the queue.")
                        .foregroundStyle(YggTheme.Color.textSecondary)
                        .accessibilityIdentifier("transferQueue.empty")
                }
                ForEach(model.items, id: \.captureID) { item in
                    row(for: item)
                }
            }

            if !model.hubAnswered {
                Text("The hub is not answering. Local states are current; hub states are last known.")
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(YggTheme.Color.textSecondary)
                    .accessibilityIdentifier("transferQueue.hubUnreachable")
            }

            Button("Refresh Queue") {
                Task { await model.runPendingTransfersAndRefresh() }
            }
            .accessibilityIdentifier("transferQueue.refresh")
        }
        .accessibilityIdentifier("transferQueue")
        .confirmationDialog(
            "Discard this capture?",
            isPresented: Binding(
                get: { model.pendingDiscardCaptureID != nil },
                set: { if !$0 { model.cancelDiscard() } }
            ),
            titleVisibility: .visible
        ) {
            // Discard is destructive and never one-tap: it exists only behind
            // this explicit confirmation, and only for items whose original is
            // still on the device.
            Button("Discard Original", role: .destructive) { model.confirmDiscard() }
                .accessibilityIdentifier("transferQueue.discard.confirm")
            Button("Keep", role: .cancel) { model.cancelDiscard() }
        } message: {
            Text("The original is still on this device. Discarding deletes it permanently.")
        }
    }

    @ViewBuilder
    private func row(for item: TransferQueueItem) -> some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
            HStack {
                Text(item.state.rawValue)
                    .accessibilityIdentifier("transferQueue.state.\(item.captureID)")
                if item.isHubStateStale {
                    Text("(last known)")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                        .accessibilityIdentifier("transferQueue.stale.\(item.captureID)")
                }
                Spacer()
                if item.cameFromWatchRelay {
                    Image(systemName: "applewatch")
                        .accessibilityLabel("Relayed from Watch")
                }
            }

            if let attention = item.attention {
                Text(attention.reason.displayReason)
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("transferQueue.reason.\(item.captureID)")
                HStack {
                    ForEach(attention.actions, id: \.self) { action in
                        actionButton(action, for: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: TransferQueueAttention.Action, for item: TransferQueueItem) -> some View {
        switch action {
        case .retry:
            Button("Retry") { Task { await model.retry(captureID: item.captureID) } }
                .accessibilityIdentifier("transferQueue.retry.\(item.captureID)")
        case .reveal:
            Button("Reveal") {}
                .accessibilityIdentifier("transferQueue.reveal.\(item.captureID)")
        case .discardWithConfirmation:
            Button("Discard", role: .destructive) { model.requestDiscard(captureID: item.captureID) }
                .accessibilityIdentifier("transferQueue.discard.\(item.captureID)")
        }
    }
}

extension TransferQueueAttention.Action: Hashable {}
