import Foundation

/// The five truthful states, plus the terminal-adjacent `needsAttention`.
///
/// `rank` exists for the monotonicity rule and is deliberately not a general
/// ordering: `needsAttention` has no rank because it is not a point on the
/// progress line, it is a demand for the user.
enum TransferQueueState: String, Equatable, CaseIterable {
    case pendingLocally = "pending locally"
    case transferring
    case backendDurablyReceived = "backend durably received"
    case processing
    case complete
    case needsAttention = "needs attention"

    /// Position on the progress line, or `nil` for `needsAttention`.
    var rank: Int? {
        switch self {
        case .pendingLocally: 0
        case .transferring: 1
        case .backendDurablyReceived: 2
        case .processing: 3
        case .complete: 4
        case .needsAttention: nil
        }
    }

    /// States at or beyond durable acceptance are backed by a persisted receipt
    /// and may never regress: the hub has acknowledged the capture, and telling
    /// the user otherwise later would unsay a promise that is still true.
    var isReceiptBacked: Bool {
        (rank ?? -1) >= TransferQueueState.backendDurablyReceived.rank ?? .max
    }
}

/// What the hub said about one capture. Absent means the hub has not answered,
/// which is different from the hub saying nothing is happening.
struct HubItemStatus: Equatable {
    enum Progress: String, Equatable {
        /// Admitted, no processing progress reported yet.
        case admitted
        case processing
        case complete
        case failed
    }

    let captureID: String
    let progress: Progress
    /// Named reason when `progress == .failed`.
    let failureReason: String?
    /// When this answer was obtained. Used to decide whether a refresh carries
    /// *new* evidence; an answer no newer than the one already rendered can
    /// never advance a state.
    let observedAt: Date

    init(captureID: String, progress: Progress, failureReason: String? = nil, observedAt: Date) {
        self.captureID = CaptureIdentity.canonical(captureID)
        self.progress = progress
        self.failureReason = failureReason
        self.observedAt = observedAt
    }
}

/// Why an item is demanding attention, and what may safely be done about it.
struct TransferQueueAttention: Equatable {
    enum Reason: Equatable {
        /// The hub refused admission with a named error the client must not
        /// blind-retry.
        case refusedAdmission(errorCode: String)
        /// The hub reported a processing failure.
        case processingFailed(reason: String)
        /// A receipt arrived whose transfer identity did not match this item.
        case receiptIdentityMismatch

        var displayReason: String {
            switch self {
            case let .refusedAdmission(errorCode):
                "The hub refused this capture: \(errorCode)."
            case let .processingFailed(reason):
                "The hub could not process this capture: \(reason)."
            case .receiptIdentityMismatch:
                "A receipt arrived for a different capture identity, so this item was not released."
            }
        }
    }

    /// Actions offered on a needs-attention item. Every one is safe by
    /// construction: retry routes through the idempotent resend path, reveal is
    /// read-only, and discard is offered *only* when the original still exists
    /// locally and always requires explicit confirmation.
    enum Action: Equatable {
        case retry
        case reveal
        case discardWithConfirmation

        var requiresExplicitConfirmation: Bool { self == .discardWithConfirmation }
    }

    let reason: Reason
    let actions: [Action]
}

/// One row of the queue surface.
struct TransferQueueItem: Equatable {
    let captureID: String
    let state: TransferQueueState
    let capturedAt: Date
    /// `true` when the rendered state came from a hub answer that is no longer
    /// known to be current — an unreachable hub, or evidence from before the
    /// last failed refresh. Local states are never stale: disk is authoritative.
    let isHubStateStale: Bool
    let attention: TransferQueueAttention?
    /// `true` while the capture's bytes are still on this device.
    let originalExistsLocally: Bool
    let cameFromWatchRelay: Bool
}

/// The pure derivation seam.
///
/// This is where "state derivation, not state invention" (INV-CDLM-4) is
/// enforceable, so it is a free function over evidence rather than something
/// tangled into a view: given an envelope, an optional hub answer, and whether
/// that answer is current, there is exactly one truthful row.
enum TransferQueueDerivation {
    /// Local error codes that mean *this needs a human*, as opposed to codes
    /// that simply mean "still waiting". Transport failures and the hub's
    /// `not_acknowledged` 500 family are retried automatically and must not
    /// nag the user.
    static let transientErrorCodes: Set<String> = [
        "hub_unreachable",
        "raw_write_failed",
        "admission_event_commit_failed",
        "receipt_persistence_failed",
        "raw_store_key_unavailable",
        "media_cap_misconfigured",
        "admission_failed",
        "receipt_body_unreadable",
        "envelope_rebuilt_after_interrupted_enqueue"
    ]

    static func item(
        for envelope: TransferOutboxEnvelope,
        hubStatus: HubItemStatus?,
        hubStatusIsStale: Bool,
        originalExistsLocally: Bool
    ) -> TransferQueueItem {
        let localState = localState(for: envelope)

        // A named local rejection is a demand for the user regardless of what
        // the hub last said about progress.
        if let attention = localAttention(for: envelope) {
            return TransferQueueItem(
                captureID: envelope.captureID,
                state: .needsAttention,
                capturedAt: envelope.capturedAt,
                isHubStateStale: false,
                attention: attention,
                originalExistsLocally: originalExistsLocally,
                cameFromWatchRelay: envelope.cameFromWatchRelay
            )
        }

        // Hub-derived states require the local receipt to be persisted first.
        // Rendering `processing` for an item whose receipt has not landed would
        // skip `backend durably received` — displaying progress the local
        // evidence cannot yet support. The coordinator persists that receipt on
        // its next pass, so this resolves itself without inventing anything.
        guard let hubStatus, envelope.receipt != nil else {
            return TransferQueueItem(
                captureID: envelope.captureID,
                state: localState,
                capturedAt: envelope.capturedAt,
                isHubStateStale: false,
                attention: nil,
                originalExistsLocally: originalExistsLocally,
                cameFromWatchRelay: envelope.cameFromWatchRelay
            )
        }

        return hubDerivedItem(
            envelope: envelope,
            localState: localState,
            hubStatus: hubStatus,
            hubStatusIsStale: hubStatusIsStale,
            originalExistsLocally: originalExistsLocally
        )
    }

