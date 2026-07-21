import Combine
import Foundation

enum WatchHapticEvent: Equatable {
    case recordStarted
    case pausedForInterruption
    case resumedAfterInterruption
    case stoppedAndFinalized
    case captureFailed
    case relayFailed
}

protocol WatchHapticPlaying {
    func play(_ event: WatchHapticEvent)
}

@MainActor
final class WatchCaptureSessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
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
    func beginStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }

    func confirmStart() {
        guard phase == .starting else { return }
        phase = .recording
        haptics.play(.recordStarted)
    }

    func failStart() {
        guard phase == .starting else { return }
        phase = .idle
        haptics.play(.captureFailed)
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
    func beginFinalization() -> Bool {
        guard phase == .recording || phase == .paused else { return false }
        phase = .finalizing
        return true
    }

    func completeFinalization(queuedRelayCount: Int, succeeded: Bool) {
        guard phase == .finalizing else { return }
        phase = .idle
        self.queuedRelayCount = queuedRelayCount
        haptics.play(succeeded ? .stoppedAndFinalized : .captureFailed)
    }

    func updateQueuedRelayCount(_ count: Int) {
        queuedRelayCount = count
    }

    func recordRelayFailure() {
        haptics.play(.relayFailed)
    }

    var isActivelyRecording: Bool { phase == .recording }
}
