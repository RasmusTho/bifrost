import Combine
import Foundation
import YggdrasilCore

/// Read-only facts presented by the capture-side consent and registration
/// surface. A missing grant is represented by `nil`, never by a placeholder.
struct DeviceRegistrationSnapshot {
    let deviceID: String
    let deviceLabel: String
    let standingGrant: ConsentGrant?
    let deviceNote: DeviceNote?

    var isRegistered: Bool { deviceNote != nil }
}

struct DeviceNote: Equatable {
    let deviceID: String?
    let label: String?
    let consentGrantRef: String?
    /// Observation-only readout of `capture_gap_log`'s length, so the
    /// already-shipped gap-log write is visible from the UI without exposing or
    /// altering the log's contents.
    let gapLogCount: Int

    init(document: FrontmatterDocument) {
        deviceID = document.frontmatter["device_id"]?.stringValue
        label = document.frontmatter["label"]?.stringValue
        consentGrantRef = document.frontmatter["consent_grant_ref"]?.stringValue
        gapLogCount = document.frontmatter["capture_gap_log"]?.arrayValue?.count ?? 0
    }
}

/// The only B3 registration writer. It creates this phone's device note using
/// the existing coordinated, provenance-tagged store and never edits consent.
@MainActor
final class DeviceRegistrationModel: ObservableObject {
    enum State {
        case unavailable
        case loading
        case loaded(DeviceRegistrationSnapshot)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    private let fileStore: VaultFileStore?
    private let deviceID: String
    private let deviceLabel: String

    init(fileStore: VaultFileStore?, deviceID: String, deviceLabel: String) {
        self.fileStore = fileStore
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
    }

