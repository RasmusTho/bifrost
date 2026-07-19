import Foundation
import SwiftUI

/// UI-independent session progression. Audio capture and delivery are injected
/// by later slices; this model only protects the state contract they must use.
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
        case deliveryPending
        case delivered
        case failed
    }

    struct StagedItem: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let duration: TimeInterval
        let capturedAt: Date
        var deliveryState: DeliveryState
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stagedItems: [StagedItem] = []

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
        capturedAt: Date = Date()
    ) -> Bool {
        guard phase == .finalizing else { return false }
        stagedItems.append(StagedItem(
            id: id,
            url: url,
            duration: duration,
            capturedAt: capturedAt,
            deliveryState: .deliveryPending
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
