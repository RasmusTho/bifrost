import Foundation

/// The device's reported charge state, mirrored from `UIDevice.batteryState`
/// without importing UIKit here so this type stays trivially testable.
enum DeviceBatteryState: Equatable {
    case unknown
    case unplugged
    case charging
    case full
}

struct DeviceBatteryStatus: Equatable {
    /// `0...1`, or `nil` when the level is not currently known (monitoring
    /// disabled, or not yet sampled).
    let level: Double?
    let state: DeviceBatteryState

    static let unknown = DeviceBatteryStatus(level: nil, state: .unknown)
}

enum MicrophonePermissionState: Equatable {
    case undetermined
    case granted
    case denied
}

/// ADR-0049 §2's declared UI-only bend, held to its letter: this type exposes
/// only runtime facts (recording/session state, delivery-queue depth and
/// oldest-pending age, battery, storage headroom, mic-permission state) and
/// holds no `VaultFileStore` reference of any kind — there is no field, no
/// initializer parameter, and no method through which this model could reach
/// the vault. That absence is what `CaptureSessionModelTests
/// .testLivePanelHasNoPersistenceSideEffects` proves against the real,
/// on-disk production `VaultFileStore` seam: driving every telemetry update
/// this model offers, against the actual `CaptureSessionModel` the app ships,
/// leaves the vault directory untouched.
///
/// The durable counterpart to this ephemeral panel is
/// `DeviceRegistrationModel.recordGapEvent` /
/// `.updateLastKnownSnapshot`, which alone may reach the device note.
@MainActor
final class DeviceHealthPanelModel: ObservableObject {
    @Published private(set) var battery: DeviceBatteryStatus
    @Published private(set) var storageHeadroomBytes: Int64
    @Published private(set) var micPermission: MicrophonePermissionState

    private let captureSession: CaptureSessionModel
    private let now: () -> Date

    init(
        captureSession: CaptureSessionModel,
        battery: DeviceBatteryStatus = .unknown,
        storageHeadroomBytes: Int64 = 0,
        micPermission: MicrophonePermissionState = .undetermined,
        now: @escaping () -> Date = Date.init
    ) {
        self.captureSession = captureSession
        self.battery = battery
        self.storageHeadroomBytes = storageHeadroomBytes
        self.micPermission = micPermission
        self.now = now
    }

    /// The HCAP-01 recording/session state, read live from the shared session
    /// model. Never cached, never written back.
    var recordingPhase: CaptureSessionModel.Phase { captureSession.phase }

    /// HCAP-03's delivery-queue depth: staged items not yet placed in the
    /// watched folder (a `.deliveredAwaitingSync` item has left the queue).
    var queueDepth: Int { pendingItems.count }

    /// The age of the oldest item still waiting on delivery, or `nil` when
    /// the queue is empty.
    var oldestPendingAge: TimeInterval? {
        pendingItems.map { now().timeIntervalSince($0.capturedAt) }.max()
    }

    private var pendingItems: [CaptureSessionModel.StagedItem] {
        captureSession.stagedItems.filter { item in
            if case .deliveredAwaitingSync = item.deliveryState { return false }
            return true
        }
    }

    func updateBattery(_ status: DeviceBatteryStatus) {
        battery = status
    }

    func updateStorageHeadroom(bytes: Int64) {
        storageHeadroomBytes = bytes
    }

    func updateMicPermission(_ state: MicrophonePermissionState) {
        micPermission = state
    }
}