    func load() async {
        guard let fileStore else {
            state = .unavailable
            return
        }
        state = .loading
        do {
            state = .loaded(try await snapshot(using: fileStore))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Registers only when the device note is absent. A concurrent creator is
    /// handled as a field-preserving merge by `readModifyWrite`; this code
    /// never replaces an existing note wholesale.
    func register() async {
        guard let fileStore else {
            state = .unavailable
            return
        }

        do {
            let before = try await snapshot(using: fileStore)
            guard !before.isRegistered else {
                state = .loaded(before)
                return
            }

            let grantRef = before.standingGrant?.grantRef
            let path = HeimdalPaths.device(id: deviceID)
            let registrationDeviceID = deviceID
            let registrationDeviceLabel = deviceLabel
            try await fileStore.readModifyWrite(path) { document in
                // A note appearing after the initial read may contain human or
                // hub-owned fields. Preserve each one and fill only the durable
                // identity fields this client owns.
                if document.frontmatter["device_id"] == nil {
                    document.frontmatter["device_id"] = .string(registrationDeviceID)
                }
                if document.frontmatter["label"] == nil {
                    document.frontmatter["label"] = .string(registrationDeviceLabel)
                }
                if document.frontmatter["consent_grant_ref"] == nil, let grantRef {
                    document.frontmatter["consent_grant_ref"] = .string(grantRef)
                }
            }
            state = .loaded(try await snapshot(using: fileStore))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Nameable capture gaps (ADR-0049 §2's durable half of the device-health
    /// bend). Raw strings, not an enum, so the vault-side `kind` spelling is
    /// exactly what this file writes and what a future consumer greps for.
    enum GapKind {
        static let interruptedNotResumed = "interrupted_not_resumed"
        static let finalizedByAbandonment = "finalized_by_abandonment"
        static let deliveryFailedAged = "delivery_failed_aged"
    }

    /// Appends one entry to this device note's `capture_gap_log` when the
    /// client can name a gap. Idempotent on `(kind, detail)`: a caller that
    /// observes and reports the same gap more than once (a retried scan, a
    /// second scenePhase activation before the first write lands) still
    /// produces exactly one entry, never a duplicate. Uses the same
    /// coordinated `readModifyWrite` seam as `register()`, so an unrelated
    /// concurrent writer's fields are preserved untouched.
    func recordGapEvent(kind: String, detail: String, at: Date = Date()) async {
        guard let fileStore else { return }
        let path = HeimdalPaths.device(id: deviceID)
        let timestamp = ISO8601DateFormatter().string(from: at)
        do {
            try await fileStore.readModifyWrite(path) { document in
                var entries = document.frontmatter["capture_gap_log"]?.arrayValue ?? []
                let alreadyRecorded = entries.contains { entry in
                    guard let fields = entry.mapValue else { return false }
                    return fields["kind"]?.stringValue == kind && fields["detail"]?.stringValue == detail
                }
                guard !alreadyRecorded else { return }
                entries.append(.map(YAMLMap([
                    ("at", .string(timestamp)),
                    ("kind", .string(kind)),
                    ("detail", .string(detail))
                ])))
                document.frontmatter["capture_gap_log"] = .array(entries)
            }
        } catch {
            // Best-effort by design: a failed gap write is a device-health
            // detail, not a reason to disrupt the capture flow reporting it.
        }
    }

    /// A coarse, low-churn health readout for `last_known_snapshot`. `battery`
    /// is `nil` when the level is not currently known.
    struct LastKnownSnapshot: Equatable {
        let battery: Double?
        let queueDepth: Int
        let recording: Bool
    }

    /// Updates `last_known_snapshot` in place: on entering background, and at
    /// most every few minutes while active — never on a tight timer. Skips
    /// the write entirely when the snapshot is unchanged from what the device
    /// note already holds, and never touches any field but
    /// `last_known_snapshot`.
    func updateLastKnownSnapshot(_ snapshot: LastKnownSnapshot, at: Date = Date()) async {
        guard let fileStore else { return }
        let path = HeimdalPaths.device(id: deviceID)
        guard let currentText = try? await fileStore.read(path),
              let currentDocument = try? FrontmatterDocument.parse(currentText) else {
            // No device note yet (not registered): nothing durable to update.
            return
        }
        if let existing = currentDocument.frontmatter["last_known_snapshot"]?.mapValue,
           existing["battery"]?.doubleValue == snapshot.battery,
           existing["queue_depth"]?.intValue == snapshot.queueDepth,
           existing["recording"]?.boolValue == snapshot.recording {
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: at)
        do {
            try await fileStore.readModifyWrite(path) { document in
                var fields: [(String, YAMLValue)] = [("at", .string(timestamp))]
                if let battery = snapshot.battery {
                    fields.append(("battery", .double(battery)))
                } else {
                    fields.append(("battery", .null))
                }
                fields.append(("queue_depth", .int(snapshot.queueDepth)))
                fields.append(("recording", .bool(snapshot.recording)))
                document.frontmatter["last_known_snapshot"] = .map(YAMLMap(fields))
            }
        } catch {
            // Best-effort: a missed coarse snapshot costs at most one stale
            // reading, never a lost gap-log entry.
        }
    }

    private func snapshot(using fileStore: VaultFileStore) async throws -> DeviceRegistrationSnapshot {
        async let consentResult = fileStore.read(HeimdalPaths.consent)
        async let deviceResult = fileStore.read(HeimdalPaths.device(id: deviceID))

        let standingGrant: ConsentGrant?
        do {
            let consent = try await consentResult
            // Not `grants.first`: the mirror is an oldest-first snapshot of the
            // hub ledger, so the leading row can be an unrelated, expired, or
            // revoked grant. `standingSelfRecordGrant` re-applies the ledger's
            // activity rule, and yields nil rather than a mis-attributed ref.
            standingGrant = ConsentNote(document: try FrontmatterDocument.parse(consent))
                .standingSelfRecordGrant()
        } catch VaultFileStoreError.notFound(_) {
            standingGrant = nil
        }

        let deviceNote: DeviceNote?
        do {
            let device = try await deviceResult
            deviceNote = DeviceNote(document: try FrontmatterDocument.parse(device))
        } catch VaultFileStoreError.notFound(_) {
            deviceNote = nil
        }

        return DeviceRegistrationSnapshot(
            deviceID: deviceID,
            deviceLabel: deviceLabel,
            standingGrant: standingGrant,
            deviceNote: deviceNote
        )
    }
}
