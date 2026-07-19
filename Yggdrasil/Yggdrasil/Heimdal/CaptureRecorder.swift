import AVFoundation
import Combine
import Foundation
import UIKit

protocol CaptureFileWriting: AnyObject {
    var duration: TimeInterval { get }
    func start(url: URL) throws
    func pause()
    func resume() throws
    func stop() throws
}

final class AVFoundationCaptureFileWriter: NSObject, CaptureFileWriting {
    private var recorder: AVAudioRecorder?

    var duration: TimeInterval { recorder?.currentTime ?? 0 }

    func start(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder?.record() == true else { throw CaptureRecorder.Error.couldNotStart }
    }

    func pause() { recorder?.pause() }

    func resume() throws {
        guard recorder?.record() == true else { throw CaptureRecorder.Error.couldNotStart }
    }

    func stop() throws { recorder?.stop() }
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
        sessionModel: CaptureSessionModel = CaptureSessionModel(),
        writer: CaptureFileWriting = AVFoundationCaptureFileWriter(),
        stagingDirectory: URL? = nil,
        deviceShortID: String = UIDevice.current.identifierForVendor?
            .uuidString.prefix(8).lowercased() ?? "device",
        configuration: Configuration = .production,
        observeInterruptions: Bool = true
    ) {
        self.sessionModel = sessionModel
        self.writer = writer
        self.stagingDirectory = stagingDirectory ?? Self.defaultStagingDirectory()
        self.deviceShortID = deviceShortID
        self.configuration = configuration
        if observeInterruptions {
            sessionObservers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in self?.handleInterruption(notification) }
            })
            sessionObservers.append(NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.abandon() }
            })
        }
    }

    deinit { sessionObservers.forEach(NotificationCenter.default.removeObserver) }

    func requestMicrophonePermissionAndStart() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.start()
                } else {
                    self.lastError = "Microphone access is needed to record your own spoken thoughts."
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

    func stop() { finalizeCurrentSegment() }

    func abandon() { finalizeCurrentSegment() }

    func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began: pause()
        case .ended:
            if shouldResume { resume() } else { needsManualResume = true }
        @unknown default: abandon()
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        let options = rawOptions.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        handleInterruption(type: type, shouldResume: options.contains(.shouldResume))
    }

    private func finalizeCurrentSegment() {
        guard let url = activeURL,
              sessionModel.phase == .recording || sessionModel.phase == .paused else { return }
        do {
            try writer.stop()
            guard FileManager.default.fileExists(atPath: url.path),
                  (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                throw Error.incompleteFile
            }
            _ = sessionModel.transition(to: .finalizing)
            guard sessionModel.stageCurrentItem(
                url: url,
                duration: writer.duration,
                capturedAt: Date()
            ) else { throw Error.incompleteFile }
            activeURL = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch { lastError = error.localizedDescription }
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
