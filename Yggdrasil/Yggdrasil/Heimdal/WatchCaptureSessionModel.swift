import Combine
import Foundation

enum WatchHapticEvent: Equatable {
    case recordStarted
    case pausedForInterruption
    case resumedAfterInterruption
    case stoppedAndFinalized
    case relayFailed
}

protocol WatchHapticPlaying {
    func play(_ event: WatchHapticEvent)
}

@MainActor
final class WatchCaptureSessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case finalizing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var queuedRelayCount = 0

    private let haptics: WatchHapticPlaying

    init(haptics: WatchHapticPlaying) {
        self.haptics = haptics
    }

    @discardableResult
    func start() -> Bool {
        guard phase == .idle else { return false }
        phase = .recording
        haptics.play(.recordStarted)
        return true
    }

    @discardableResult
    func pauseForInterruption() -> Bool {
        guard phase == .recording else { return false }
        phase = .paused
        haptics.play(.pausedForInterruption)
        return true
    }

    @discardableResult
    func resumeAfterInterruption() -> Bool {
        guard phase == .paused else { return false }
        phase = .recording
        haptics.play(.resumedAfterInterruption)
        return true
    }

    @discardableResult
    func finalize() -> Bool {
        guard phase == .recording || phase == .paused else { return false }
        phase = .finalizing
        haptics.play(.stoppedAndFinalized)
        return true
    }

    func completeFinalization(queuedRelayCount: Int) {
        phase = .idle
        self.queuedRelayCount = queuedRelayCount
    }

    func updateQueuedRelayCount(_ count: Int) {
        queuedRelayCount = count
    }

    func recordRelayFailure() {
        haptics.play(.relayFailed)
    }
}