    private static func hubDerivedItem(
        envelope: TransferOutboxEnvelope,
        localState: TransferQueueState,
        hubStatus: HubItemStatus,
        hubStatusIsStale: Bool,
        originalExistsLocally: Bool
    ) -> TransferQueueItem {
        switch hubStatus.progress {
        case .failed:
            return TransferQueueItem(
                captureID: envelope.captureID,
                state: .needsAttention,
                capturedAt: envelope.capturedAt,
                isHubStateStale: hubStatusIsStale,
                attention: TransferQueueAttention(
                    reason: .processingFailed(reason: hubStatus.failureReason ?? "unknown"),
                    actions: safeActions(originalExistsLocally: originalExistsLocally)
                ),
                originalExistsLocally: originalExistsLocally,
                cameFromWatchRelay: envelope.cameFromWatchRelay
            )
        case .admitted:
            // The hub confirms acceptance but reports no progress; the local
            // receipt-backed state is already the truthful answer.
            return TransferQueueItem(
                captureID: envelope.captureID,
                state: localState,
                capturedAt: envelope.capturedAt,
                isHubStateStale: false,
                attention: nil,
                originalExistsLocally: originalExistsLocally,
                cameFromWatchRelay: envelope.cameFromWatchRelay
            )
        case .processing, .complete:
            return TransferQueueItem(
                captureID: envelope.captureID,
                state: hubStatus.progress == .processing ? .processing : .complete,
                capturedAt: envelope.capturedAt,
                isHubStateStale: hubStatusIsStale,
                attention: nil,
                originalExistsLocally: originalExistsLocally,
                cameFromWatchRelay: envelope.cameFromWatchRelay
            )
        }
    }

    /// Local states come from disk alone.
    ///
    /// The `receipt == nil` guard is the one that matters: `backend durably
    /// received` is a claim about the hub's acknowledgement, so it is never
    /// rendered from a state field alone. If an envelope ever said received
    /// without carrying its receipt, the honest display is the state before it.
    static func localState(for envelope: TransferOutboxEnvelope) -> TransferQueueState {
        switch envelope.state {
        case .pendingLocally:
            return .pendingLocally
        case .transferring:
            return .transferring
        case .backendDurablyReceived:
            return envelope.receipt == nil ? .transferring : .backendDurablyReceived
        }
    }

    private static func localAttention(for envelope: TransferOutboxEnvelope) -> TransferQueueAttention? {
        guard envelope.receipt == nil, let code = envelope.lastErrorCode else { return nil }
        if code == "receipt_identity_mismatch" {
            return TransferQueueAttention(
                reason: .receiptIdentityMismatch,
                actions: safeActions(originalExistsLocally: !envelope.originalReleased)
            )
        }
        guard !transientErrorCodes.contains(code) else { return nil }
        return TransferQueueAttention(
            reason: .refusedAdmission(errorCode: code),
            actions: safeActions(originalExistsLocally: !envelope.originalReleased)
        )
    }

    /// Discard is offered only when there is still a local original to discard.
    /// Offering it otherwise would present an action that either does nothing or
    /// implies the user can dispose of something already gone.
    static func safeActions(originalExistsLocally: Bool) -> [TransferQueueAttention.Action] {
        originalExistsLocally ? [.retry, .reveal, .discardWithConfirmation] : [.retry, .reveal]
    }

    /// The monotonicity rule applied on refresh.
    ///
    /// - A receipt-backed state never regresses: once the hub has durably
    ///   accepted a capture, no later render may unsay it.
    /// - Below durable acceptance, regression *to truth* is allowed and correct
    ///   — CDLM-03 states plainly that `transferring` may fall back to `pending
    ///   locally` after a crash, and hiding that would be the lie.
    /// - Advancement requires new evidence: a refresh carrying no newer hub
    ///   answer cannot move an item forward.
    static func merge(previous: TransferQueueItem?, refreshed: TransferQueueItem) -> TransferQueueItem {
        guard let previous else { return refreshed }
        guard previous.captureID == refreshed.captureID else { return refreshed }

        // Needs-attention is a demand, not a rank; let it through in either
        // direction so a newly failed item surfaces and a resolved one clears.
        if previous.state == .needsAttention || refreshed.state == .needsAttention { return refreshed }

        guard let previousRank = previous.state.rank, let refreshedRank = refreshed.state.rank else {
            return refreshed
        }
        if refreshedRank < previousRank && previous.state.isReceiptBacked {
            // Keep the earlier, stronger claim, but carry the fresh staleness
            // marking so the user still learns the hub is not answering.
            return TransferQueueItem(
                captureID: previous.captureID,
                state: previous.state,
                capturedAt: previous.capturedAt,
                isHubStateStale: refreshed.isHubStateStale || previous.isHubStateStale,
                attention: previous.attention,
                originalExistsLocally: refreshed.originalExistsLocally,
                cameFromWatchRelay: previous.cameFromWatchRelay
            )
        }
        return refreshed
    }
}
