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
    }

    enum DeliveryState: Equatable {
        case deliveryPending
        case delivered
        case failed
    }

    struct StagedItem: Identifiable, Equatable {
        let id: UUID
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
    func stageCurrentItem(id: UUID = UUID()) -> Bool {
        guard phase == .finalizing else { return false }
        stagedItems.append(StagedItem(id: id, deliveryState: .deliveryPending))
        phase = .staged
        return true
    }

    @discardableResult
    func updateDeliveryState(for id: UUID, to state: DeliveryState) -> Bool {
        guard let index = stagedItems.firstIndex(where: { $0.id == id }) else { return false }
        stagedItems[index].deliveryState = state
        return true
    }

    private func isValidTransition(from current: Phase, to next: Phase) -> Bool {
        switch (current, next) {
        case (.idle, .recording),
             (.recording, .paused),
             (.paused, .recording),
             (.recording, .finalizing),
             (.finalizing, .staged):
            true
        default:
            false
        }
    }
}
