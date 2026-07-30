import Foundation
import XCTest
@testable import Yggdrasil

/// CDLM-03 durability tests.
///
/// Every test drives the **production** `TransferOutboxCoordinator` and
/// `TransferOutboxStore` against a real temporary directory. Nothing here stubs
/// the store or the release gate, because the properties under test are exactly
/// the ones a stub would assume away: what is on disk after a crash, and whether
/// an original can be deleted without a persisted receipt.
final class TransferOutboxTests: XCTestCase {
    /// Replaced with a fresh, unique directory in `setUpWithError`. Seeded rather
    /// than implicitly unwrapped so a missing setup cannot crash the suite.
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferOutboxTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - AC 1

    /// An original is deleted only after its durable-acceptance receipt is
    /// persisted, asserted at the production deletion call site.
    ///
    /// This drives every non-accepting outcome the production coordinator can
    /// reach — unreachable hub, `not_acknowledged` 500, named 4xx rejection, and
    /// a 503 receipt-store read failure — and asserts the original survives all
    /// of them. That is the "no other deletion path exists" claim tested as
    /// behaviour over the real surface, not as a code-style convention.
    func testDeletionRequiresPersistedReceipt() async throws {
        let store = makeStore()
        let item = try enqueueFixture(in: store, name: "memo-gate.m4a")

        // Direct call into the gate, in the two states that precede a receipt.
        for state in [TransferOutboxState.pendingLocally, .transferring] {
            if state == .transferring { try store.markTransferring(captureID: item.captureID) }
            XCTAssertThrowsError(try store.releaseOriginal(captureID: item.captureID)) { error in
                XCTAssertEqual(
                    error as? TransferOutboxError,
                    .releaseWithoutPersistedReceipt(captureID: item.captureID, state: state)
                )
            }
            XCTAssertTrue(mediaExists(item), "The original must survive a refused release in \(state.rawValue).")
        }

        // Every non-accepting production outcome, via the coordinator.
        let refusals: [StubTransport.Behaviour] = [
            .throwUnreachable,
            .admit(.notAcknowledged(errorCode: "raw_store_key_unavailable")),
            .admit(.rejected(errorCode: "consent_refused")),
            .query(.storeUnavailable)
        ]
        for behaviour in refusals {
            try store.markPendingLocally(captureID: item.captureID, errorCode: nil)
            if case .query = behaviour { try store.markTransferring(captureID: item.captureID) }
            let coordinator = TransferOutboxCoordinator(store: store, transport: StubTransport(behaviour))
            await coordinator.runPass()
            XCTAssertTrue(mediaExists(item), "The original must survive outcome \(behaviour).")
            let reloaded = try store.item(for: item.captureID)
            XCTAssertNotEqual(reloaded.envelope.state, .backendDurablyReceived)
            XCTAssertFalse(reloaded.envelope.originalReleased)
        }

        // Only now, with a receipt persisted, may the original go.
        let receipt = makeReceipt(for: item)
        try store.persistReceipt(receipt, for: item.captureID)
        XCTAssertTrue(mediaExists(item), "Persisting a receipt must not itself delete anything.")
        try store.releaseOriginal(captureID: item.captureID)
        XCTAssertFalse(mediaExists(item), "A receipted original is eligible for release.")

        // The receipt outlives the original.
        let released = try store.item(for: item.captureID)
        XCTAssertEqual(released.envelope.receipt?.receiptID, receipt.receiptID)
        XCTAssertTrue(released.envelope.originalReleased)
        XCTAssertEqual(released.envelope.state, .backendDurablyReceived)
    }

    // MARK: - AC 2

