import Foundation
import SwiftUI

/// UI-independent capture and delivery progression. Durable custody remains on
/// disk; these states explain the current process's view of each attempt.
@MainActor
final class CaptureSessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case finalizing
        case staged
        case failed
    }

    enum DeliveryState: Equatable {
        case staged
        case delivering(startedAt: Date)
        case deliveredAwaitingSync(placedAt: Date)
        case failed(message: String, at: Date)
    }

    enum RecoveryFailureReason: Equatable {
        case invalidOrUnverifiableMedia

        var message: String {
            switch self {
            case .invalidOrUnverifiableMedia:
                "Heimdal could not verify this recording as complete audio. The original file was kept."
            }
        }
    }

    struct RecoveryFailure: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let detectedAt: Date
        let reason: RecoveryFailureReason
    }

    struct StagedItem: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let duration: TimeInterval
        let capturedAt: Date
        /// Capture-time facts travel with the staged recording so delivery does
        /// not have to infer them from a filename or filesystem timestamps.
        let recordedStartAt: Date
        let recordedEndAt: Date
        let interruptions: Int
        let deviceID: String
        let sourceSurface: CaptureSourceSurface
        /// `true` when the item was reconstructed from the local staging directory
        /// after the process was no longer able to retain its in-memory capture state.
        let wasRecoveredAfterRestart: Bool
        var deliveryState: DeliveryState
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stagedItems: [StagedItem] = []
    @Published private(set) var recoveryFailures: [RecoveryFailure] = []

    @discardableResult
    func transition(to next: Phase) -> Bool {
        guard isValidTransition(from: phase, to: next) else { return false }
        phase = next
        return true
    }

    @discardableResult
    func stageCurrentItem(
        id: UUID = UUID(),
        url: URL = URL(fileURLWithPath: "/dev/null"),
        duration: TimeInterval = 0,
        capturedAt: Date = Date(),
        recordedStartAt: Date? = nil,
        recordedEndAt: Date? = nil,
        interruptions: Int = 0,
        deviceID: String = "device",
        sourceSurface: CaptureSourceSurface = .iphoneApp,
        wasRecoveredAfterRestart: Bool = false
    ) -> Bool {
        guard phase == .finalizing else { return false }
        stagedItems.append(StagedItem(
            id: id,
            url: url,
            duration: duration,
            capturedAt: capturedAt,
            recordedStartAt: recordedStartAt ?? capturedAt,
            recordedEndAt: recordedEndAt ?? capturedAt,
            interruptions: interruptions,
            deviceID: deviceID,
            sourceSurface: sourceSurface,
            wasRecoveredAfterRestart: wasRecoveredAfterRestart,
            deliveryState: .staged
        ))
        phase = .staged
        return true
    }

    @discardableResult
    func updateDeliveryState(for id: UUID, to state: DeliveryState) -> Bool {
        guard let index = stagedItems.firstIndex(where: { $0.id == id }) else { return false }
        stagedItems[index].deliveryState = state
        return true
    }

    @discardableResult
    func failCurrentItem() -> Bool {
        guard phase == .finalizing else { return false }
        phase = .failed
        return true
    }

    /// Rebuilds the durable staged list after a launch. Recovery intentionally uses
    /// the same pending-delivery state as an ordinary finalized capture: it has not
    /// yet been placed in the watched folder and must remain accountable locally.
    func recoverStagedItem(
        id: UUID = UUID(),
        url: URL,
        duration: TimeInterval,
        capturedAt: Date,
        deviceID: String = "device",
        sourceSurface: CaptureSourceSurface = .iphoneApp
    ) {
        guard !stagedItems.contains(where: { $0.url == url }) else { return }
        stagedItems.append(StagedItem(
            id: id,
            url: url,
            duration: duration,
            capturedAt: capturedAt,
            recordedStartAt: capturedAt.addingTimeInterval(-duration),
            recordedEndAt: capturedAt,
            interruptions: 0,
            deviceID: deviceID,
            sourceSurface: sourceSurface,
            wasRecoveredAfterRestart: true,
            deliveryState: .staged
        ))
        if phase == .idle {
            phase = .staged
        }
    }

    /// Preserves custody of a local file that cannot safely enter the delivery
    /// queue. The file remains untouched on disk and is surfaced separately from
    /// complete, deliverable staged audio.
    func recordRecoveryFailure(
        id: UUID = UUID(),
        url: URL,
        detectedAt: Date,
        reason: RecoveryFailureReason
    ) {
        guard !recoveryFailures.contains(where: { $0.url == url }) else { return }
        recoveryFailures.append(RecoveryFailure(
            id: id,
            url: url,
            detectedAt: detectedAt,
            reason: reason
        ))
    }

    private func isValidTransition(from current: Phase, to next: Phase) -> Bool {
        switch (current, next) {
        case (.idle, .recording),
             (.staged, .recording),
             (.failed, .recording),
             (.recording, .paused),
             (.paused, .recording),
             (.recording, .finalizing),
             (.paused, .finalizing),
             (.finalizing, .staged):
            true
        default:
            false
        }
    }
}
