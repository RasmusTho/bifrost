import Foundation

/// Drives the outbox: sends what is waiting, resolves what is ambiguous, and
/// releases only what the hub has durably accepted.
///
/// ## The ordering that matters
///
/// For every item the sequence is strictly: persist `transferring` → send →
/// persist receipt → *then* consider release. The receipt write is never
/// deferred until after a deletion, and a deletion is never attempted on the
/// strength of an in-memory success flag. `releaseOriginal` re-reads the
/// envelope from disk and refuses without a persisted receipt, so even a caller
/// that ignored this ordering could not delete an un-receipted original.
///
/// ## The post-2xx-pre-persist window
///
/// If the process dies between the hub's 2xx and `persistReceipt`, disk still
/// says `transferring`. On the next run that item is resolved by *querying
/// receipts first*, never by resending blindly and never by assuming the send
/// worked. Three answers, three different behaviours:
///
/// - `admitted` → persist the receipt, then release becomes possible.
/// - `unknown` → the hub genuinely has nothing; resend. Safe and duplicate-free
///   because the transfer identity was minted before the first send.
/// - `storeUnavailable` (503) → *no information*. The item is left exactly as it
///   is: no release, no resend. Treating a read failure as `unknown` is the one
///   mistake that could delete an original the hub never accepted.
///
/// ## Offline
///
/// A transport that throws means the hub said nothing at all. The item returns to
/// `pendingLocally` with its original intact and waits indefinitely and visibly.
/// The outbox has no watched-folder fallback — that lane is the legacy Model-1
/// writer, which is not receipt-gated and is not reachable from here.
actor TransferOutboxCoordinator {
    private let store: TransferOutboxStore
    private let transport: HeimdalMediaTransporting
    /// When false, an original is retained even after its receipt is persisted.
    /// Release is always *permitted* only by a receipt; this switch lets a build
    /// keep originals for longer without ever loosening that gate.
    private let releasesOriginalsAfterReceipt: Bool

    init(
        store: TransferOutboxStore,
        transport: HeimdalMediaTransporting,
        releasesOriginalsAfterReceipt: Bool = true
    ) {
        self.store = store
        self.transport = transport
        self.releasesOriginalsAfterReceipt = releasesOriginalsAfterReceipt
    }

    /// Result of one pass, for tests and for the queue surface a later slice adds.
    struct PassSummary: Equatable {
        var admitted: [String] = []
        var resolvedFromReceiptQuery: [String] = []
        var resent: [String] = []
        var stillPending: [String] = []
        var released: [String] = []
        /// Items left untouched because the hub could not answer. Never released,
        /// never resent.
        var unresolvable: [String] = []
    }

    /// Processes every item currently on disk. The work list is rebuilt from disk
    /// on each pass, so a pass is safe to run after any crash.
    @discardableResult
    func runPass(now: Date = Date()) async -> PassSummary {
        var summary = PassSummary()
        let items = (try? store.loadAll()) ?? []
        for item in items {
            await process(item: item, now: now, into: &summary)
        }
        return summary
    }

    private func process(item: TransferOutboxItem, now: Date, into summary: inout PassSummary) async {
        switch item.envelope.state {
        case .backendDurablyReceived:
            // Already accepted. The only remaining work is release, which is
            // idempotent and gated inside the store.
            releaseIfPermitted(captureID: item.captureID, into: &summary)

        case .transferring:
            // Ambiguous: a send was attempted and its outcome is not on disk.
            // Resolve against the hub before considering a resend.
            await resolveAmbiguous(item: item, now: now, into: &summary)

        case .pendingLocally:
            await send(item: item, now: now, isResend: false, into: &summary)
        }
    }

    /// Recovery for an ambiguous send. Queries receipts *first* and resends only
    /// true unknowns.
    private func resolveAmbiguous(item: TransferOutboxItem, now: Date, into summary: inout PassSummary) async {
        let outcome: ReceiptQueryOutcome
        do {
            outcome = try await transport.receipt(forCaptureID: item.captureID)
        } catch {
            // The hub said nothing. Return to the waiting state; the original is
            // untouched and the next pass will ask again.
            try? store.markPendingLocally(captureID: item.captureID, errorCode: "hub_unreachable", at: now)
            summary.stillPending.append(item.captureID)
            return
        }

        switch outcome {
        case let .admitted(receipt):
            guard persistReceipt(receipt, for: item, into: &summary) else { return }
            summary.resolvedFromReceiptQuery.append(item.captureID)
            releaseIfPermitted(captureID: item.captureID, into: &summary)

        case .unknown:
            // The hub genuinely has no receipt, so the bytes never landed
            // durably. Resending reuses the already-minted identity.
            await send(item: item, now: now, isResend: true, into: &summary)

        case .storeUnavailable:
            // 503 is not `unknown`. Change nothing.
            summary.unresolvable.append(item.captureID)
        }
    }

    private func send(item: TransferOutboxItem, now: Date, isResend: Bool, into summary: inout PassSummary) async {
        // Persist the attempt before making it, so a crash mid-send leaves the
        // ambiguity visible on disk instead of looking like an untried item.
        try? store.markTransferring(captureID: item.captureID, at: now)

        let outcome: MediaAdmissionOutcome
        do {
            let attempted = (try? store.item(for: item.captureID)) ?? item
            outcome = try await transport.admit(item: attempted)
        } catch {
            try? store.markPendingLocally(captureID: item.captureID, errorCode: "hub_unreachable", at: now)
            summary.stillPending.append(item.captureID)
            return
        }

        switch outcome {
        case let .accepted(receipt):
            guard persistReceipt(receipt, for: item, into: &summary) else { return }
            if isResend {
                summary.resent.append(item.captureID)
            }
            summary.admitted.append(item.captureID)
            releaseIfPermitted(captureID: item.captureID, into: &summary)

        case let .notAcknowledged(errorCode):
            // Nothing was acknowledged and no receipt exists. Safe to retry later.
            try? store.markPendingLocally(captureID: item.captureID, errorCode: errorCode, at: now)
            summary.stillPending.append(item.captureID)

        case let .rejected(errorCode):
            // A named rejection the client must not blind-retry. The original is
            // still retained; the reason is recorded so the item can explain itself.
            try? store.markPendingLocally(captureID: item.captureID, errorCode: errorCode, at: now)
            summary.stillPending.append(item.captureID)
        }
    }

    /// Persists a receipt, refusing one that belongs to a different transfer
    /// identity. A mismatched receipt is treated as no receipt: the item stays
    /// un-released rather than being released against someone else's evidence.
    private func persistReceipt(
        _ receipt: DurableAcceptanceReceipt,
        for item: TransferOutboxItem,
        into summary: inout PassSummary
    ) -> Bool {
        guard receipt.captureID == item.envelope.captureID,
              receipt.contentSHA256 == item.envelope.contentSHA256 else {
            try? store.markPendingLocally(
                captureID: item.captureID,
                errorCode: "receipt_identity_mismatch",
                at: Date()
            )
            summary.unresolvable.append(item.captureID)
            return false
        }
        do {
            try store.persistReceipt(receipt, for: item.captureID)
            return true
        } catch {
            // The receipt could not be made durable, so acceptance is not
            // locally provable and the original must stay.
            summary.unresolvable.append(item.captureID)
            return false
        }
    }

    private func releaseIfPermitted(captureID: String, into summary: inout PassSummary) {
        guard releasesOriginalsAfterReceipt else { return }
        do {
            try store.releaseOriginal(captureID: captureID)
            summary.released.append(captureID)
        } catch {
            // The store refused. That is the gate working, not an error to route
            // around; the original stays and the item remains accounted for.
            summary.unresolvable.append(captureID)
        }
    }
}
