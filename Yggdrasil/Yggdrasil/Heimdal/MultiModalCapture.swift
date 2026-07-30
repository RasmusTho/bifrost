import Foundation

/// Per-kind capture caps, enforced *at capture* rather than after enqueue.
///
/// Refusing at capture is the point: an oversize video that reached the outbox
/// would be a durable item the hub is guaranteed to reject, so the queue would
/// carry a permanent failure the user cannot resolve. Refusing earlier keeps the
/// promise that everything in the queue is something the hub can accept.
struct CaptureKindLimits: Equatable {
    var maxVideoBytes: Int
    var maxVideoDurationSeconds: Double

    static let production = CaptureKindLimits(
        maxVideoBytes: 512 * 1_024 * 1_024,
        maxVideoDurationSeconds: 10 * 60
    )
}

enum MultiModalCaptureError: LocalizedError, Equatable {
    case videoExceedsCap(byteSize: Int, maxBytes: Int)
    case videoExceedsDurationCap(seconds: Double, maxSeconds: Double)
    case subkindRequiresDocumentKind
    case missingPartial

    var errorDescription: String? {
        switch self {
        case let .videoExceedsCap(byteSize, maxBytes):
            "This video is \(byteSize) bytes, over the \(maxBytes)-byte capture limit. It was not queued."
        case let .videoExceedsDurationCap(seconds, maxSeconds):
            "This video runs \(Int(seconds))s, over the \(Int(maxSeconds))s capture limit. It was not queued."
        case .subkindRequiresDocumentKind:
            "A receipt/document subkind only applies to a document scan."
        case .missingPartial:
            "That unfinished capture is no longer on disk."
        }
    }
}

/// An unfinalized capture: bytes on disk that never became an outbox item.
///
/// Surfaced for retry or discard, and deliberately **not** a queue entry. See
/// `MultiModalCaptureIntake` for why partials live outside the queue rather than
/// being adopted into it.
struct UnfinalizedCapture: Equatable {
    let id: String
    let url: URL
    let kind: TransferMediaKind
    let discoveredAt: Date
}

/// Finalize-then-enqueue intake for every non-audio modality.
///
/// ## Why partials live outside the queue
///
/// CDLM-03's store *adopts* a capture directory whose media landed but whose
/// envelope write was interrupted, so a finalized original is never orphaned.
/// CDLM-04 requires the opposite for an **unfinalized** capture: a crash mid-save
/// must leave no queue entry and no orphan inside the store.
///
/// Those are different situations, and they are kept structurally distinct rather
/// than by weakening the adoption rule. In-progress bytes are written to a
/// hidden `.partials` directory, which `TransferOutboxStore.loadAll()` skips
/// because it skips hidden entries. Only once a capture is complete is it moved
/// into the store under its capture identity — the temp-name-then-rename
/// discipline — at which point adoption is exactly the right behaviour, because
/// the file really is a finalized original.
///
/// So: a partial is never a queue entry, and a finalized original is never lost.
struct MultiModalCaptureIntake {
    private let store: TransferOutboxStore
    private let partialsDirectory: URL
    private let deviceID: String
    private let limits: CaptureKindLimits
    private let fileManager: FileManager

    init(
        store: TransferOutboxStore,
        partialsDirectory: URL,
        deviceID: String,
        limits: CaptureKindLimits = .production,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.partialsDirectory = partialsDirectory
        self.deviceID = deviceID
        self.limits = limits
        self.fileManager = fileManager
    }

    // MARK: - In-progress captures

    /// Opens a place to write an in-progress capture. The returned URL is inside
    /// the hidden partials area, so nothing written there can appear in the queue.
    func beginCapture(id: String = UUID().uuidString, kind: TransferMediaKind, fileExtension: String) throws -> URL {
        try fileManager.createDirectory(at: partialsDirectory, withIntermediateDirectories: true)
        return partialsDirectory.appendingPathComponent("\(kind.rawValue)-\(id).\(fileExtension)")
    }

    /// Unfinalized captures found on disk, for retry or discard. These are the
    /// only accountable place partial bytes may sit.
    func unfinalizedCaptures() -> [UnfinalizedCapture] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: partialsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        )) ?? []
        return contents.compactMap { url in
            let name = url.lastPathComponent
            guard let kind = TransferMediaKind.allCases.first(where: { name.hasPrefix("\($0.rawValue)-") }) else {
                return nil
            }
            let discoveredAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return UnfinalizedCapture(id: name, url: url, kind: kind, discoveredAt: discoveredAt)
        }.sorted { $0.discoveredAt < $1.discoveredAt }
    }

    /// Discards an unfinalized capture. Safe by definition: a partial was never
    /// an accepted capture, and it carries no receipt to contradict.
    func discardUnfinalized(_ partial: UnfinalizedCapture) throws {
        guard fileManager.fileExists(atPath: partial.url.path) else {
            throw MultiModalCaptureError.missingPartial
        }
        try fileManager.removeItem(at: partial.url)
    }

    // MARK: - Finalization

    /// Finalizes a completed capture into the outbox as one typed item.
    ///
    /// Caps are checked *before* the item enters the store, so an oversize video
    /// is refused at capture rather than enqueued and then rejected forever.
    @discardableResult
    func finalize(
        partialURL: URL,
        kind: TransferMediaKind,
        subkind: CaptureSubkind? = nil,
        pageCount: Int? = nil,
        durationSeconds: Double? = nil,
        capturedAt: Date = Date(),
        sessionRefs: [String] = []
    ) throws -> TransferOutboxItem {
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw MultiModalCaptureError.missingPartial
        }
        // Subkind is a property of a document scan's entry point. Attaching it to
        // any other kind would be meaningless at best and an inference at worst.
        if subkind != nil && kind != .document {
            throw MultiModalCaptureError.subkindRequiresDocumentKind
        }

        let byteSize = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if kind == .video {
            guard byteSize <= limits.maxVideoBytes else {
                throw MultiModalCaptureError.videoExceedsCap(byteSize: byteSize, maxBytes: limits.maxVideoBytes)
            }
            if let durationSeconds, durationSeconds > limits.maxVideoDurationSeconds {
                throw MultiModalCaptureError.videoExceedsDurationCap(
                    seconds: durationSeconds,
                    maxSeconds: limits.maxVideoDurationSeconds
                )
            }
        }

        // Complete and admissible: hand custody to the outbox, which mints the
        // capture identity and computes the content hash over the real bytes.
        return try store.enqueue(
            finalizedMediaURL: partialURL,
            kind: kind,
            subkind: subkind,
            typedMetadata: TypedCaptureMetadata(
                pageCount: kind == .document ? pageCount : nil,
                durationSeconds: durationSeconds,
                byteSize: byteSize
            ),
            capturedAt: capturedAt,
            deviceID: deviceID,
            sessionRefs: sessionRefs
        )
    }
}
