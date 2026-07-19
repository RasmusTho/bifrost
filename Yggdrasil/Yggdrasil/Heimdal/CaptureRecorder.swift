import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
protocol CaptureFileWriting: AnyObject {
    func start(url: URL) throws
    func pause()
    func resume() throws
    func stop() async throws -> TimeInterval
}

@MainActor
final class AVFoundationCaptureFileWriter: NSObject, CaptureFileWriting {
    private var recorder: AVAudioRecorder?
    private var delegateProxy: AudioRecorderDelegateProxy?
    private var finishContinuation: CheckedContinuation<TimeInterval, Swift.Error>?
    private var durationAtStop: TimeInterval = 0

    func start(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        let writer = self
        delegateProxy = AudioRecorderDelegateProxy { [weak writer] successfully in
            guard let writer else { return }
            Task { @MainActor [writer, successfully] in
                writer.finish(successfully: successfully)
            }
        }
        recorder?.delegate = delegateProxy
        guard recorder?.record() == true else { throw CaptureRecorder.Error.couldNotStart }
    }

    func pause() { recorder?.pause() }

    func resume() throws {
        guard recorder?.record() == true else { throw CaptureRecorder.Error.couldNotStart }
    }

    func stop() async throws -> TimeInterval {
        guard let recorder else { throw CaptureRecorder.Error.incompleteFile }
        guard finishContinuation == nil else { throw CaptureRecorder.Error.incompleteFile }
        durationAtStop = recorder.currentTime
        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            recorder.stop()
        }
    }

    private func finish(successfully: Bool, error: Swift.Error? = nil) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        recorder = nil
        delegateProxy = nil
        if successfully {
            continuation.resume(returning: durationAtStop)
        } else {
            continuation.resume(throwing: error ?? CaptureRecorder.Error.incompleteFile)
        }
    }
}

private final class AudioRecorderDelegateProxy: NSObject, AVAudioRecorderDelegate {
    private let onFinish: @Sendable (Bool) -> Void

    init(onFinish: @escaping @Sendable (Bool) -> Void) {
        self.onFinish = onFinish
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onFinish(flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Swift.Error?) {
        onFinish(false)
    }
}

@MainActor
final class CaptureRecorder: ObservableObject {
    enum Error: LocalizedError {
        case couldNotStart
        case incompleteFile

        var errorDescription: String? {
            switch self {
            case .couldNotStart: "Heimdal could not start recording."
            case .incompleteFile: "Heimdal could not finish the recording safely."
            }
        }
    }

    struct Configuration {
        let audioBackgroundModeEnabled: Bool
        let microphonePrePrompt: String

        static let production = Configuration(
            audioBackgroundModeEnabled: true,
            microphonePrePrompt: "Heimdal records your own spoken thoughts into a local file. "
                + "It does not transcribe or share audio."
        )
    }

    let sessionModel: CaptureSessionModel
    let configuration: Configuration
    @Published private(set) var lastError: String?
    @Published private(set) var needsManualResume = false

    private let writer: CaptureFileWriting
    private let stagingDirectory: URL
    private let deviceShortID: String
    private var activeURL: URL?
    private var sessionObservers: [NSObjectProtocol] = []

    init(
        sessionModel: CaptureSessionModel? = nil,
        writer: CaptureFileWriting? = nil,
        stagingDirectory: URL? = nil,
        deviceShortID: String? = nil,
        configuration: Configuration = .production,
        observeInterruptions: Bool = true
    ) {
        self.sessionModel = sessionModel ?? CaptureSessionModel()
        self.writer = writer ?? AVFoundationCaptureFileWriter()
        self.stagingDirectory = stagingDirectory ?? Self.defaultStagingDirectory()
        self.deviceShortID = deviceShortID ?? UIDevice.current.identifierForVendor?
            .uuidString.prefix(8).lowercased() ?? "device"
        self.configuration = configuration
        if observeInterruptions {
            sessionObservers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let recorder = self else { return }
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                Task { @MainActor [recorder, rawType, rawOptions] in
                    await recorder.handleInterruption(rawType: rawType, rawOptions: rawOptions)
                }
            })
            observeFinalizingNotification(AVAudioSession.routeChangeNotification)
            observeFinalizingNotification(AVAudioSession.mediaServicesWereLostNotification)
            observeFinalizingNotification(AVAudioSession.mediaServicesWereResetNotification)
        }
    }

    deinit { sessionObservers.forEach(NotificationCenter.default.removeObserver) }

    func requestMicrophonePermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard let recorder = self else { return }
            Task { @MainActor [recorder, granted] in
                if granted {
                    recorder.start()
                } else {
                    recorder.lastError = "Microphone access is needed to record your own spoken thoughts."
                }
            }
        }
    }

    func start() {
        guard sessionModel.phase == .idle || sessionModel.phase == .staged else { return }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let url = nextFileURL()
            try writer.start(url: url)
            activeURL = url
            lastError = nil
            _ = sessionModel.transition(to: .recording)
        } catch { lastError = error.localizedDescription }
    }

    func pause() {
        guard sessionModel.phase == .recording else { return }
        writer.pause()
        _ = sessionModel.transition(to: .paused)
    }

    func resume() {
        guard sessionModel.phase == .paused else { return }
        do {
            try writer.resume()
            needsManualResume = false
            _ = sessionModel.transition(to: .recording)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() async { await finalizeCurrentSegment() }

    func abandon() async { await finalizeCurrentSegment() }

    func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) async {
        switch type {
        case .began: pause()
        case .ended:
            if shouldResume { resume() } else { needsManualResume = true }
        @unknown default: await abandon()
        }
    }

    func handleRouteChangeOrSessionFailure() async {
        await abandon()
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt?) async {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        let options = rawOptions.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        await handleInterruption(type: type, shouldResume: options.contains(.shouldResume))
    }

    private func finalizeCurrentSegment() async {
        guard let url = activeURL,
              sessionModel.phase == .recording || sessionModel.phase == .paused else { return }
        do {
            _ = sessionModel.transition(to: .finalizing)
            let duration = try await writer.stop()
            guard FileManager.default.fileExists(atPath: url.path),
                  (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                throw Error.incompleteFile
            }
            guard sessionModel.stageCurrentItem(
                url: url,
                duration: duration,
                capturedAt: Date()
            ) else { throw Error.incompleteFile }
            activeURL = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch { lastError = error.localizedDescription }
    }

    private func observeFinalizingNotification(_ name: Notification.Name) {
        sessionObservers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let recorder = self else { return }
            Task { @MainActor [recorder] in
                await recorder.handleRouteChangeOrSessionFailure()
            }
        })
    }

    private func nextFileURL() -> URL {
        let stamp = Self.filenameDateFormatter.string(from: Date())
        let sequence = UUID().uuidString.prefix(8).lowercased()
        return stagingDirectory.appendingPathComponent("heimdal-\(deviceShortID)-\(stamp)-\(sequence).m4a")
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func defaultStagingDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heimdal/Staging", isDirectory: true)
    }
}
