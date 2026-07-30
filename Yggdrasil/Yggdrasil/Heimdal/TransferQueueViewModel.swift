import Foundation

/// Source of hub-side progress for queue items.
///
/// Separate from `HeimdalMediaTransporting` because this is a read-only status
/// projection: nothing here may admit, resend, or release anything.
protocol TransferQueueStatusSource: Sendable {
    /// Answers for as many of the requested captures as the hub knows about.
    /// Throwing means the hub did not answer at all, which is different from
    /// answering that it knows nothing.
    func statuses(forCaptureIDs captureIDs: [String]) async throws -> [String: HubItemStatus]
}

/// The production render path for the durable transfer queue.
///
/// The surface owns no durable state. It renders CDLM-03's outbox from disk plus
/// hub answers, and every rule that could make it lie lives here rather than in
/// the view:
///
/// - **Cold launch** renders from disk first, then performs exactly one status
///   query. If that query fails, local states still render truthfully and
///   hub-derived states are marked stale rather than omitted or invented.
/// - **Refresh is monotone over evidence** (`TransferQueueDerivation.merge`): a
///   receipt-backed state never regresses, and nothing advances without a newer
///   hub answer.
/// - **Hub answers are remembered in memory only.** After relaunch there is no
///   unfetched hub progress to restore, so `processing`/`complete` legitimately
///   do not appear until the first refresh answers — honest staleness rather
///   than invented progress.
@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published private(set) var items: [TransferQueueItem] = []
    /// `false` once a status query has failed and not yet succeeded again.
    @Published private(set) var hubAnswered = true
    /// Set when the user asks to discard an item; the view must confirm before
    /// `confirmDiscard` may run. Discard is never a one-tap action.
    @Published var pendingDiscardCaptureID: String?

    private let store: TransferOutboxStore
    private let statusSource: TransferQueueStatusSource
    private let coordinator: TransferOutboxCoordinator?
    private var lastKnownHubStatus: [String: HubItemStatus] = [:]
    private var hubStatusIsStale = false
    private let fileManager: FileManager

    init(
        store: TransferOutboxStore,
        statusSource: TransferQueueStatusSource,
        coordinator: TransferOutboxCoordinator? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.statusSource = statusSource
        self.coordinator = coordinator
        self.fileManager = fileManager
    }

    /// Cold launch: disk, then exactly one status query.
    func loadOnColdLaunch() async {
        renderFromDisk()
        await refresh()
    }

    /// Renders local evidence alone. Always safe: disk is authoritative for the
    /// first three states and never stale.
    func renderFromDisk() {
        let envelopes = (try? store.loadAll()) ?? []
        items = envelopes.map { outboxItem in
            let derived = TransferQueueDerivation.item(
                for: outboxItem.envelope,
                hubStatus: lastKnownHubStatus[outboxItem.captureID],
                hubStatusIsStale: hubStatusIsStale,
                originalExistsLocally: fileManager.fileExists(atPath: outboxItem.mediaURL.path)
            )
            return TransferQueueDerivation.merge(previous: previousItem(for: outboxItem.captureID), refreshed: derived)
        }
    }

    /// Refreshes hub-derived states. A failed query marks existing hub-derived
    /// state stale; it never clears it and never advances anything.
    func refresh() async {
        let outboxItems = (try? store.loadAll()) ?? []
        let captureIDs = outboxItems.map(\.captureID)
        guard !captureIDs.isEmpty else {
            items = []
            return
        }

        do {
            let answers = try await statusSource.statuses(forCaptureIDs: captureIDs)
            // Only newer evidence may replace what is already rendered.
            for (captureID, status) in answers {
                let identity = CaptureIdentity.canonical(captureID)
                if let existing = lastKnownHubStatus[identity], status.observedAt <= existing.observedAt {
                    continue
                }
                lastKnownHubStatus[identity] = status
            }
            hubStatusIsStale = false
            hubAnswered = true
        } catch {
            // The hub said nothing. Keep the last known answers and mark them
            // stale so the surface stays honest instead of looking current.
            hubStatusIsStale = true
            hubAnswered = false
        }

        items = outboxItems.map { outboxItem in
            let derived = TransferQueueDerivation.item(
                for: outboxItem.envelope,
                hubStatus: lastKnownHubStatus[outboxItem.captureID],
                hubStatusIsStale: hubStatusIsStale,
                originalExistsLocally: fileManager.fileExists(atPath: outboxItem.mediaURL.path)
            )
            return TransferQueueDerivation.merge(previous: previousItem(for: outboxItem.captureID), refreshed: derived)
        }
    }

    // MARK: - Safe actions

    /// Retry routes through the ordinary coordinator pass, which is idempotent
    /// by the hub's transfer-identity contract. There is no bespoke retry that
    /// could resend under a fresh identity.
    func retry(captureID: String) async {
        try? store.markPendingLocally(captureID: captureID, errorCode: nil)
        await coordinator?.runPass()
        await refresh()
    }

    func requestDiscard(captureID: String) {
        // Only an item whose original is still here can be discarded, and even
        // then only after explicit confirmation.
        guard items.first(where: { $0.captureID == captureID })?.originalExistsLocally == true else { return }
        pendingDiscardCaptureID = captureID
    }

    func cancelDiscard() {
        pendingDiscardCaptureID = nil
    }

    /// Completes a discard the user has explicitly confirmed.
    ///
    /// This is the *only* deletion of outbox media that is not receipt-gated,
    /// and it exists because CDLM-05 requires it: a human may decide to throw
    /// away their own capture. It is deliberately unreachable from the transfer
    /// machinery — `TransferOutboxCoordinator` never calls it — so CDLM-03's
    /// guarantee is unchanged in substance: *the transfer machinery* still
    /// cannot delete an un-receipted original.
    @discardableResult
    func confirmDiscard() -> Bool {
        guard let captureID = pendingDiscardCaptureID else { return false }
        defer { pendingDiscardCaptureID = nil }
        guard (try? store.discardByExplicitUserAction(captureID: captureID)) != nil else { return false }
        renderFromDisk()
        return true
    }

    private func previousItem(for captureID: String) -> TransferQueueItem? {
        items.first { $0.captureID == captureID }
    }
}
