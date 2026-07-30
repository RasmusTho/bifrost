import Foundation
import XCTest
@testable import Yggdrasil

/// CDLM-09 tests.
///
/// The trust-bearing properties here are region separation, reconnect
/// truthfulness, and retain-until-ack notes. All three are asserted against the
/// production `LiveMeetingViewModel`, `LiveMeetingSessionModel`, and
/// `UserNoteStore` over real on-disk state — a stub of any of them would assume
/// away exactly what is being proven.
@MainActor
final class LiveMeetingSessionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveMeetingSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - AC 1

    /// Meeting segments mint monotonic `session_seq`, finalize as admissible
    /// files, enter the outbox with session sidecar fields, and recording
    /// continues offline.
    func testSegmentsMintMonotonicallyIntoOutbox() throws {
        let store = makeStore()
        let session = LiveMeetingSessionModel(store: store, deviceID: "device-under-test")
        session.start(sessionID: "session-a")

        for index in 0..<3 {
            try session.finalizeSegment(mediaURL: try segmentFile("seg-\(index).m4a"), durationSeconds: 30)
        }

        let segments = session.segments(for: "session-a")
        XCTAssertEqual(segments.compactMap { $0.envelope.sessionSeq }, [0, 1, 2], "Sequences must be monotonic.")
        for segment in segments {
            XCTAssertEqual(segment.envelope.sessionID, "session-a", "Each segment carries its session identity.")
            XCTAssertEqual(segment.envelope.state, .pendingLocally)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: segment.mediaURL.path),
                "A segment is a real, admissible file under outbox custody."
            )
            XCTAssertEqual(segment.envelope.contentSHA256, try TransferOutboxStore.sha256Hex(of: segment.mediaURL))
        }

        // Monotonicity must survive a relaunch: an in-memory counter would
        // restart at zero and make two segments claim one position, which the
        // hub would read as a duplicate rather than a gap.
        let relaunched = LiveMeetingSessionModel(store: makeStore(), deviceID: "device-under-test")
        relaunched.start(sessionID: "session-a")
        XCTAssertEqual(relaunched.nextSequence(for: "session-a"), 3, "Sequence must resume from disk, not from zero.")
        try relaunched.finalizeSegment(mediaURL: try segmentFile("seg-3.m4a"))
        XCTAssertEqual(relaunched.segments(for: "session-a").compactMap { $0.envelope.sessionSeq }, [0, 1, 2, 3])

        // A second session numbers independently.
        relaunched.start(sessionID: "session-b")
        XCTAssertEqual(relaunched.nextSequence(for: "session-b"), 0)

        // Recording offline is unaffected: finalization never consults the hub.
        XCTAssertNoThrow(try relaunched.finalizeSegment(mediaURL: try segmentFile("offline.m4a")))
    }

    // MARK: - AC 2

    /// The two regions are structurally separate, with provisionality markers on
    /// every derived block.
    func testRegionSeparationAndProvisionalityMarkers() async throws {
        let model = try makeModel(
            transport: StubTransport(projection: projectionFixture(revision: 4, missing: [2]))
        )
        model.editorText = "my own note"
        await model.commitEditorText()
        await model.refreshProjection()

        // The user region contains only the user's blocks.
        XCTAssertEqual(model.userNotes.map(\.text), ["my own note"])
        let derivedTexts = Set(model.projection.derivedBlocks.map(\.text))
        for note in model.userNotes {
            XCTAssertFalse(
                derivedTexts.contains(note.text),
                "A user note must never appear as derived content."
            )
        }

        // The AI region contains no user-authored block. The types make this
        // structural — there is no shared collection either could land in.
        let userTexts = Set(model.userNotes.map(\.text))
        for block in model.projection.derivedBlocks {
            XCTAssertFalse(userTexts.contains(block.text), "Derived output must never absorb the user's words.")
        }
        for entry in model.projection.transcript {
            XCTAssertFalse(userTexts.contains(entry.text), "The transcript must never absorb the user's words.")
        }

        // Every derived block carries provisionality: revision, coverage, and
        // the explicit provisional flag.
        XCTAssertFalse(model.projection.derivedBlocks.isEmpty)
        for block in model.projection.derivedBlocks {
            XCTAssertTrue(block.isProvisional, "A live derived block is provisional by construction.")
            XCTAssertEqual(block.revision, 4, "Each block names the revision that produced it.")
            XCTAssertFalse(block.derivedFromSeqs.isEmpty, "Each block names its coverage.")
        }

        // Ledger holes are explicit, not silently closed over.
        XCTAssertEqual(model.projection.missingSequences, [2], "A gap must be reported, not smoothed away.")

        // A projection refresh must not disturb the user's in-progress text.
        model.editorText = "half-typed thought"
        await model.refreshProjection()
        XCTAssertEqual(model.editorText, "half-typed thought", "A refresh must never displace the user's cursor.")
    }

    // MARK: - AC 3

    /// User notes persist locally at write time, send with stable
    /// `(note_block_id, revision)`, survive relaunch unsent, and resend idempotently.
    func testUserNotesRetainedUntilAckAndResendSafely() async throws {
        // The hub is unreachable, so nothing can be acknowledged.
        let offline = StubTransport(projection: .empty, failsNoteSend: true)
        let model = try makeModel(transport: offline)

        model.editorText = "first note"
        await model.commitEditorText()

        let stored = try XCTUnwrap(model.userNotes.first)
        XCTAssertEqual(stored.revision, 1)
        XCTAssertFalse(stored.isSynced, "An unacknowledged note must not claim to be synced.")

        // Survives relaunch, still unsent.
        let reloaded = UserNoteStore(directoryURL: notesRoot).load()
        XCTAssertEqual(reloaded.map(\.text), ["first note"])
        XCTAssertEqual(reloaded.first?.noteBlockID, stored.noteBlockID, "Identity is durable across relaunch.")
        XCTAssertFalse(try XCTUnwrap(reloaded.first).isSynced)

        // The hub comes back. Resend uses the same identity and revision, which
        // is what makes it idempotent rather than duplicative.
        let online = StubTransport(projection: .empty)
        let resumed = try makeModel(transport: online)
        await resumed.resendUnsyncedNotes()

        XCTAssertEqual(online.sentBlocks.count, 1)
        XCTAssertEqual(online.sentBlocks.first?.noteBlockID, stored.noteBlockID, "A resend must reuse the identity.")
        XCTAssertEqual(online.sentBlocks.first?.revision, 1)
        XCTAssertTrue(try XCTUnwrap(resumed.userNotes.first).isSynced)
        XCTAssertEqual(resumed.userNotes.count, 1, "A resend must never duplicate the block.")

        // Editing bumps the revision and makes it unsynced again; an ack for the
        // older revision must not mark the newer text synced.
        await resumed.editNote(noteBlockID: stored.noteBlockID, text: "first note, revised")
        XCTAssertEqual(resumed.userNotes.first?.revision, 2)

        let store = UserNoteStore(directoryURL: notesRoot)
        try store.recordAck(UserNoteAck(noteBlockID: stored.noteBlockID, revision: 1))
        let afterStaleAck = try XCTUnwrap(store.load().first)
        XCTAssertEqual(afterStaleAck.revision, 2)
        XCTAssertEqual(
            afterStaleAck.ackedRevision, 2,
            "The revision-2 ack from the edit send stands; a stale revision-1 ack must not lower it."
        )
    }

    // MARK: - AC 4

    /// Reconnect resends exactly the ledger-missing segments and renders
    /// reconciliation as a new revision without discarding editor state or notes.
    func testReconnectResendsMissingAndRendersNewRevision() async throws {
        let store = makeStore()
        let session = LiveMeetingSessionModel(store: store, deviceID: "device-under-test")
        session.start(sessionID: "session-r")
        for index in 0..<4 {
            try session.finalizeSegment(mediaURL: try segmentFile("r-\(index).m4a"))
        }
        // Segments 0, 1 and 3 are already durably accepted; only 2 is missing.
        for seq in [0, 1, 3] {
            let item = try XCTUnwrap(session.segments(for: "session-r").first { $0.envelope.sessionSeq == seq })
            try store.persistReceipt(
                DurableAcceptanceReceipt(
                    receiptID: "receipt-\(seq)",
                    captureID: item.captureID,
                    contentSHA256: item.envelope.contentSHA256,
                    admittedAt: Date()
                ),
                for: item.captureID
            )
        }

        let transport = StubTransport(projection: projectionFixture(revision: 7, missing: [2]))
        let model = LiveMeetingViewModel(
            session: session,
            noteStore: UserNoteStore(directoryURL: notesRoot),
            transport: transport
        )
        await model.refreshProjection()
        XCTAssertEqual(model.projection.revision, 7)

        model.editorText = "mid-sentence when the network dropped"
        await model.commitEditorText()
        let noteBefore = try XCTUnwrap(model.userNotes.first).text
        model.editorText = "still typing"

        // Reconnect: the hub now reports a higher revision with no gaps.
        transport.projection = projectionFixture(revision: 8, missing: [])
        await model.reconnect()

        XCTAssertEqual(
            model.lastReconnectResentSequences, [2],
            "Reconnect must resend exactly the ledger-missing segment, not everything."
        )
        XCTAssertEqual(model.projection.revision, 8, "Reconciliation renders as a new revision.")
        XCTAssertTrue(model.projection.missingSequences.isEmpty)
        XCTAssertEqual(model.userNotes.first?.text, noteBefore, "Reconnect must not rewrite note content.")
        XCTAssertEqual(model.editorText, "still typing", "Reconnect must not discard in-progress editor state.")

        // An older revision arriving late must not walk the AI region backwards.
        transport.projection = projectionFixture(revision: 6, missing: [2])
        await model.refreshProjection()
        XCTAssertEqual(model.projection.revision, 8, "A stale projection read must never regress the rendered one.")
    }

    // MARK: - AC 5

    /// The final view renders three distinct artifacts with user notes verbatim
    /// and separate, surfacing needs-attention prominently.
    func testFinalViewSeparatesArtifactsAndSurfacesGaps() async throws {
        let transport = StubTransport(projection: projectionFixture(revision: 3, missing: [1]))
        transport.finalization = MeetingFinalization(
            sessionID: "session-f",
            declaredFinalCount: 3,
            missingSequences: [1],
            consolidatedTranscript: [TranscriptEntry(id: "t0", sessionSeq: 0, text: "spoken words")],
            finalDerivedBlocks: [
                DerivedBlock(id: "d0", kind: .summary, text: "derived summary", revision: 3, derivedFromSeqs: [0])
            ]
        )
        let model = try makeModel(transport: transport, sessionID: "session-f")
        model.editorText = "my verbatim note"
        await model.commitEditorText()

        await model.endMeeting()

        let final = try XCTUnwrap(model.finalView)
        XCTAssertEqual(final.consolidatedTranscript.map(\.text), ["spoken words"])
        XCTAssertEqual(final.finalDerivedBlocks.map(\.text), ["derived summary"])
        XCTAssertEqual(final.userNotes.map(\.text), ["my verbatim note"], "User notes appear verbatim.")

        // Three distinct artifacts: nothing the user wrote appears in either of
        // the other two collections.
        let userTexts = Set(final.userNotes.map(\.text))
        for entry in final.consolidatedTranscript {
            XCTAssertFalse(userTexts.contains(entry.text), "User notes must never be interleaved into the transcript.")
        }
        for block in final.finalDerivedBlocks {
            XCTAssertFalse(userTexts.contains(block.text), "User notes must never be interleaved into derived output.")
        }

        // Needs-attention names the affected identities rather than a bare count.
        XCTAssertTrue(final.needsAttention)
        XCTAssertEqual(final.needsAttentionSequences, [1], "The missing segment must be named, not merely counted.")

        // A complete meeting reports nothing needing attention.
        transport.finalization = MeetingFinalization(
            sessionID: "session-f",
            declaredFinalCount: 3,
            missingSequences: [],
            consolidatedTranscript: [],
            finalDerivedBlocks: []
        )
        await model.endMeeting()
        XCTAssertFalse(try XCTUnwrap(model.finalView).needsAttention)
    }

    // MARK: - Helpers

    private var outboxRoot: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    private var notesRoot: URL { root.appendingPathComponent("notes", isDirectory: true) }

    private func makeStore() -> TransferOutboxStore { TransferOutboxStore(rootURL: outboxRoot) }

    private func segmentFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("staging-\(name)")
        try Data("segment-\(name)".utf8).write(to: url)
        return url
    }

    private func makeModel(transport: LiveMeetingTransport, sessionID: String = "session-x") throws
        -> LiveMeetingViewModel {
        let session = LiveMeetingSessionModel(store: makeStore(), deviceID: "device-under-test")
        session.start(sessionID: sessionID)
        return LiveMeetingViewModel(
            session: session,
            noteStore: UserNoteStore(directoryURL: notesRoot),
            transport: transport
        )
    }

    private func projectionFixture(revision: Int, missing: [Int]) -> MeetingProjection {
        MeetingProjection(
            revision: revision,
            transcript: [TranscriptEntry(id: "t-\(revision)", sessionSeq: 0, text: "transcribed speech")],
            derivedBlocks: [
                DerivedBlock(
                    id: "b-\(revision)",
                    kind: .summary,
                    text: "provisional summary r\(revision)",
                    revision: revision,
                    derivedFromSeqs: [0]
                ),
                DerivedBlock(
                    id: "q-\(revision)",
                    kind: .openQuestion,
                    text: "open question r\(revision)",
                    revision: revision,
                    derivedFromSeqs: [0]
                )
            ],
            missingSequences: missing,
            observedAt: Date()
        )
    }
}

