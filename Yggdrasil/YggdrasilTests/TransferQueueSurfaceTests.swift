import Foundation
import XCTest
@testable import Yggdrasil

/// CDLM-05 surface tests.
///
/// These drive the production `TransferQueueViewModel` over a real
/// `TransferOutboxStore` on disk. The properties under test are precisely the
/// ones a cheap implementation would fake — a state shown without the evidence
/// behind it, or progress that survives a refresh that proved nothing — so
/// nothing here stubs the store or the derivation.
@MainActor
final class TransferQueueSurfaceTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferQueueSurfaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - AC 1

    /// Every rendered state transition is backed by the required evidence,
    /// asserted at the view-model seam that is the production render path.
    func testStatesRenderOnlyFromEvidence() async throws {
        let store = makeStore()
        let pending = try enqueue(in: store, name: "a.m4a")
        let sending = try enqueue(in: store, name: "b.m4a")
        try store.markTransferring(captureID: sending.captureID)
        let received = try enqueue(in: store, name: "c.m4a")
        try store.persistReceipt(makeReceipt(for: received), for: received.captureID)

        // No hub answers at all: only the three locally-evidenced states exist.
        let silent = StubStatusSource(answers: [:])
        let model = TransferQueueViewModel(store: store, statusSource: silent)
        await model.refresh()

        XCTAssertEqual(state(in: model, pending.captureID), .pendingLocally)
        XCTAssertEqual(state(in: model, sending.captureID), .transferring)
        XCTAssertEqual(state(in: model, received.captureID), .backendDurablyReceived)
        for item in model.items {
            XCTAssertNotEqual(item.state, .processing, "processing must never appear without a hub answer.")
            XCTAssertNotEqual(item.state, .complete, "complete must never appear without a hub answer.")
        }

        // `backend durably received` is a claim about the hub's acknowledgement,
        // so a state field alone must not produce it. Strip the receipt while
        // leaving the state, and the surface must fall back rather than assert
        // an acceptance it cannot evidence.
        let forged = TransferOutboxEnvelope(
            captureID: pending.captureID,
            contentSHA256: pending.envelope.contentSHA256,
            kind: .audio,
            capturedAt: pending.envelope.capturedAt,
            deviceID: "device",
            mediaFileName: pending.envelope.mediaFileName,
            state: .backendDurablyReceived,
            receipt: nil
        )
        XCTAssertEqual(
            TransferQueueDerivation.localState(for: forged), .transferring,
            "A received state without a persisted receipt must not render as durably received."
        )

        // A hub answer cannot skip the local state either: progress for an item
        // with no persisted receipt renders the local truth.
        let premature = StubStatusSource(answers: [
            pending.captureID: HubItemStatus(captureID: pending.captureID, progress: .processing, observedAt: Date())
        ])
        let prematureModel = TransferQueueViewModel(store: store, statusSource: premature)
        await prematureModel.refresh()
        XCTAssertEqual(
            state(in: prematureModel, pending.captureID), .pendingLocally,
            "Hub progress must not advance an item whose receipt is not persisted locally."
        )

        // With the receipt present, the same answer is honoured.
        let answered = StubStatusSource(answers: [
            received.captureID: HubItemStatus(captureID: received.captureID, progress: .complete, observedAt: Date())
        ])
        let answeredModel = TransferQueueViewModel(store: store, statusSource: answered)
        await answeredModel.refresh()
        XCTAssertEqual(state(in: answeredModel, received.captureID), .complete)
    }

    // MARK: - AC 2

    /// Cold launch renders from disk plus one receipts query, identical to the
    /// pre-kill local evidence, with staleness marking for hub-derived states.
    func testColdLaunchRendersFromDurableEvidence() async throws {
        let store = makeStore()
        let local = try enqueue(in: store, name: "local.m4a")
        let accepted = try enqueue(in: store, name: "accepted.m4a")
        try store.persistReceipt(makeReceipt(for: accepted), for: accepted.captureID)

        // Warm session: the hub reports processing.
        let live = StubStatusSource(answers: [
            accepted.captureID: HubItemStatus(captureID: accepted.captureID, progress: .processing, observedAt: Date())
        ])
        let warm = TransferQueueViewModel(store: store, statusSource: live)
        await warm.loadOnColdLaunch()
        XCTAssertEqual(state(in: warm, accepted.captureID), .processing)
        XCTAssertEqual(live.queryCount, 1, "Cold launch must issue exactly one status query.")

        // Force-quit and relaunch with the hub unreachable. Local evidence must
        // render exactly as before; hub progress is simply not yet known, and
        // must not be invented from the previous run.
        let unreachable = StubStatusSource(answers: [:], throwsError: true)
        let cold = TransferQueueViewModel(store: makeStore(), statusSource: unreachable)
        await cold.loadOnColdLaunch()

        XCTAssertEqual(unreachable.queryCount, 1, "Cold launch must issue exactly one status query.")
        XCTAssertFalse(cold.hubAnswered, "An unreachable hub must be visible, not hidden.")
        XCTAssertEqual(
            state(in: cold, local.captureID), .pendingLocally,
            "Local evidence must render identically to the pre-kill state."
        )
        XCTAssertEqual(
            state(in: cold, accepted.captureID), .backendDurablyReceived,
            "The receipt is on disk, so durable acceptance survives relaunch."
        )
        XCTAssertNil(
            cold.items.first { $0.state == .processing || $0.state == .complete },
            "Unfetched hub progress must not be reconstructed after relaunch."
        )

        // Once a hub answer arrives, hub-derived state appears and is not stale.
        let recovered = TransferQueueViewModel(
            store: makeStore(),
            statusSource: StubStatusSource(answers: [
                accepted.captureID: HubItemStatus(
                    captureID: accepted.captureID,
                    progress: .complete,
                    observedAt: Date()
                )
            ])
        )
        await recovered.loadOnColdLaunch()
        let completed = try XCTUnwrap(recovered.items.first { $0.captureID == accepted.captureID })
        XCTAssertEqual(completed.state, .complete)
        XCTAssertFalse(completed.isHubStateStale)
    }

    // MARK: - AC 3

    /// Reconnect refresh never regresses a receipt-backed state and never
    /// advances without new evidence.
    func testReconnectRefreshIsMonotoneOverEvidence() async throws {
        let store = makeStore()
        let item = try enqueue(in: store, name: "monotone.m4a")
        try store.persistReceipt(makeReceipt(for: item), for: item.captureID)

        let firstAnswer = HubItemStatus(
            captureID: item.captureID,
            progress: .processing,
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let source = StubStatusSource(answers: [item.captureID: firstAnswer])
        let model = TransferQueueViewModel(store: store, statusSource: source)
        await model.refresh()
        XCTAssertEqual(state(in: model, item.captureID), .processing)

        // A refresh that answers nothing new must not advance anything.
        await model.refresh()
        XCTAssertEqual(state(in: model, item.captureID), .processing, "No new evidence must mean no advancement.")

        // Stale evidence — an older observation — must not move the item either.
        source.answers[item.captureID] = HubItemStatus(
            captureID: item.captureID,
            progress: .complete,
            observedAt: Date(timeIntervalSince1970: 500)
        )
        await model.refresh()
        XCTAssertEqual(
            state(in: model, item.captureID), .processing,
            "An older hub observation must never overwrite a newer one."
        )

        // Genuinely newer evidence does advance it.
        source.answers[item.captureID] = HubItemStatus(
            captureID: item.captureID,
            progress: .complete,
            observedAt: Date(timeIntervalSince1970: 2_000)
        )
        await model.refresh()
        XCTAssertEqual(state(in: model, item.captureID), .complete)

        // The hub goes away. A receipt-backed state must not regress; it is
        // marked stale instead.
        source.throwsError = true
        await model.refresh()
        let afterOutage = try XCTUnwrap(model.items.first { $0.captureID == item.captureID })
        XCTAssertEqual(afterOutage.state, .complete, "A receipt-backed state must never regress on reconnect failure.")
        XCTAssertFalse(model.hubAnswered)

        // The merge rule itself, stated directly: below durable acceptance,
        // regression to truth is allowed, because CDLM-03 says an interrupted
        // send legitimately falls back to `pending locally`.
        let wasTransferring = makeItem(captureID: "x", state: .transferring)
        let nowPending = makeItem(captureID: "x", state: .pendingLocally)
        XCTAssertEqual(
            TransferQueueDerivation.merge(previous: wasTransferring, refreshed: nowPending).state,
            .pendingLocally,
            "Regression to truth below durable acceptance must be allowed, not suppressed."
        )
        let wasComplete = makeItem(captureID: "y", state: .complete)
        let nowPendingAgain = makeItem(captureID: "y", state: .pendingLocally)
        XCTAssertEqual(
            TransferQueueDerivation.merge(previous: wasComplete, refreshed: nowPendingAgain).state,
            .complete,
            "A receipt-backed state must never be unsaid."
        )
    }

    // MARK: - AC 4

    /// Each needs-attention item names its reason and offers only safe actions.
    func testNeedsAttentionIsActionableAndSafe() async throws {
        let store = makeStore()
        let refused = try enqueue(in: store, name: "refused.m4a")
        try store.markPendingLocally(captureID: refused.captureID, errorCode: "consent_refused")

        let model = TransferQueueViewModel(store: store, statusSource: StubStatusSource(answers: [:]))
        await model.refresh()

        let item = try XCTUnwrap(model.items.first { $0.captureID == refused.captureID })
        XCTAssertEqual(item.state, .needsAttention)
        let attention = try XCTUnwrap(item.attention)
        XCTAssertEqual(attention.reason, .refusedAdmission(errorCode: "consent_refused"))
        XCTAssertTrue(
            attention.reason.displayReason.contains("consent_refused"),
            "The reason must be named, not generic."
        )
        XCTAssertEqual(attention.actions, [.retry, .reveal, .discardWithConfirmation])

        // A transient failure is not a demand for the user.
        let waiting = try enqueue(in: store, name: "waiting.m4a")
        try store.markPendingLocally(captureID: waiting.captureID, errorCode: "hub_unreachable")
        await model.refresh()
        XCTAssertEqual(
            state(in: model, waiting.captureID), .pendingLocally,
            "An unreachable hub is waiting, not a demand for the user."
        )

        // Discard requires explicit confirmation and is never one-tap.
        XCTAssertTrue(item.originalExistsLocally)
        model.requestDiscard(captureID: refused.captureID)
        XCTAssertEqual(model.pendingDiscardCaptureID, refused.captureID)
        model.cancelDiscard()
        XCTAssertNil(model.pendingDiscardCaptureID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: refused.mediaURL.path),
            "Cancelling a discard must leave the original untouched."
        )

        model.requestDiscard(captureID: refused.captureID)
        XCTAssertTrue(model.confirmDiscard())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: refused.mediaURL.path),
            "A confirmed discard is an explicit user decision and removes the original."
        )

        // Once the original is gone, discard is no longer offered.
        await model.refresh()
        let discarded = try XCTUnwrap(model.items.first { $0.captureID == refused.captureID })
        XCTAssertFalse(discarded.originalExistsLocally)
        XCTAssertEqual(
            TransferQueueDerivation.safeActions(originalExistsLocally: false), [.retry, .reveal],
            "Discard must not be offered for an item with no local original."
        )

        try await assertTransferMachineryCannotDelete(in: store)
    }

    /// The CDLM-03 boundary still holds after CDLM-05 adds a user discard: the
    /// transfer machinery cannot delete an un-receipted original. Only the
    /// confirmed user action can.
    private func assertTransferMachineryCannotDelete(in store: TransferOutboxStore) async throws {
        let protected = try enqueue(in: store, name: "protected.m4a")
        try store.markPendingLocally(captureID: protected.captureID, errorCode: "consent_refused")
        let coordinator = TransferOutboxCoordinator(
            store: store,
            transport: RejectingTransport(errorCode: "consent_refused")
        )
        await coordinator.runPass()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: protected.mediaURL.path),
            "A refused item must keep its original; only an explicit user discard may remove it."
        )
    }

    // MARK: - Helpers

    private func makeStore() -> TransferOutboxStore { TransferOutboxStore(rootURL: root) }

    private func enqueue(in store: TransferOutboxStore, name: String) throws -> TransferOutboxItem {
        let source = root.appendingPathComponent("staging-\(name)")
        try Data("audio-\(name)".utf8).write(to: source)
        return try store.enqueue(finalizedMediaURL: source, capturedAt: Date(), deviceID: "device-under-test")
    }

    private func makeReceipt(for item: TransferOutboxItem) -> DurableAcceptanceReceipt {
        DurableAcceptanceReceipt(
            receiptID: "receipt-\(item.captureID)",
            captureID: item.captureID,
            contentSHA256: item.envelope.contentSHA256,
            admittedAt: Date()
        )
    }

    private func makeItem(captureID: String, state: TransferQueueState) -> TransferQueueItem {
        TransferQueueItem(
            captureID: captureID,
            state: state,
            capturedAt: Date(),
            isHubStateStale: false,
            attention: nil,
            originalExistsLocally: true,
            cameFromWatchRelay: false
        )
    }

    private func state(in model: TransferQueueViewModel, _ captureID: String) -> TransferQueueState? {
        model.items.first { $0.captureID == captureID }?.state
    }
}

