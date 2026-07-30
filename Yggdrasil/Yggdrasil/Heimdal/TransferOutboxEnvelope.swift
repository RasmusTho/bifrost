import Foundation

/// The media kinds the outbox can carry.
///
/// Modality is a field on the item, not a fork in the delivery path: every kind
/// is the same outbox item with the same durability rules, so CDLM-03's proofs
/// cover all of them without being re-litigated per kind.
enum TransferMediaKind: String, Codable, Equatable, CaseIterable {
    case audio
    case image
    case document
    case video
}

/// Distinguishes a receipt scan from a general document scan.
///
/// Chosen by the user's capture entry point and nothing else. The client never
/// inspects content to decide this — that would be derived meaning, which the
/// raw seam (INV-B3-2) keeps off the device for every modality.
enum CaptureSubkind: String, Codable, Equatable {
    case receipt
    case document
}

/// Per-kind minimum metadata carried alongside the CDLM-01 sidecar fields.
///
/// These are capture-time facts — how many pages the scanner produced, how long
/// the video ran — never anything derived from the content itself.
struct TypedCaptureMetadata: Codable, Equatable {
    /// Documents only: pages in the finalized PDF.
    var pageCount: Int?
    /// Video and audio: recorded duration.
    var durationSeconds: Double?
    /// Rough size of the finalized file, recorded at finalization.
    var byteSize: Int?

    init(pageCount: Int? = nil, durationSeconds: Double? = nil, byteSize: Int? = nil) {
        self.pageCount = pageCount
        self.durationSeconds = durationSeconds
        self.byteSize = byteSize
    }

    enum CodingKeys: String, CodingKey {
        case pageCount = "page_count"
        case durationSeconds = "duration_seconds"
        case byteSize = "byte_size"
    }

    var isEmpty: Bool { pageCount == nil && durationSeconds == nil && byteSize == nil }
}

/// Lifecycle of one outbox item. These are the only three states that exist on
/// disk, and every one of them is a state in which the original is still
/// present unless its receipt has been persisted.
///
/// There is deliberately no `failed` state. A rejection or an unreachable hub
/// returns the item to `pendingLocally` with a recorded error code: failure is
/// a reason an item is still waiting, never a reason it stops being accounted
/// for (INV-CDLM-2).
enum TransferOutboxState: String, Codable, Equatable {
    /// Never sent, or sent and returned unacknowledged. The original is present.
    case pendingLocally = "pending_locally"
    /// A send was attempted and its outcome is not yet known on disk. This is
    /// the only ambiguous state, and it is resolved by querying receipts —
    /// never by guessing.
    case transferring
    /// The hub's durable-acceptance receipt is persisted locally. This is the
    /// only state in which the original may be released.
    case backendDurablyReceived = "backend_durably_received"
}

/// The hub's durable-acceptance receipt, as persisted on device.
///
/// `receiptID` is the authoritative identity: the hub derives it from
/// `(capture_id, content_sha256)` and it is the receipt table's primary key, so
/// a resend of the same transfer identity returns the same `receiptID`. Per
/// `docs/EVENTS.md :: Heimdal governed media ingress + durable receipts`, a
/// consumer keys on `receipt_id` and never on admission-event arrival counts.
///
/// The client stores what the hub returned rather than re-deriving the uuid5
/// itself: re-deriving would require reproducing the hub's namespace exactly,
/// and a client that guessed it wrong would compute a confident, wrong
/// identity. Stability is instead asserted by comparison across a replay.
struct DurableAcceptanceReceipt: Codable, Equatable {
    let receiptID: String
    let captureID: String
    let contentSHA256: String
    let admittedAt: Date
    /// The hub's reference to the stored raw object, when it supplied one.
    ///
    /// Not load-bearing for release, and deliberately so: `KD-4384-RETENTION`
    /// records that hard retention can delete the raw object a receipt attests
    /// to, leaving a `rawRef` that no longer resolves. Release is gated on the
    /// persisted receipt, which is the acknowledgement the hub actually made.
    let rawRef: String?
    /// `true` when the hub reported this admission as an idempotent replay of
    /// an already-acknowledged identity rather than a first admission.
    let isIdempotentReplay: Bool

    enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id"
        case captureID = "capture_id"
        case contentSHA256 = "content_sha256"
        case admittedAt = "admitted_at"
        case rawRef = "raw_ref"
        case isIdempotentReplay = "idempotent_replay"
    }

    init(
        receiptID: String,
        captureID: String,
        contentSHA256: String,
        admittedAt: Date,
        rawRef: String? = nil,
        isIdempotentReplay: Bool = false
    ) {
        self.receiptID = receiptID
        self.captureID = CaptureIdentity.canonical(captureID)
        self.contentSHA256 = contentSHA256
        self.admittedAt = admittedAt
        self.rawRef = rawRef
        self.isIdempotentReplay = isIdempotentReplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receiptID = try container.decode(String.self, forKey: .receiptID)
        captureID = CaptureIdentity.canonical(try container.decode(String.self, forKey: .captureID))
        contentSHA256 = try container.decode(String.self, forKey: .contentSHA256)
        admittedAt = try container.decodeIfPresent(Date.self, forKey: .admittedAt) ?? Date()
        rawRef = try container.decodeIfPresent(String.self, forKey: .rawRef)
        isIdempotentReplay = try container.decodeIfPresent(Bool.self, forKey: .isIdempotentReplay) ?? false
    }
}