    /// `capture_id` is minted exactly once at finalization and survives relaunch;
    /// a resend after a lost response reuses it and persists the hub's
    /// `idempotent_replay` receipt without duplicating the item.
    func testIdentityStableAcrossRelaunchAndResend() async throws {
        let store = makeStore()
        let item = try enqueueFixture(in: store, name: "memo-identity.m4a")
        let mintedCaptureID = item.captureID
        let contentHash = item.envelope.contentSHA256

        // First attempt: the response is lost. The hub committed nothing the
        // client can see, so disk is left ambiguous.
        let lost = StubTransport(.throwUnreachable)
        await TransferOutboxCoordinator(store: store, transport: lost).runPass()
        try store.markTransferring(captureID: mintedCaptureID)

        // Relaunch: a brand-new store instance over the same directory.
        let relaunched = makeStore()
        let afterRelaunch = try XCTUnwrap(try relaunched.loadAll().first)
        XCTAssertEqual(afterRelaunch.captureID, mintedCaptureID, "capture_id must survive relaunch unchanged.")
        XCTAssertEqual(afterRelaunch.envelope.contentSHA256, contentHash, "The transfer identity must not drift.")

        // The resend is answered as an idempotent replay of the same identity.
        let replayReceipt = DurableAcceptanceReceipt(
            receiptID: "receipt-stable-1",
            captureID: mintedCaptureID,
            contentSHA256: contentHash,
            admittedAt: Date(),
            isIdempotentReplay: true
        )
        let replay = StubTransport(.query(.unknown), then: .admit(.accepted(replayReceipt)))
        let coordinator = TransferOutboxCoordinator(store: relaunched, transport: replay)
        let summary = await coordinator.runPass()

        XCTAssertEqual(summary.resent, [mintedCaptureID], "An unknown identity must be resent, not abandoned.")
        XCTAssertEqual(
            replay.admittedCaptureIDs, [mintedCaptureID],
            "The resend must reuse the already-minted capture_id rather than minting a new one."
        )

        // Exactly one item, carrying the replay receipt.
        let all = try relaunched.loadAll()
        XCTAssertEqual(all.count, 1, "A resend must never duplicate the outbox item.")
        let final = try XCTUnwrap(all.first)
        XCTAssertEqual(final.captureID, mintedCaptureID)
        XCTAssertEqual(final.envelope.receipt?.receiptID, "receipt-stable-1")
        XCTAssertTrue(try XCTUnwrap(final.envelope.receipt).isIdempotentReplay)
    }

    // MARK: - AC 3