private final class StubStatusSource: TransferQueueStatusSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAnswers: [String: HubItemStatus]
    private var storedThrows: Bool
    private var count = 0

    init(answers: [String: HubItemStatus], throwsError: Bool = false) {
        storedAnswers = answers
        storedThrows = throwsError
    }

    var answers: [String: HubItemStatus] {
        get { lock.lock(); defer { lock.unlock() }; return storedAnswers }
        set { lock.lock(); storedAnswers = newValue; lock.unlock() }
    }

    var throwsError: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedThrows }
        set { lock.lock(); storedThrows = newValue; lock.unlock() }
    }

    var queryCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func statuses(forCaptureIDs captureIDs: [String]) async throws -> [String: HubItemStatus] {
        lock.lock()
        count += 1
        let shouldThrow = storedThrows
        let current = storedAnswers
        lock.unlock()
        if shouldThrow { throw URLError(.cannotConnectToHost) }
        return current.filter { captureIDs.contains($0.key) }
    }
}

/// Always rejects admission with a named 4xx-family error.
private struct RejectingTransport: HeimdalMediaTransporting {
    let errorCode: String

    func admit(item: TransferOutboxItem) async throws -> MediaAdmissionOutcome {
        .rejected(errorCode: errorCode)
    }

    func receipt(forCaptureID captureID: String) async throws -> ReceiptQueryOutcome { .unknown }
}
