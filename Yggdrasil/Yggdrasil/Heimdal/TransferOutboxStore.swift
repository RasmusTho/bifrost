import CryptoKit
import Foundation

enum TransferOutboxError: LocalizedError, Equatable {
    case missingSource
    case unknownItem(captureID: String)
    /// Raised when a release is attempted without a persisted receipt. This is
    /// the guard that makes receipt-gated release a property of the store
    /// rather than a convention its callers are trusted to follow.
    case releaseWithoutPersistedReceipt(captureID: String, state: TransferOutboxState)

    var errorDescription: String? {
        switch self {
        case .missingSource:
            "The finalized recording is no longer available to take into the outbox."
        case let .unknownItem(captureID):
            "No outbox item exists for capture \(captureID)."
        case let .releaseWithoutPersistedReceipt(captureID, state):
            """
            Refusing to delete the original for capture \(captureID): its state is \
            \(state.rawValue) and no durable-acceptance receipt is persisted.
            """
        }
    }
}

/// The on-disk transfer outbox.
///
/// ## Custody
///
/// Enqueueing **moves** the finalized original into a directory the outbox owns
/// outright, one directory per capture identity. That is deliberate: it makes
/// "no other code path deletes outbox media" a structural property rather than a
/// rule other code is trusted to respect. Once an item is enqueued, the only
/// code in the app that can remove those bytes is `releaseOriginal(captureID:)`,
/// and that function refuses to act without a persisted receipt.
///
/// ## Durability ordering
///
/// Media is moved into place *before* its envelope is written, and every
/// envelope write is atomic (write to a temporary sibling, then replace). The
/// consequences of a crash at each point are therefore bounded:
///
/// - crash after the move, before the first envelope write → the directory holds
///   an original with no envelope. `loadAll()` adopts it and writes a
///   `pendingLocally` envelope, so the original is accounted for rather than
///   orphaned. Nothing is ever deleted to "clean up" such a directory.
/// - crash during an envelope update → the previous envelope survives intact,
///   because a partially written temporary file is never swapped in.
/// - crash after the hub's 2xx but before `persistReceipt` → the envelope still
///   says `transferring`, which the coordinator resolves by querying receipts.
///   It never infers acceptance from the absence of a receipt.
///
/// The store performs no network work and holds no in-memory authority: every
/// query reads disk.
struct TransferOutboxStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private static let envelopeFileName = "envelope.json"

    init(rootURL: URL = TransferOutboxStore.defaultRootURL(), fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HeimdalTransferOutbox", isDirectory: true)
    }

    // MARK: - Intake

    /// Takes custody of a finalized original and mints its identity exactly once.
    ///
    /// `captureID` is minted here and never re-minted. The content hash is
    /// computed over the bytes now in the outbox, so the `(capture_id,
    /// content_sha256)` transfer identity the hub keys on is fixed before any
    /// send can happen.
    @discardableResult
    func enqueue(
        finalizedMediaURL: URL,
        kind: TransferMediaKind = .audio,
        capturedAt: Date,
        deviceID: String,
        sessionRefs: [String] = [],
        cameFromWatchRelay: Bool = false,
        captureID: String = CaptureIdentity.mint()
    ) throws -> TransferOutboxItem {
        guard fileManager.fileExists(atPath: finalizedMediaURL.path) else {
            throw TransferOutboxError.missingSource
        }

        let identity = CaptureIdentity.canonical(captureID)
        let directoryURL = directory(for: identity)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let mediaFileName = finalizedMediaURL.lastPathComponent
        let mediaURL = directoryURL.appendingPathComponent(mediaFileName)
        if !fileManager.fileExists(atPath: mediaURL.path) {
            // Custody transfer. A cross-volume move is not expected here (staging
            // and the outbox share the app container), but fall back to copy so an
            // unexpected layout degrades into duplicated bytes rather than a lost
            // original.
            do {
                try fileManager.moveItem(at: finalizedMediaURL, to: mediaURL)
            } catch {
                try fileManager.copyItem(at: finalizedMediaURL, to: mediaURL)
                try? fileManager.removeItem(at: finalizedMediaURL)
            }
        }

        let envelope = TransferOutboxEnvelope(
            captureID: identity,
            contentSHA256: try Self.sha256Hex(of: mediaURL),
            kind: kind,
            capturedAt: capturedAt,
            deviceID: deviceID,
            sessionRefs: sessionRefs,
            mediaFileName: mediaFileName,
            cameFromWatchRelay: cameFromWatchRelay
        )
        try write(envelope: envelope, to: directoryURL)
        return TransferOutboxItem(envelope: envelope, directoryURL: directoryURL)
    }

    // MARK: - Disk-rebuilt truth

    /// Rebuilds the queue from disk alone. No in-memory state contributes, and
    /// no state is ever advanced during a rebuild: an item that was
    /// `transferring` when the process died is still `transferring`, which is
    /// exactly the ambiguity the coordinator must resolve against the hub.
    func loadAll() throws -> [TransferOutboxItem] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var items: [TransferOutboxItem] = []
        for directoryURL in directories {
            guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let envelope = try? readEnvelope(in: directoryURL) {
                items.append(TransferOutboxItem(envelope: envelope, directoryURL: directoryURL))
            } else if let adopted = try adoptEnvelopelessDirectory(directoryURL) {
                items.append(adopted)
            }
        }
        return items.sorted { $0.envelope.capturedAt < $1.envelope.capturedAt }
    }

    func item(for captureID: String) throws -> TransferOutboxItem {
        let identity = CaptureIdentity.canonical(captureID)
        let directoryURL = directory(for: identity)
        guard let envelope = try? readEnvelope(in: directoryURL) else {
            throw TransferOutboxError.unknownItem(captureID: identity)
        }
        return TransferOutboxItem(envelope: envelope, directoryURL: directoryURL)
    }

    /// Recovers a directory whose envelope never landed (a crash between the
    /// custody move and the first envelope write). The original is present, so
    /// the honest reconstruction is a fresh `pendingLocally` envelope keyed on
    /// the directory name, which is the already-minted capture identity.
    private func adoptEnvelopelessDirectory(_ directoryURL: URL) throws -> TransferOutboxItem? {
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let mediaURL = contents.first(where: { $0.lastPathComponent != Self.envelopeFileName }) else {
            return nil
        }
        let identity = CaptureIdentity.canonical(directoryURL.lastPathComponent)
        let capturedAt = (try? mediaURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let envelope = TransferOutboxEnvelope(
            captureID: identity,
            contentSHA256: try Self.sha256Hex(of: mediaURL),
            kind: .audio,
            capturedAt: capturedAt,
            deviceID: "",
            mediaFileName: mediaURL.lastPathComponent,
            lastErrorCode: "envelope_rebuilt_after_interrupted_enqueue"
        )
        try write(envelope: envelope, to: directoryURL)
        return TransferOutboxItem(envelope: envelope, directoryURL: directoryURL)
    }

    // MARK: - State transitions

    func markTransferring(captureID: String, at date: Date = Date()) throws {
        try mutate(captureID: captureID) { envelope in
            envelope.state = .transferring
            envelope.lastAttemptAt = date
        }
    }

    /// Returns an item to the waiting state with a named reason. Never touches
    /// the original, and never clears a receipt that is already persisted.
    func markPendingLocally(captureID: String, errorCode: String?, at date: Date = Date()) throws {
        try mutate(captureID: captureID) { envelope in
            guard envelope.receipt == nil else { return }
            envelope.state = .pendingLocally
            envelope.lastErrorCode = errorCode
            envelope.lastAttemptAt = date
        }
    }

    /// Persists the hub's receipt. This is the write that must land *before any
    /// deletion is considered*, and it is atomic, so the observable states are
    /// "no receipt" and "receipt durably present" — never a half-written one.
    func persistReceipt(_ receipt: DurableAcceptanceReceipt, for captureID: String) throws {
        try mutate(captureID: captureID) { envelope in
            envelope.receipt = receipt
            envelope.state = .backendDurablyReceived
            envelope.lastErrorCode = nil
        }
    }

    // MARK: - Receipt-gated release

    /// **The only code path in the app that deletes outbox media.**
    ///
    /// Refuses unless a durable-acceptance receipt is persisted for this exact
    /// item. The receipt and envelope are retained after the original is gone,
    /// so the record of acceptance outlives the bytes it attests to.
    func releaseOriginal(captureID: String) throws {
        let item = try item(for: captureID)
        guard item.envelope.isEligibleForRelease else {
            // Already released is a no-op rather than an error: the invariant
            // (no un-receipted original was deleted) still holds.
            if item.envelope.originalReleased { return }
            throw TransferOutboxError.releaseWithoutPersistedReceipt(
                captureID: item.captureID,
                state: item.envelope.state
            )
        }
        if fileManager.fileExists(atPath: item.mediaURL.path) {
            try fileManager.removeItem(at: item.mediaURL)
        }
        try mutate(captureID: captureID) { envelope in
            envelope.originalReleased = true
        }
    }

    /// Deletes an original because **the user explicitly said so** (CDLM-05's
    /// discard action, which requires confirmation at the view-model seam).
    ///
    /// This is the one deletion of outbox media that is not receipt-gated, and
    /// the naming is deliberately awkward so it cannot be reached for casually.
    /// It is never called by `TransferOutboxCoordinator`: the transfer
    /// machinery still has exactly one deletion path, `releaseOriginal`, and
    /// still cannot delete an un-receipted original. CDLM-03's guarantee is
    /// about what the machinery does on the user's behalf, not about forbidding
    /// the user to discard their own capture.
    ///
    /// The envelope is retained and marked, so the item remains a truthful
    /// record that a capture existed and was deliberately thrown away.
    func discardByExplicitUserAction(captureID: String) throws {
        let item = try item(for: captureID)
        if fileManager.fileExists(atPath: item.mediaURL.path) {
            try fileManager.removeItem(at: item.mediaURL)
        }
        try mutate(captureID: captureID) { envelope in
            envelope.originalReleased = true
            envelope.lastErrorCode = "discarded_by_user"
        }
    }

    // MARK: - Envelope IO

    private func directory(for captureID: String) -> URL {
        rootURL.appendingPathComponent(CaptureIdentity.canonical(captureID), isDirectory: true)
    }

    private func mutate(captureID: String, _ transform: (inout TransferOutboxEnvelope) -> Void) throws {
        let identity = CaptureIdentity.canonical(captureID)
        let directoryURL = directory(for: identity)
        guard var envelope = try? readEnvelope(in: directoryURL) else {
            throw TransferOutboxError.unknownItem(captureID: identity)
        }
        transform(&envelope)
        try write(envelope: envelope, to: directoryURL)
    }

    private func readEnvelope(in directoryURL: URL) throws -> TransferOutboxEnvelope {
        let data = try Data(contentsOf: directoryURL.appendingPathComponent(Self.envelopeFileName))
        return try Self.decoder.decode(TransferOutboxEnvelope.self, from: data)
    }

    /// Atomic envelope write: a partially written temporary file can never be
    /// mistaken for the envelope, because the swap into place is a rename.
    private func write(envelope: TransferOutboxEnvelope, to directoryURL: URL) throws {
        let data = try Self.encoder.encode(envelope)
        let finalURL = directoryURL.appendingPathComponent(Self.envelopeFileName)
        let temporaryURL = directoryURL.appendingPathComponent("\(Self.envelopeFileName).writing")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