/// Scripted hub. Records what was sent so tests can assert identity stability
/// and that a resend reuses `(note_block_id, revision)`.
private final class StubTransport: LiveMeetingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedProjection: MeetingProjection
    private var storedFinalization: MeetingFinalization?
    private var storedSent: [UserNoteBlock] = []
    private let failsNoteSend: Bool

    init(projection: MeetingProjection, failsNoteSend: Bool = false) {
        storedProjection = projection
        self.failsNoteSend = failsNoteSend
    }

    var projection: MeetingProjection {
        get { lock.lock(); defer { lock.unlock() }; return storedProjection }
        set { lock.lock(); storedProjection = newValue; lock.unlock() }
    }

    var finalization: MeetingFinalization? {
        get { lock.lock(); defer { lock.unlock() }; return storedFinalization }
        set { lock.lock(); storedFinalization = newValue; lock.unlock() }
    }

    var sentBlocks: [UserNoteBlock] {
        lock.lock(); defer { lock.unlock() }; return storedSent
    }

    func openSession(templateID: String) async throws -> String { "session-x" }

    func projection(sessionID: String) async throws -> MeetingProjection { projection }

    func sendUserNote(sessionID: String, block: UserNoteBlock) async throws -> UserNoteAck {
        if failsNoteSend { throw URLError(.cannotConnectToHost) }
        lock.lock()
        storedSent.append(block)
        lock.unlock()
        return UserNoteAck(noteBlockID: block.noteBlockID, revision: block.revision)
    }

    func closeSession(sessionID: String, finalSegmentCount: Int) async throws -> MeetingFinalization {
        guard let finalization else { throw URLError(.cannotConnectToHost) }
        return finalization
    }
}
