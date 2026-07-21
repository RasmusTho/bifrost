import XCTest
@testable import Yggdrasil

@MainActor
final class WatchHapticsTests: XCTestCase {
    func testHapticPerTransition() {
        let haptics = RecordingHapticPlayer()
        let model = WatchCaptureSessionModel(haptics: haptics)

        XCTAssertTrue(model.start())
        XCTAssertTrue(model.pauseForInterruption())
        XCTAssertTrue(model.resumeAfterInterruption())
        XCTAssertTrue(model.finalize())

        XCTAssertEqual(haptics.events, [
            .recordStarted,
            .pausedForInterruption,
            .resumedAfterInterruption,
            .stoppedAndFinalized
        ])
    }
}

private final class RecordingHapticPlayer: WatchHapticPlaying {
    private(set) var events: [WatchHapticEvent] = []
    func play(_ event: WatchHapticEvent) { events.append(event) }
}
