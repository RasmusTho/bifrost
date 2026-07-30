import Foundation
import SwiftUI

/// DEBUG-only scripted hub for the composed meeting journey: unreachable for the
/// first projection read (the disconnect), answering with a higher revision
/// afterwards (the reconnect). Inert in release like every other
/// `UITestLaunchConfiguration` seam.
final class ScriptedMeetingTransport: LiveMeetingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private static let readsRefusedBeforeReconnect = 1

    func openSession(templateID: String) async throws -> String { "ui-test-session" }

    func projection(sessionID: String) async throws -> MeetingProjection {
        lock.lock(); reads += 1; let readCount = reads; lock.unlock()
        // The cold-launch read is refused, so the disconnect is observable;
        // the read the Reconnect action triggers is answered.
        guard readCount > Self.readsRefusedBeforeReconnect else { throw URLError(.cannotConnectToHost) }
        return MeetingProjection(
            revision: readCount,
            transcript: [TranscriptEntry(id: "t0", sessionSeq: 0, text: "transcribed speech")],
            derivedBlocks: [
                DerivedBlock(
                    id: "b0",
                    kind: .summary,
                    text: "provisional summary",
                    revision: readCount,
                    derivedFromSeqs: [0]
                )
            ],
            missingSequences: readCount > Self.readsRefusedBeforeReconnect + 1 ? [] : [1],
            observedAt: Date()
        )
    }

    func sendUserNote(sessionID: String, block: UserNoteBlock) async throws -> UserNoteAck {
        UserNoteAck(noteBlockID: block.noteBlockID, revision: block.revision)
    }

    func closeSession(sessionID: String, finalSegmentCount: Int) async throws -> MeetingFinalization {
        MeetingFinalization(
            sessionID: sessionID,
            declaredFinalCount: finalSegmentCount,
            missingSequences: [],
            consolidatedTranscript: [TranscriptEntry(id: "t0", sessionSeq: 0, text: "transcribed speech")],
            finalDerivedBlocks: [
                DerivedBlock(id: "b0", kind: .summary, text: "final summary", revision: 9, derivedFromSeqs: [0])
            ]
        )
    }
}

/// Canonical location of the live-meeting note store, so the app and the
/// surface agree on one path rather than each composing their own.
enum LiveMeetingNotePaths {
    static func defaultDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LiveMeetingNotes", isDirectory: true)
    }
}

/// Builds the live meeting surface over the real outbox and note stores.
struct LiveMeetingHost: View {
    @StateObject private var model: LiveMeetingViewModel

    init(transport: LiveMeetingTransport, deviceID: String = "device") {
        let store = TransferOutboxStore()
        let session = LiveMeetingSessionModel(store: store, deviceID: deviceID)
        session.start(sessionID: "ui-test-session")
        let notesDirectory = LiveMeetingNotePaths.defaultDirectory()
        _model = StateObject(
            wrappedValue: LiveMeetingViewModel(
                session: session,
                noteStore: UserNoteStore(directoryURL: notesDirectory),
                transport: transport
            )
        )
    }

    var body: some View {
        NavigationStack {
            LiveMeetingView(model: model)
        }
        .task { await model.refreshProjection() }
    }
}
