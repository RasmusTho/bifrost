import Foundation

/// One block of the hub's derived understanding.
///
/// Every derived block carries its provisionality on its face: which revision
/// produced it, which segments it was derived from, and whether the ledger had
/// holes at that point. A derived block with no provisionality marking would be
/// indistinguishable from settled fact, which is the specific lie this surface
/// exists to avoid.
struct DerivedBlock: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case summary
        case theme
        case provisionalDecision = "provisional_decision"
        case openQuestion = "open_question"
        case actionCandidate = "action_candidate"
    }

    let id: String
    let kind: Kind
    let text: String
    /// Revision of the projection that produced this block.
    let revision: Int
    /// Session sequence numbers this block was derived from — its coverage.
    let derivedFromSeqs: [Int]

    /// Always true for a live projection: derived output remains provisional
    /// until the meeting is finalized. Kept explicit so the view cannot render
    /// a derived block without a provisionality decision having been made.
    var isProvisional: Bool { true }
}

struct TranscriptEntry: Equatable, Identifiable {
    let id: String
    let sessionSeq: Int
    let text: String
}

/// A hub projection read, as observed at a point in time.
struct MeetingProjection: Equatable {
    let revision: Int
    let transcript: [TranscriptEntry]
    let derivedBlocks: [DerivedBlock]
    /// Session sequence numbers the hub's ledger is missing. Rendered as
    /// explicit gap markers rather than silently closed over.
    let missingSequences: [Int]
    let observedAt: Date

    static let empty = MeetingProjection(
        revision: 0,
        transcript: [],
        derivedBlocks: [],
        missingSequences: [],
        observedAt: Date(timeIntervalSince1970: 0)
    )
}

/// The hub's answer to closing a session.
struct MeetingFinalization: Equatable {
    let sessionID: String
    let declaredFinalCount: Int
    /// Sequences the hub never received. Non-empty means the final view must
    /// surface needs-attention with these identities named.
    let missingSequences: [Int]
    let consolidatedTranscript: [TranscriptEntry]
    let finalDerivedBlocks: [DerivedBlock]
}

/// Acknowledgement of one user-note write.
struct UserNoteAck: Equatable {
    let noteBlockID: String
    /// The revision the hub acknowledged. An ack for an older revision must not
    /// mark a newer local edit as synced.
    let revision: Int
}

/// Hub seam for a live meeting. Behind a protocol because `KD-4384-RAWKEY`
/// means no live hub can currently answer, so the trust-bearing behaviour has
/// to be provable at the client seam.
protocol LiveMeetingTransport: Sendable {
    func openSession(templateID: String) async throws -> String
    func projection(sessionID: String) async throws -> MeetingProjection
    func sendUserNote(sessionID: String, block: UserNoteBlock) async throws -> UserNoteAck
    func closeSession(sessionID: String, finalSegmentCount: Int) async throws -> MeetingFinalization
}

/// Session identity and monotonic segment numbering.
///
/// `session_seq` is minted on device and must be monotonic across a relaunch,
/// so the next value is derived from what is already durably in the outbox
/// rather than from an in-memory counter. That is the same disk-is-authoritative
/// rule CDLM-03 applies to state: a counter that lived only in memory would
/// restart at zero after a crash and make two different segments claim one
/// position, which the hub would read as a duplicate rather than a gap.
@MainActor
final class LiveMeetingSessionModel: ObservableObject {
    @Published private(set) var sessionID: String?
    @Published private(set) var templateID: String = LiveMeetingSessionModel.defaultTemplateID
    /// v1 offers only the generic default; the list exists so the choice runs
    /// through the CDLM-06 precedence seam rather than being hardcoded at the
    /// call site. No participant fields, no invitee inference (INV-CDLM-8).
    static let defaultTemplateID = "generic-default"
    static let availableTemplateIDs = [defaultTemplateID]

    private let store: TransferOutboxStore
    private let deviceID: String

    init(store: TransferOutboxStore, deviceID: String) {
        self.store = store
        self.deviceID = deviceID
    }

    func start(sessionID: String, templateID: String = LiveMeetingSessionModel.defaultTemplateID) {
        self.sessionID = sessionID
        self.templateID = LiveMeetingSessionModel.availableTemplateIDs.contains(templateID)
            ? templateID
            : LiveMeetingSessionModel.defaultTemplateID
    }

    /// The next sequence for this session, derived from disk.
    func nextSequence(for sessionID: String) -> Int {
        let existing = (try? store.loadAll()) ?? []
        let highest = existing
            .filter { $0.envelope.sessionID == sessionID }
            .compactMap { $0.envelope.sessionSeq }
            .max()
        return (highest ?? -1) + 1
    }

    /// Finalizes one bounded segment into the outbox.
    ///
    /// Recording continues regardless of connectivity: this path never consults
    /// the hub, so a segment captured offline queues exactly like any other
    /// capture and is retained under CDLM-03's receipt-gated custody.
    @discardableResult
    func finalizeSegment(
        mediaURL: URL,
        capturedAt: Date = Date(),
        durationSeconds: Double? = nil
    ) throws -> TransferOutboxItem {
        guard let sessionID else { throw LiveMeetingError.noOpenSession }
        let seq = nextSequence(for: sessionID)
        return try store.enqueue(
            finalizedMediaURL: mediaURL,
            kind: .audio,
            typedMetadata: TypedCaptureMetadata(durationSeconds: durationSeconds),
            capturedAt: capturedAt,
            deviceID: deviceID,
            sessionRefs: ["session:\(sessionID)"],
            sessionID: sessionID,
            sessionSeq: seq
        )
    }

    /// Returns a segment to the waiting state so the ordinary coordinator pass
    /// picks it up again. Deliberately routes through the outbox rather than
    /// offering a bespoke upload path, so a reconnect resend is the same
    /// idempotent send as any other.
    func markSegmentPending(captureID: String) throws {
        try store.markPendingLocally(captureID: captureID, errorCode: nil)
    }

    /// Segments this session has durably queued, in sequence order.
    func segments(for sessionID: String) -> [TransferOutboxItem] {
        let existing = (try? store.loadAll()) ?? []
        return existing
            .filter { $0.envelope.sessionID == sessionID }
            .sorted { ($0.envelope.sessionSeq ?? 0) < ($1.envelope.sessionSeq ?? 0) }
    }
}

enum LiveMeetingError: LocalizedError, Equatable {
    case noOpenSession

    var errorDescription: String? {
        switch self {
        case .noOpenSession:
            "No meeting session is open."
        }
    }
}
