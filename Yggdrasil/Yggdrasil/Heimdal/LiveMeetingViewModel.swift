import Foundation

/// The final view's three artifacts, kept as three separate collections.
///
/// Structural separation rather than presentational: user notes are never
/// interleaved into derived output, so no rendering mistake can merge them.
struct MeetingFinalView: Equatable {
    let consolidatedTranscript: [TranscriptEntry]
    let finalDerivedBlocks: [DerivedBlock]
    /// The user's notes, verbatim.
    let userNotes: [UserNoteBlock]
    /// Missing segment identities, named. Empty means nothing needs attention.
    let needsAttentionSequences: [Int]

    var needsAttention: Bool { !needsAttentionSequences.isEmpty }
}

/// The live meeting surface.
///
/// ## Why the regions are separate properties
///
/// CDLM-07 enforces user-note ownership on the hub: derived writers cannot touch
/// `user_note` blocks. If this client merged the two regions into one rendered
/// collection, that server-side guarantee would become a UI lie — the user would
/// see their words and the machine's words in one undifferentiated stream and
/// have no way to tell which was which. So the AI region and the user region are
/// two separately-typed properties that are never combined, and the tests assert
/// no derived content can reach the user region.
///
/// ## Reconnect
///
/// Reconciliation renders as a *new revision*, never as silent content
/// replacement, and never at the cost of editor state or note text. A projection
/// refresh that arrived while the user was mid-sentence must not move their
/// cursor or discard what they typed.
@MainActor
final class LiveMeetingViewModel: ObservableObject {
    // MARK: - AI region ("AI uppdaterar löpande")

    @Published private(set) var projection: MeetingProjection = .empty
    /// `true` when the last projection read failed, so the AI region shows
    /// last-known content marked stale rather than looking current.
    @Published private(set) var projectionIsStale = false

    // MARK: - User region ("Dina anteckningar")

    @Published private(set) var userNotes: [UserNoteBlock] = []
    /// Live editor text. Never touched by a projection refresh.
    @Published var editorText: String = ""

    // MARK: - Session

    @Published private(set) var finalView: MeetingFinalView?
    @Published private(set) var lastReconnectResentSequences: [Int] = []

    private let session: LiveMeetingSessionModel
    private let noteStore: UserNoteStore
    private let transport: LiveMeetingTransport
    private let coordinator: TransferOutboxCoordinator?

    init(
        session: LiveMeetingSessionModel,
        noteStore: UserNoteStore,
        transport: LiveMeetingTransport,
        coordinator: TransferOutboxCoordinator? = nil
    ) {
        self.session = session
        self.noteStore = noteStore
        self.transport = transport
        self.coordinator = coordinator
        userNotes = noteStore.load()
    }

    // MARK: - AI region

    /// Refreshes the projection. A newer revision replaces the rendered one; an
    /// older or equal revision is ignored, so a late or duplicated read cannot
    /// walk the AI region backwards.
    func refreshProjection() async {
        guard let sessionID = session.sessionID else { return }
        do {
            let fresh = try await transport.projection(sessionID: sessionID)
            if fresh.revision >= projection.revision {
                projection = fresh
            }
            projectionIsStale = false
        } catch {
            // The hub said nothing. Keep what is rendered and mark it stale.
            projectionIsStale = true
        }
    }

    // MARK: - User region

    /// Writes the editor's contents as a new note block.
    ///
    /// The note is durable before any send is attempted, so a failed send costs
    /// the user nothing. Sending is best-effort; an unacknowledged note simply
    /// stays unsynced and is resent later.
    func commitEditorText(at date: Date = Date()) async {
        let text = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let block = try? noteStore.append(text: text, at: date) else { return }
        editorText = ""
        userNotes = noteStore.load()
        await send(block: block)
    }

    func editNote(noteBlockID: String, text: String, at date: Date = Date()) async {
        guard let updated = try? noteStore.edit(noteBlockID: noteBlockID, text: text, at: date) else { return }
        userNotes = noteStore.load()
        await send(block: updated)
    }

    /// Resends every note whose current revision is unacknowledged. Idempotent
    /// by `(note_block_id, revision)`, so a resend after a lost response updates
    /// rather than duplicating.
    func resendUnsyncedNotes() async {
        for block in noteStore.unsynced() {
            await send(block: block)
        }
        userNotes = noteStore.load()
    }

    private func send(block: UserNoteBlock) async {
        guard let sessionID = session.sessionID else { return }
        guard let ack = try? await transport.sendUserNote(sessionID: sessionID, block: block) else { return }
        try? noteStore.recordAck(ack)
        userNotes = noteStore.load()
    }

    // MARK: - Reconnect

    /// Regained connectivity.
    ///
    /// Resends exactly the segments the hub's ledger is missing — not everything,
    /// which would re-upload bytes the hub already holds — then refreshes the
    /// projection and resends unsynced notes. Editor state and note content are
    /// untouched throughout.
    func reconnect() async {
        guard let sessionID = session.sessionID else { return }

        let missing = Set(projection.missingSequences)
        let resendable = session.segments(for: sessionID).filter { item in
            guard let seq = item.envelope.sessionSeq else { return false }
            return missing.contains(seq)
        }
        lastReconnectResentSequences = resendable.compactMap { $0.envelope.sessionSeq }.sorted()

        // Returning a missing segment to the waiting state is what makes the
        // coordinator pick it up again; the coordinator itself owns the
        // idempotent resend, so there is no bespoke upload path here.
        for item in resendable {
            try? await markResendable(item)
        }
        await coordinator?.runPass()

        await refreshProjection()
        await resendUnsyncedNotes()
    }

    private func markResendable(_ item: TransferOutboxItem) async throws {
        guard item.envelope.receipt == nil else { return }
        try session.markSegmentPending(captureID: item.captureID)
    }

    // MARK: - End meeting

    /// Closes the session with the declared final count and builds the final view.
    ///
    /// The three artifacts stay three collections. `needs attention` names the
    /// affected sequence identities rather than reporting a bare count, because
    /// "two segments missing" is not actionable and "segments 3 and 4 missing" is.
    func endMeeting() async {
        guard let sessionID = session.sessionID else { return }
        let declaredCount = session.segments(for: sessionID).count
        guard let finalization = try? await transport.closeSession(
            sessionID: sessionID,
            finalSegmentCount: declaredCount
        ) else { return }

        finalView = MeetingFinalView(
            consolidatedTranscript: finalization.consolidatedTranscript,
            finalDerivedBlocks: finalization.finalDerivedBlocks,
            userNotes: noteStore.load(),
            needsAttentionSequences: finalization.missingSequences.sorted()
        )
    }
}
