import AVFoundation
import Combine
import Foundation
import WatchKit

final class WatchKitHapticPlayer: WatchHapticPlaying {
    func play(_ event: WatchHapticEvent) {
        let haptic: WKHapticType
        switch event {
        case .recordStarted: haptic = .start
        case .pausedForInterruption: haptic = .retry
        case .resumedAfterInterruption: haptic = .success
        case .stoppedAndFinalized: haptic = .stop
        case .captureFailed: haptic = .failure
        case .relayFailed: haptic = .failure
        }
        WKInterfaceDevice.current().play(haptic)
    }
}

@MainActor
final class WatchCaptureRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var lastError: String?

    private let model: WatchCaptureSessionModel
    private let custody: WatchRelayCustody
    private let relay: WatchConnectivityRelayTransport
    private let fileManager: FileManager
    private let metadataStore: WatchRelayMetadataStore
    private let now: () -> Date
    private let timeZoneProvider: () -> TimeZone
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    private var captureTimezone: String?
    private var interruptionCount = 0
    private var interruptionObserver: NSObjectProtocol?

    init(
        model: WatchCaptureSessionModel,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        timeZoneProvider: @escaping () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.model = model
        self.fileManager = fileManager
        self.now = now
        self.timeZoneProvider = timeZoneProvider
        metadataStore = WatchRelayMetadataStore(fileManager: fileManager)
        custody = WatchRelayCustody(fileManager: fileManager)
        relay = WatchConnectivityRelayTransport()
        super.init()
        relay.completion = { [weak self] transfer, error in
            Task { @MainActor [weak self] in self?.handleRelayCompletion(transfer: transfer, error: error) }
        }
        relay.activate()
        rebuildRelayQueue()
        installInterruptionObserver()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func start() {
        guard model.beginStart() else { return }
        do {
            try fileManager.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
            let url = recordingDirectory.appendingPathComponent("watch-\(UUID().uuidString.lowercased()).m4a")
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            recorder.delegate = self
            recorder.prepareToRecord()
            guard recorder.record() else { throw WatchCaptureError.couldNotStart }
            self.recorder = recorder
            startedAt = now()
            captureTimezone = timeZoneProvider().identifier
            interruptionCount = 0
            lastError = nil
            model.confirmStart()
        } catch {
            lastError = error.localizedDescription
            model.failStart()
        }
    }

    func stop() {
        guard model.beginFinalization() else { return }
        guard let recorder else {
            lastError = "The Watch could not finalize this recording. It remains on disk for recovery."
            model.completeFinalization(queuedRelayCount: custody.queuedCount, succeeded: false)
            return
        }
        recorder.stop()
    }

    func elapsedText(at date: Date) -> String {
        let elapsed = max(0, date.timeIntervalSince(startedAt ?? date))
        return String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let fileURL = recorder.url
        let recordedStartAt = startedAt
        let timezone = captureTimezone
        let recordedEndAt = now()
        self.recorder = nil
        startedAt = nil
        captureTimezone = nil
        try? AVAudioSession.sharedInstance().setActive(false)

        guard flag else {
            lastError = "The Watch could not finalize this recording. It remains on disk for recovery."
            model.completeFinalization(queuedRelayCount: custody.queuedCount, succeeded: false)
            return
        }

        if let recordedStartAt, let timezone {
            do {
                try metadataStore.write(
                    WatchRelayCaptureMetadata(
                        recordedStartAt: recordedStartAt,
                        recordedEndAt: recordedEndAt,
                        timezone: timezone,
                        interruptions: interruptionCount
                    ),
                    for: fileURL
                )
            } catch {
                lastError = "The recording is safe, but its capture metadata could not be retained."
            }
        }
        let queued = custody.enqueue(fileURL: fileURL, using: relay)
        let finalizedMediaIsValid = !custody.invalidFiles.contains(fileURL)
        model.completeFinalization(
            queuedRelayCount: custody.queuedCount,
            succeeded: finalizedMediaIsValid
        )
        if !finalizedMediaIsValid {
            lastError = custody.lastError
        } else if !queued {
            lastError = custody.lastError
            model.recordRelayFailure()
        }
    }

    private var recordingDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchRelay", isDirectory: true)
    }

    private func rebuildRelayQueue() {
        try? fileManager.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        custody.reconcileQueue(from: recordingDirectory, using: relay)
        if !custody.invalidFiles.isEmpty { lastError = custody.lastError }
        model.updateQueuedRelayCount(custody.queuedCount)
    }

    private func handleRelayCompletion(transfer: WatchRelayTransfer, error: Error?) {
        custody.complete(transfer: transfer, error: error)
        if error != nil { model.recordRelayFailure() }
        model.updateQueuedRelayCount(custody.queuedCount)
    }

    private func installInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self, notification] in
                self?.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            recorder?.pause()
            if model.pauseForInterruption() { interruptionCount += 1 }
        case .ended:
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
               recorder?.record() == true {
                _ = model.resumeAfterInterruption()
            }
        @unknown default:
            break
        }
    }
}

private enum WatchCaptureError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "The Watch could not start recording." }
}