/// Capture-identity spelling rules.
///
/// The hub canonicalizes capture-id spelling, so an uppercase UUID is the same
/// identity as its lowercase form. The client canonicalizes on the way in so a
/// receipt returned for `ABC…` is matched against a locally stored `abc…`
/// instead of being mistaken for a different item.
enum CaptureIdentity {
    static func canonical(_ captureID: String) -> String {
        captureID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Mints a new capture identity. Called exactly once per capture, at
    /// finalization, before any send (INV-CDLM-3).
    static func mint() -> String {
        canonical(UUID().uuidString)
    }
}

/// The durable record for one outbox item: everything needed to resume, resolve,
/// and release without consulting in-memory state.
struct TransferOutboxEnvelope: Codable, Equatable {
    let captureID: String
    let contentSHA256: String
    let kind: TransferMediaKind
    /// Receipt vs document, for `kind == .document`. Set from the user's entry
    /// point only; `nil` for every other kind.
    let subkind: CaptureSubkind?
    /// Per-kind capture-time facts (page count, duration, byte size).
    let typedMetadata: TypedCaptureMetadata
    let capturedAt: Date
    let deviceID: String
    /// Session references when the capture belongs to one. Empty for a
    /// standalone memo; meeting-session semantics are a different slice.
    let sessionRefs: [String]
    /// File name of the original inside this item's outbox directory. The
    /// outbox owns these bytes outright.
    let mediaFileName: String
    var state: TransferOutboxState
    var receipt: DurableAcceptanceReceipt?
    /// `true` once the original has been deleted under a persisted receipt. The
    /// envelope and its receipt outlive the original, so a released item is
    /// still a truthful record of an accepted capture.
    var originalReleased: Bool
    /// The last named error the hub or transport reported, kept so an item
    /// waiting in `pendingLocally` can explain itself rather than looking idle.
    var lastErrorCode: String?
    var lastAttemptAt: Date?
    /// `true` when this item arrived over the Watch relay rather than from the
    /// on-device recorder. Recorded for provenance; it changes no durability rule.
    var cameFromWatchRelay: Bool

    enum CodingKeys: String, CodingKey {
        case captureID = "capture_id"
        case contentSHA256 = "content_sha256"
        case kind
        case subkind
        case typedMetadata = "typed_metadata"
        case capturedAt = "captured_at"
        case deviceID = "device_id"
        case sessionRefs = "session_refs"
        case mediaFileName = "media_file_name"
        case state
        case receipt
        case originalReleased = "original_released"
        case lastErrorCode = "last_error_code"
        case lastAttemptAt = "last_attempt_at"
        case cameFromWatchRelay = "came_from_watch_relay"
    }

    init(
        captureID: String,
        contentSHA256: String,
        kind: TransferMediaKind,
        subkind: CaptureSubkind? = nil,
        typedMetadata: TypedCaptureMetadata = TypedCaptureMetadata(),
        capturedAt: Date,
        deviceID: String,
        sessionRefs: [String] = [],
        mediaFileName: String,
        state: TransferOutboxState = .pendingLocally,
        receipt: DurableAcceptanceReceipt? = nil,
        originalReleased: Bool = false,
        lastErrorCode: String? = nil,
        lastAttemptAt: Date? = nil,
        cameFromWatchRelay: Bool = false
    ) {
        self.captureID = CaptureIdentity.canonical(captureID)
        self.contentSHA256 = contentSHA256
        self.kind = kind
        self.subkind = subkind
        self.typedMetadata = typedMetadata
        self.capturedAt = capturedAt
        self.deviceID = deviceID
        self.sessionRefs = sessionRefs
        self.mediaFileName = mediaFileName
        self.state = state
        self.receipt = receipt
        self.originalReleased = originalReleased
        self.lastErrorCode = lastErrorCode
        self.lastAttemptAt = lastAttemptAt
        self.cameFromWatchRelay = cameFromWatchRelay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureID = CaptureIdentity.canonical(try container.decode(String.self, forKey: .captureID))
        contentSHA256 = try container.decode(String.self, forKey: .contentSHA256)
        kind = try container.decode(TransferMediaKind.self, forKey: .kind)
        subkind = try container.decodeIfPresent(CaptureSubkind.self, forKey: .subkind)
        typedMetadata = try container.decodeIfPresent(TypedCaptureMetadata.self, forKey: .typedMetadata)
            ?? TypedCaptureMetadata()
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        sessionRefs = try container.decodeIfPresent([String].self, forKey: .sessionRefs) ?? []
        mediaFileName = try container.decode(String.self, forKey: .mediaFileName)
        state = try container.decode(TransferOutboxState.self, forKey: .state)
        receipt = try container.decodeIfPresent(DurableAcceptanceReceipt.self, forKey: .receipt)
        originalReleased = try container.decodeIfPresent(Bool.self, forKey: .originalReleased) ?? false
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        cameFromWatchRelay = try container.decodeIfPresent(Bool.self, forKey: .cameFromWatchRelay) ?? false
    }

    /// The single predicate that authorizes deleting an original.
    ///
    /// Every clause matters: the state must be the received state, the receipt
    /// must actually be on disk (not merely implied by the state), and the
    /// original must not already have been released.
    var isEligibleForRelease: Bool {
        state == .backendDurablyReceived && receipt != nil && !originalReleased
    }
}

/// One outbox item as read back from disk: its envelope plus the resolved
/// location of the original it is holding custody of.
struct TransferOutboxItem: Equatable {
    let envelope: TransferOutboxEnvelope
    /// Directory owned exclusively by this item.
    let directoryURL: URL

    var captureID: String { envelope.captureID }
    var mediaURL: URL { directoryURL.appendingPathComponent(envelope.mediaFileName) }
}