    /// The queue rebuilds from disk alone after force-quit at each state, with no
    /// lost original and no fabricated advanced state.
    func testQueueRebuildsFromDiskAtEveryState() async throws {
        let store = makeStore()

        let pending = try enqueueFixture(in: store, name: "memo-pending.m4a")
        let transferring = try enqueueFixture(in: store, name: "memo-transferring.m4a")
        try store.markTransferring(captureID: transferring.captureID)

        // The post-2xx-pre-persist window: the hub accepted, but the process died
        // before `persistReceipt` landed. On disk that is indistinguishable from
        // any other interrupted send — which is the point.
        let ambiguous = try enqueueFixture(in: store, name: "memo-ambiguous.m4a")
        try store.markTransferring(captureID: ambiguous.captureID)

        // "Relaunch": nothing in memory carries over.
        let rebuilt = try makeStore().loadAll()
        XCTAssertEqual(rebuilt.count, 3, "Every item must be rebuilt from disk alone.")

        let byID = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.captureID, $0) })
        XCTAssertEqual(byID[pending.captureID]?.envelope.state, .pendingLocally)
        XCTAssertEqual(byID[transferring.captureID]?.envelope.state, .transferring)
        XCTAssertEqual(byID[ambiguous.captureID]?.envelope.state, .transferring)

        for item in rebuilt {
            XCTAssertTrue(mediaExists(item), "No original may be lost across a rebuild.")
            XCTAssertNil(item.envelope.receipt, "A rebuild must not fabricate a receipt.")
            XCTAssertNotEqual(
                item.envelope.state, .backendDurablyReceived,
                "A rebuild must never advance an item to an accepted state it cannot prove."
            )
            XCTAssertFalse(item.envelope.originalReleased)
        }

        // An interrupted enqueue — original on disk, envelope never written — is
        // adopted rather than orphaned or cleaned up.
        let strandedID = CaptureIdentity.mint()
        let strandedDirectory = root.appendingPathComponent(strandedID, isDirectory: true)
        try FileManager.default.createDirectory(at: strandedDirectory, withIntermediateDirectories: true)
        let strandedMedia = strandedDirectory.appendingPathComponent("memo-stranded.m4a")
        try Data("stranded-original".utf8).write(to: strandedMedia)

        let afterAdoption = try makeStore().loadAll()
        XCTAssertEqual(afterAdoption.count, 4, "An envelope-less directory must be adopted, not skipped.")
        let adopted = try XCTUnwrap(afterAdoption.first { $0.captureID == strandedID })
        XCTAssertEqual(adopted.envelope.state, .pendingLocally)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: strandedMedia.path),
            "Adoption must never delete the original it recovered."
        )
    }

    // MARK: - AC 4

    /// Recovery after an ambiguous send queries receipts first and resends only
    /// true unknowns.
    func testRecoveryQueriesReceiptsBeforeResend() async throws {
        // Case A: the hub already has the receipt. No bytes may be resent.
        let storeA = makeStore()
        let itemA = try enqueueFixture(in: storeA, name: "memo-known.m4a")
        try storeA.markTransferring(captureID: itemA.captureID)

        let known = StubTransport(.query(.admitted(makeReceipt(for: itemA))))
        let summaryA = await TransferOutboxCoordinator(store: storeA, transport: known).runPass()

        XCTAssertEqual(known.calls.first, .receiptQuery(itemA.captureID), "Recovery must query receipts first.")
        XCTAssertTrue(known.admittedCaptureIDs.isEmpty, "An already-admitted identity must not be re-uploaded.")
        XCTAssertEqual(summaryA.resolvedFromReceiptQuery, [itemA.captureID])
        let resolvedA = try storeA.item(for: itemA.captureID)
        XCTAssertEqual(resolvedA.envelope.state, .backendDurablyReceived)

        // Case B: the hub genuinely has nothing. Only now is a resend correct,
        // and it must still come after the query.
        let storeB = makeStore()
        let itemB = try enqueueFixture(in: storeB, name: "memo-unknown.m4a")
        try storeB.markTransferring(captureID: itemB.captureID)

        let unknown = StubTransport(.query(.unknown), then: .admit(.accepted(makeReceipt(for: itemB))))
        let summaryB = await TransferOutboxCoordinator(store: storeB, transport: unknown).runPass()

        XCTAssertEqual(unknown.calls.first, .receiptQuery(itemB.captureID), "The query must precede the resend.")
        XCTAssertEqual(unknown.calls.dropFirst().first, .admit(itemB.captureID))
        XCTAssertEqual(summaryB.resent, [itemB.captureID])

        // Case C: a 503 read failure is not `unknown`. Nothing may move.
        let storeC = makeStore()
        let itemC = try enqueueFixture(in: storeC, name: "memo-unavailable.m4a")
        try storeC.markTransferring(captureID: itemC.captureID)

        let unavailable = StubTransport(.query(.storeUnavailable))
        let summaryC = await TransferOutboxCoordinator(store: storeC, transport: unavailable).runPass()

        XCTAssertTrue(unavailable.admittedCaptureIDs.isEmpty, "A 503 must not trigger a blind resend.")
        XCTAssertEqual(summaryC.unresolvable, [itemC.captureID])
        XCTAssertTrue(mediaExists(itemC), "A 503 must never release an original.")
        XCTAssertEqual(try storeC.item(for: itemC.captureID).envelope.state, .transferring)
    }

    // MARK: - AC 5

    /// An unreachable hub leaves items `pending locally` with originals intact,
    /// and no watched-folder fallback occurs from the outbox path.
    func testOfflineRetainsWithoutFolderFallback() async throws {
        let store = makeStore()
        let item = try enqueueFixture(in: store, name: "memo-offline.m4a")

        // A watched folder that would receive anything the outbox wrongly fell
        // back to. It must still be empty afterwards.
        let watchedFolder = root.appendingPathComponent("WatchedFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedFolder, withIntermediateDirectories: true)

        let offline = StubTransport(.throwUnreachable)
        let coordinator = TransferOutboxCoordinator(store: store, transport: offline)

        for _ in 0..<3 {
            await coordinator.runPass()
        }

        let waiting = try store.item(for: item.captureID)
        XCTAssertEqual(waiting.envelope.state, .pendingLocally, "An unreachable hub means indefinite visible waiting.")
        XCTAssertEqual(waiting.envelope.lastErrorCode, "hub_unreachable", "The wait must explain itself.")
        XCTAssertNil(waiting.envelope.receipt)
        XCTAssertTrue(mediaExists(item), "The original must remain intact while offline.")

        let placed = try FileManager.default.contentsOfDirectory(atPath: watchedFolder.path)
        XCTAssertTrue(placed.isEmpty, "The outbox path must never fall back to the watched folder.")
    }

    // MARK: - AC 6

    /// Watch-relayed recordings enter the outbox and inherit every rule above.
    ///
    /// The first half drives the **real HCAP-06 seam** — `WatchRelayStagingReceiver`
    /// with an outbox intake attached — so this proves relayed audio actually
    /// routes into the outbox, not merely that the store can hold such an item.
    @MainActor
    func testWatchRelayEntersOutbox() async throws {
        let store = makeStore()
        let sessionModel = CaptureSessionModel()
        let receiver = WatchRelayStagingReceiver(
            sessionModel: sessionModel,
            stagingDirectory: root.appendingPathComponent("WatchStaging", isDirectory: true),
            mediaValidator: AlwaysValidRelayMediaValidator(),
            deviceID: "device-under-test",
            outboxIntake: CaptureOutboxIntake(store: store, deviceID: "device-under-test")
        )

        let relayedSource = root.appendingPathComponent("relayed-from-watch.m4a")
        try Data("relayed-audio".utf8).write(to: relayedSource)
        XCTAssertTrue(receiver.register(stagedURL: relayedSource, capturedAt: Date()))

        let viaRelay = try XCTUnwrap(try store.loadAll().first, "The relayed recording must enter the outbox.")
        XCTAssertTrue(viaRelay.envelope.cameFromWatchRelay, "Relay provenance must be recorded on intake.")
        XCTAssertEqual(viaRelay.envelope.state, .pendingLocally)
        XCTAssertTrue(mediaExists(viaRelay), "The relayed original must be in the outbox's custody.")
        XCTAssertEqual(
            sessionModel.stagedItems.first?.url, viaRelay.mediaURL,
            "The staged item must point at the outbox copy, so the visible surface resolves real bytes."
        )

        // The rest of the durability contract, on an item created the same way.
        // A separate store keeps the assertions below about exactly one item.
        let store2 = TransferOutboxStore(rootURL: root.appendingPathComponent("relay-inherits", isDirectory: true))
        let relayed = try enqueueFixture(in: store2, name: "watch-memo.m4a", cameFromWatchRelay: true)

        XCTAssertTrue(relayed.envelope.cameFromWatchRelay)
        XCTAssertFalse(relayed.captureID.isEmpty, "A relayed capture must be minted an identity like any other.")
        XCTAssertEqual(relayed.envelope.state, .pendingLocally)

        // Inherits the release gate.
        XCTAssertThrowsError(try store2.releaseOriginal(captureID: relayed.captureID))
        XCTAssertTrue(mediaExists(relayed))

        // Inherits offline retention.
        await TransferOutboxCoordinator(store: store2, transport: StubTransport(.throwUnreachable)).runPass()
        XCTAssertTrue(mediaExists(relayed))
        XCTAssertEqual(try store2.item(for: relayed.captureID).envelope.state, .pendingLocally)

        // And is released only once its receipt is persisted.
        let receipt = makeReceipt(for: relayed)
        let coordinator = TransferOutboxCoordinator(
            store: store2,
            transport: StubTransport(.admit(.accepted(receipt)))
        )
        let summary = await coordinator.runPass()

        XCTAssertEqual(summary.admitted, [relayed.captureID])
        XCTAssertEqual(summary.released, [relayed.captureID])
        XCTAssertFalse(mediaExists(relayed), "A receipted relayed original is releasable.")
        let stored = try store2.item(for: relayed.captureID)
        XCTAssertEqual(stored.envelope.receipt?.receiptID, receipt.receiptID)
        XCTAssertTrue(stored.envelope.cameFromWatchRelay, "Provenance survives release.")
    }

    // MARK: - Helpers

    private func makeStore() -> TransferOutboxStore {
        TransferOutboxStore(rootURL: root)
    }

    private func enqueueFixture(
        in store: TransferOutboxStore,
        name: String,
        cameFromWatchRelay: Bool = false
    ) throws -> TransferOutboxItem {
        let source = root.appendingPathComponent("staging-\(name)")
        try Data("finalized-audio-\(name)".utf8).write(to: source)
        let item = try store.enqueue(
            finalizedMediaURL: source,
            capturedAt: Date(),
            deviceID: "device-under-test",
            cameFromWatchRelay: cameFromWatchRelay
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "Enqueue must take custody of the bytes so no other path can delete them."
        )
        return item
    }

    private func makeReceipt(for item: TransferOutboxItem) -> DurableAcceptanceReceipt {
        DurableAcceptanceReceipt(
            receiptID: "receipt-\(item.captureID)",
            captureID: item.captureID,
            contentSHA256: item.envelope.contentSHA256,
            admittedAt: Date()
        )
    }

    private func mediaExists(_ item: TransferOutboxItem) -> Bool {
        FileManager.default.fileExists(atPath: item.mediaURL.path)
    }
}

