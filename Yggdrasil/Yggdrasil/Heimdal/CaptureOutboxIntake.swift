import Foundation

/// Which delivery lane a build uses for finalized captures.
///
/// The outbox lane is receipt-gated (CDLM-03). The legacy Model-1 watched-folder
/// writer is *not* — it deletes after placement, which is the loss window #4369
/// exposed. The two must never both own the same bytes, so on an outbox-capable
/// build the legacy writer defaults off.
struct CaptureLaneSettings: Equatable {
    /// The HCAP-03 watched-folder writer. Kept only as the explicit
    /// phoneless/legacy floor; removing it is out of scope for CDLM-03.
    ///
    /// Default `false`: while the outbox holds custody, a second lane that
    /// deletes after placement would reintroduce exactly the un-receipted
    /// deletion this slice exists to remove.
    var legacyWatchedFolderWriterEnabled: Bool

    static let outboxCapable = CaptureLaneSettings(legacyWatchedFolderWriterEnabled: false)
    /// For builds that genuinely have no hub to talk to.
    static let legacyOnly = CaptureLaneSettings(legacyWatchedFolderWriterEnabled: true)
}

/// The single intake seam through which finalized captures enter the outbox.
///
/// Both HCAP-02 (on-device recorder) and HCAP-06 (Watch relay) finalize through
/// here, which is why a relayed recording inherits every durability rule without
/// a second implementation: there is only one way in.
///
/// Intake hands *custody* of the bytes to the outbox and returns the file's new
/// location. Callers stage that returned URL rather than the old staging path, so
/// the existing staged surface keeps pointing at bytes that exist while the
/// outbox alone controls their deletion.
@MainActor
struct CaptureOutboxIntake {
    private let store: TransferOutboxStore
    private let deviceID: String

    init(store: TransferOutboxStore, deviceID: String) {
        self.store = store
        self.deviceID = deviceID
    }

    /// Takes custody of a finalized original, minting its capture identity.
    ///
    /// Returns the original's new URL inside the outbox, or `nil` when custody
    /// could not be taken — in which case the caller keeps the file exactly where
    /// it is. Failing to enter the outbox must never mean losing the capture.
    func takeCustody(
        ofFinalized mediaURL: URL,
        capturedAt: Date,
        sessionRefs: [String] = [],
        cameFromWatchRelay: Bool = false
    ) -> URL? {
        do {
            let item = try store.enqueue(
                finalizedMediaURL: mediaURL,
                kind: .audio,
                capturedAt: capturedAt,
                deviceID: deviceID,
                sessionRefs: sessionRefs,
                cameFromWatchRelay: cameFromWatchRelay
            )
            return item.mediaURL
        } catch {
            return nil
        }
    }
}
