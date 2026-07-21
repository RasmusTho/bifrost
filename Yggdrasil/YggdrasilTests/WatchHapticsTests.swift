import XCTest
@testable import Yggdrasil

@MainActor
final class WatchHapticsTests: XCTestCase {
    func testHapticPerTransition() {
        let haptics = RecordingHapticPlayer()
        let model = WatchCaptureSessionModel(haptics: haptics)

        XCTAssertTrue(model.beginStart())
        XCTAssertTrue(haptics.events.isEmpty)
        model.confirmStart()
        XCTAssertTrue(model.pauseForInterruption())
        XCTAssertFalse(model.isActivelyRecording)
        XCTAssertTrue(model.resumeAfterInterruption())
        XCTAssertTrue(model.beginFinalization())
        XCTAssertEqual(haptics.events.last, .resumedAfterInterruption)
        model.completeFinalization(queuedRelayCount: 1, succeeded: true)

        XCTAssertEqual(haptics.events, [
            .recordStarted,
            .pausedForInterruption,
            .resumedAfterInterruption,
            .stoppedAndFinalized
        ])
    }

    func testFailedStartAndFinalizationEmitFailureInsteadOfSuccess() {
        let haptics = RecordingHapticPlayer()
        let model = WatchCaptureSessionModel(haptics: haptics)

        XCTAssertTrue(model.beginStart())
        model.failStart()
        XCTAssertEqual(haptics.events, [.captureFailed])

        XCTAssertTrue(model.beginStart())
        model.confirmStart()
        XCTAssertTrue(model.beginFinalization())
        model.completeFinalization(queuedRelayCount: 0, succeeded: false)

        XCTAssertEqual(haptics.events, [.captureFailed, .recordStarted, .captureFailed])
        XCTAssertEqual(model.phase, .idle)
    }
}

private final class RecordingHapticPlayer: WatchHapticPlaying {
    private(set) var events: [WatchHapticEvent] = []
    func play(_ event: WatchHapticEvent) { events.append(event) }
}