/// Scripted transport. Records call order so tests can assert that a receipt
/// query genuinely precedes any resend rather than merely happening somewhere.
private final class StubTransport: HeimdalMediaTransporting, @unchecked Sendable {
    enum Behaviour: Equatable, CustomStringConvertible {
        case throwUnreachable
        case admit(MediaAdmissionOutcome)
        case query(ReceiptQueryOutcome)

        var description: String {
            switch self {
            case .throwUnreachable: "unreachable hub"
            case let .admit(outcome): "admission \(outcome)"
            case let .query(outcome): "receipt query \(outcome)"
            }
        }
    }

    enum Call: Equatable {
        case admit(String)
        case receiptQuery(String)
    }

    private let queryBehaviour: Behaviour?
    private let admitBehaviour: Behaviour?
    private let throwsOnAdmit: Bool
    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    init(_ first: Behaviour, then second: Behaviour? = nil) {
        var query: Behaviour?
        var admit: Behaviour?
        var unreachable = false
        for behaviour in [first, second].compactMap({ $0 }) {
            switch behaviour {
            case .throwUnreachable: unreachable = true
            case .admit: admit = behaviour
            case .query: query = behaviour
            }
        }
        queryBehaviour = query
        admitBehaviour = admit
        throwsOnAdmit = unreachable
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    var admittedCaptureIDs: [String] {
        calls.compactMap { if case let .admit(id) = $0 { return id } else { return nil } }
    }

    func admit(item: TransferOutboxItem) async throws -> MediaAdmissionOutcome {
        record(.admit(item.captureID))
        if throwsOnAdmit { throw URLError(.cannotConnectToHost) }
        guard case let .admit(outcome)? = admitBehaviour else { throw URLError(.cannotConnectToHost) }
        return outcome
    }

    func receipt(forCaptureID captureID: String) async throws -> ReceiptQueryOutcome {
        record(.receiptQuery(captureID))
        if throwsOnAdmit && queryBehaviour == nil { throw URLError(.cannotConnectToHost) }
        guard case let .query(outcome)? = queryBehaviour else { return .unknown }
        return outcome
    }

    private func record(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}

/// Relayed fixtures are not real audio; the relay seam's validator is stubbed so
/// the test exercises custody and durability rather than AVFoundation decoding.
private struct AlwaysValidRelayMediaValidator: CaptureMediaValidating {
    func validate(url: URL) -> Result<ValidatedCaptureMedia, CaptureMediaValidationFailure> {
        .success(ValidatedCaptureMedia(duration: 2))
    }
}
