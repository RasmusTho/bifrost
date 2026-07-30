import Foundation
import XCTest
@testable import Yggdrasil

/// CDLM-04 tests.
///
/// The point of this slice is that modality is a *field*, not a second delivery
/// path, so these tests deliberately re-check CDLM-03's durability rules through
/// the new kinds rather than trusting that they carry over.
final class MultiModalCaptureTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiModalCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - AC 1

    /// Each modality finalizes into the outbox as a complete admissible file with
    /// a correct typed sidecar, including a `content_sha256` that matches bytes.
    func testEachModalityFinalizesTypedOutboxItem() throws {
        let store = makeStore()
        let intake = makeIntake(store: store)

        let image = try finalize(intake, kind: .image, bytes: "photo-bytes", ext: "jpg")
        let document = try finalize(
            intake, kind: .document, bytes: "pdf-bytes", ext: "pdf",
            subkind: .receipt, pageCount: 2
        )
        let video = try finalize(intake, kind: .video, bytes: "video-bytes", ext: "mov", duration: 20)
        let audio = try store.enqueue(
            finalizedMediaURL: try writeSource(named: "memo.m4a", bytes: "audio-bytes"),
            kind: .audio,
            capturedAt: Date(),
            deviceID: "device-under-test"
        )

        XCTAssertEqual(image.envelope.kind, .image)
        XCTAssertNil(image.envelope.subkind, "Subkind applies only to document scans.")

        XCTAssertEqual(document.envelope.kind, .document)
        XCTAssertEqual(document.envelope.subkind, .receipt)
        XCTAssertEqual(document.envelope.typedMetadata.pageCount, 2, "Documents must carry their page count.")

        XCTAssertEqual(video.envelope.kind, .video)
        XCTAssertEqual(video.envelope.typedMetadata.durationSeconds, 20)
        XCTAssertNil(video.envelope.typedMetadata.pageCount, "Page count is meaningless for video.")

        // Every kind is one outbox item, and each hash matches its own bytes.
        for item in [image, document, video, audio] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.mediaURL.path))
            XCTAssertEqual(
                item.envelope.contentSHA256,
                try TransferOutboxStore.sha256Hex(of: item.mediaURL),
                "content_sha256 must match the finalized bytes for \(item.envelope.kind.rawValue)."
            )
            XCTAssertEqual(item.envelope.state, .pendingLocally)
        }

        // Byte size is a per-kind minimum for the modalities this slice adds.
        // Audio keeps the unchanged CDLM-03 intake, which records no byte size
        // and is not required to — this slice does not alter the audio path.
        for item in [image, document, video] {
            XCTAssertNotNil(
                item.envelope.typedMetadata.byteSize,
                "\(item.envelope.kind.rawValue) must record its byte size at finalization."
            )
        }
        XCTAssertTrue(
            audio.envelope.typedMetadata.isEmpty,
            "The audio path is unchanged by this slice and carries no typed metadata."
        )
        XCTAssertEqual(try store.loadAll().count, 4, "Every modality is just another outbox item.")
    }

    // MARK: - AC 2

    /// A crash before finalization leaves no queue entry and no orphaned partial
    /// inside the outbox store; recovery surfaces the partial for retry or discard.
    func testUnfinalizedCaptureStaysOutOfQueue() throws {
        let store = makeStore()
        let intake = makeIntake(store: store)

        // A capture that started writing and never finished.
        let partialURL = try intake.beginCapture(kind: .video, fileExtension: "mov")
        try Data("half-written-video".utf8).write(to: partialURL)

        // "Relaunch": a fresh store over the same root must not see a queue entry.
        XCTAssertTrue(
            try makeStore().loadAll().isEmpty,
            "An unfinalized capture must never appear as a queue entry."
        )

        // Nor may it sit as an orphan inside the store's item area: partials live
        // in their own accountable place.
        let storeEntries = try FileManager.default.contentsOfDirectory(atPath: outboxRoot.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertTrue(storeEntries.isEmpty, "No orphaned partial may sit among outbox items: \(storeEntries)")

        // Recovery surfaces it for retry or discard, and the bytes are still there.
        let partials = intake.unfinalizedCaptures()
        XCTAssertEqual(partials.count, 1, "The partial must be recoverable, not silently dropped.")
        let recovered = try XCTUnwrap(partials.first)
        XCTAssertEqual(recovered.kind, .video)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.url.path))

        // Retry: finalizing the recovered partial produces an ordinary item.
        let finalized = try intake.finalize(partialURL: recovered.url, kind: .video, durationSeconds: 5)
        XCTAssertEqual(try store.loadAll().count, 1)
        XCTAssertEqual(finalized.envelope.kind, .video)
        XCTAssertTrue(intake.unfinalizedCaptures().isEmpty, "Finalizing consumes the partial.")

        // Discard: the other safe action on a partial.
        let second = try intake.beginCapture(kind: .image, fileExtension: "jpg")
        try Data("half-written-photo".utf8).write(to: second)
        let toDiscard = try XCTUnwrap(intake.unfinalizedCaptures().first)
        try intake.discardUnfinalized(toDiscard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try store.loadAll().count, 1, "Discarding a partial must not touch real items.")
    }

    // MARK: - AC 3

    /// Receipt vs document subkind follows the user's entry point only, and is
    /// carried through envelope and sidecar.
    func testSubkindFollowsEntryPointOnly() throws {
        let store = makeStore()
        let intake = makeIntake(store: store)

        // Byte-identical scans; only the entry point differs. Any content-based
        // inference would be forced to give these the same subkind.
        let identicalBytes = "%PDF-1.4 identical scan bytes"
        let asReceipt = try finalize(
            intake, kind: .document, bytes: identicalBytes, ext: "pdf",
            subkind: .receipt, pageCount: 1
        )
        let asDocument = try finalize(
            intake, kind: .document, bytes: identicalBytes, ext: "pdf",
            subkind: .document, pageCount: 1
        )

        XCTAssertEqual(asReceipt.envelope.subkind, .receipt)
        XCTAssertEqual(asDocument.envelope.subkind, .document)
        XCTAssertEqual(
            asReceipt.envelope.contentSHA256, asDocument.envelope.contentSHA256,
            "The bytes are identical, so only the entry point can explain the differing subkind."
        )

        // Survives a reload: subkind is durable, not a UI-only distinction.
        let reloaded = try makeStore().item(for: asReceipt.captureID)
        XCTAssertEqual(reloaded.envelope.subkind, .receipt)

        // Subkind is meaningless off a document scan and is refused rather than
        // silently dropped.
        let strayURL = try intake.beginCapture(kind: .image, fileExtension: "jpg")
        try Data("photo".utf8).write(to: strayURL)
        XCTAssertThrowsError(try intake.finalize(partialURL: strayURL, kind: .image, subkind: .receipt)) { error in
            XCTAssertEqual(error as? MultiModalCaptureError, .subkindRequiresDocumentKind)
        }
    }

    // MARK: - AC 4

    /// Oversize video is refused at capture with a legible state, not
    /// enqueued-then-rejected.
    func testVideoCapRefusedAtCapture() throws {
        let store = makeStore()
        let intake = MultiModalCaptureIntake(
            store: store,
            partialsDirectory: partialsRoot,
            deviceID: "device-under-test",
            limits: CaptureKindLimits(maxVideoBytes: 32, maxVideoDurationSeconds: 10)
        )

        let oversizeURL = try intake.beginCapture(kind: .video, fileExtension: "mov")
        try Data(String(repeating: "v", count: 64).utf8).write(to: oversizeURL)

        XCTAssertThrowsError(try intake.finalize(partialURL: oversizeURL, kind: .video)) { error in
            guard case let .videoExceedsCap(byteSize, maxBytes)? = error as? MultiModalCaptureError else {
                return XCTFail("Expected a legible cap refusal, got \(error)")
            }
            XCTAssertEqual(byteSize, 64)
            XCTAssertEqual(maxBytes, 32)
            XCTAssertTrue(
                (error as? MultiModalCaptureError)?.errorDescription?.contains("not queued") == true,
                "The refusal must say plainly that nothing was queued."
            )
        }

        XCTAssertTrue(try store.loadAll().isEmpty, "An over-cap video must never become a queue entry.")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oversizeURL.path),
            "Refusing at capture must not destroy the user's bytes; the partial stays recoverable."
        )

        // A too-long video is refused the same way.
        let longURL = try intake.beginCapture(kind: .video, fileExtension: "mov")
        try Data("ok".utf8).write(to: longURL)
        XCTAssertThrowsError(try intake.finalize(partialURL: longURL, kind: .video, durationSeconds: 30)) { error in
            guard case .videoExceedsDurationCap? = error as? MultiModalCaptureError else {
                return XCTFail("Expected a duration cap refusal, got \(error)")
            }
        }
        XCTAssertTrue(try store.loadAll().isEmpty)

        // Within the cap, it queues normally.
        let okURL = try intake.beginCapture(kind: .video, fileExtension: "mov")
        try Data("small".utf8).write(to: okURL)
        XCTAssertNoThrow(try intake.finalize(partialURL: okURL, kind: .video, durationSeconds: 5))
        XCTAssertEqual(try store.loadAll().count, 1)
    }

    // MARK: - AC 5

    /// All new kinds inherit CDLM-03 retention/resend semantics unchanged.
    func testNewKindsInheritOutboxSemantics() async throws {
        let store = makeStore()
        let intake = makeIntake(store: store)

        for (kind, ext) in [(TransferMediaKind.image, "jpg"), (.document, "pdf"), (.video, "mov")] {
            let scopedRoot = root.appendingPathComponent("scoped-\(kind.rawValue)", isDirectory: true)
            let scopedStore = TransferOutboxStore(rootURL: scopedRoot)
            let scopedIntake = MultiModalCaptureIntake(
                store: scopedStore,
                partialsDirectory: scopedRoot.appendingPathComponent(".partials"),
                deviceID: "device-under-test"
            )
            let partialURL = try scopedIntake.beginCapture(kind: kind, fileExtension: ext)
            try Data("bytes-\(kind.rawValue)".utf8).write(to: partialURL)
            let item = try scopedIntake.finalize(
                partialURL: partialURL,
                kind: kind,
                subkind: kind == .document ? .document : nil,
                pageCount: kind == .document ? 1 : nil,
                durationSeconds: kind == .video ? 3 : nil
            )

            // Receipt-gated release, unchanged for this kind.
            XCTAssertThrowsError(
                try scopedStore.releaseOriginal(captureID: item.captureID),
                "\(kind.rawValue) must not be released without a persisted receipt."
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.mediaURL.path))

            // Offline retention, unchanged for this kind.
            let offline = TransferOutboxCoordinator(store: scopedStore, transport: UnreachableTransport())
            await offline.runPass()
            XCTAssertEqual(try scopedStore.item(for: item.captureID).envelope.state, .pendingLocally)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.mediaURL.path))

            // Receipted release, unchanged for this kind.
            let receipt = DurableAcceptanceReceipt(
                receiptID: "receipt-\(item.captureID)",
                captureID: item.captureID,
                contentSHA256: item.envelope.contentSHA256,
                admittedAt: Date()
            )
            let accepting = TransferOutboxCoordinator(
                store: scopedStore,
                transport: AcceptingTransport(receipt: receipt)
            )
            let summary = await accepting.runPass()
            XCTAssertEqual(summary.released, [item.captureID], "\(kind.rawValue) must release once receipted.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.mediaURL.path))

            // Typed facts survive release, so the record stays truthful.
            let released = try scopedStore.item(for: item.captureID)
            XCTAssertEqual(released.envelope.kind, kind)
            XCTAssertTrue(released.envelope.originalReleased)
            XCTAssertNotNil(released.envelope.receipt)
        }

        _ = intake
    }

    // MARK: - Helpers

    private var outboxRoot: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    private var partialsRoot: URL { root.appendingPathComponent("outbox/.partials", isDirectory: true) }

    private func makeStore() -> TransferOutboxStore { TransferOutboxStore(rootURL: outboxRoot) }

    private func makeIntake(store: TransferOutboxStore) -> MultiModalCaptureIntake {
        MultiModalCaptureIntake(store: store, partialsDirectory: partialsRoot, deviceID: "device-under-test")
    }

    private func writeSource(named: String, bytes: String) throws -> URL {
        let url = root.appendingPathComponent("source-\(UUID().uuidString)-\(named)")
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func finalize(
        _ intake: MultiModalCaptureIntake,
        kind: TransferMediaKind,
        bytes: String,
        ext: String,
        subkind: CaptureSubkind? = nil,
        pageCount: Int? = nil,
        duration: Double? = nil
    ) throws -> TransferOutboxItem {
        let partialURL = try intake.beginCapture(kind: kind, fileExtension: ext)
        try Data(bytes.utf8).write(to: partialURL)
        return try intake.finalize(
            partialURL: partialURL,
            kind: kind,
            subkind: subkind,
            pageCount: pageCount,
            durationSeconds: duration
        )
    }
}

private struct UnreachableTransport: HeimdalMediaTransporting {
    func admit(item: TransferOutboxItem) async throws -> MediaAdmissionOutcome {
        throw URLError(.cannotConnectToHost)
    }

    func receipt(forCaptureID captureID: String) async throws -> ReceiptQueryOutcome {
        throw URLError(.cannotConnectToHost)
    }
}

private struct AcceptingTransport: HeimdalMediaTransporting {
    let receipt: DurableAcceptanceReceipt

    func admit(item: TransferOutboxItem) async throws -> MediaAdmissionOutcome { .accepted(receipt) }
    func receipt(forCaptureID captureID: String) async throws -> ReceiptQueryOutcome { .admitted(receipt) }
}
