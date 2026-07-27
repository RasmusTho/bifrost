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

    init(document: FrontmatterDocument) {
        deviceID = document.frontmatter["device_id"]?.stringValue
        label = document.frontmatter["label"]?.stringValue
        consentGrantRef = document.frontmatter["consent_grant_ref"]?.stringValue
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

    private func snapshot(using fileStore: VaultFileStore) async throws -> DeviceRegistrationSnapshot {
        async let consentResult = fileStore.read(HeimdalPaths.consent)
        async let deviceResult = fileStore.read(HeimdalPaths.device(id: deviceID))

        let standingGrant: ConsentGrant?
        do {
            let consent = try await consentResult
            standingGrant = ConsentNote(document: try FrontmatterDocument.parse(consent)).grants.first
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
