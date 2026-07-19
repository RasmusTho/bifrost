import AVFoundation
import Combine
import Foundation
import UIKit

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

    private struct ActiveCapture {
        let generation: UInt64
        let url: URL
    }

    private enum FinalizationMode {
        case delegateCompletion
        case forcedCompletion
    }

    let sessionModel: CaptureSessionModel
    let configuration: Configuration
    @Published private(set) var lastError: String?
    @Published private(set) var needsManualResume = false
    private(set) var activeCaptureGeneration: UInt64?

    private let writer: CaptureFileWriting
    private let stagingDirectory: URL
    private let deviceShortID: String
    private let observeSessionNotifications: Bool
    private var activeCapture: ActiveCapture?
    private var nextCaptureGeneration: UInt64 = 0
    private var finalizationGeneration: UInt64?
    private var forcedTerminationGeneration: UInt64?
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
        observeSessionNotifications = observeInterruptions
    }

    deinit {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
    }

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
        guard sessionModel.phase == .idle
                || sessionModel.phase == .staged
                || sessionModel.phase == .failed else { return }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)

            nextCaptureGeneration &+= 1
            let generation = nextCaptureGeneration
            let url = nextFileURL()
            try writer.start(url: url, generation: generation) { [weak self] event in
                self?.handleWriterTerminal(event)
            }

            activeCapture = ActiveCapture(generation: generation, url: url)
            activeCaptureGeneration = generation
            lastError = nil
            needsManualResume = false
            _ = sessionModel.transition(to: .recording)
            installSessionObservers(for: generation)
        } catch {
            clearActiveCapture()
            lastError = error.localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func pause() {
        guard let generation = activeCapture?.generation else { return }
        pause(captureGeneration: generation)
    }

    func resume() {
        guard let generation = activeCapture?.generation else { return }
        resume(captureGeneration: generation)
    }

    func stop() async {
        // An interrupted recorder may never deliver its normal finish delegate callback.
        // Explicit stop while paused therefore uses the deterministic forced terminal path.
        let mode: FinalizationMode = sessionModel.phase == .paused
            ? .forcedCompletion
            : .delegateCompletion
        finalizeCurrentSegment(mode: mode)
    }

    func abandon() async {
        finalizeCurrentSegment(mode: .forcedCompletion)
    }

    func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) async {
        guard let generation = activeCapture?.generation else { return }
        await handleInterruption(
            type: type,
            shouldResume: shouldResume,
            captureGeneration: generation
        )
    }

    func handleInterruption(
        type: AVAudioSession.InterruptionType,
        shouldResume: Bool,
        captureGeneration: UInt64
    ) async {
        guard captureGeneration == activeCapture?.generation else { return }
        switch type {
        case .began:
            pause(captureGeneration: captureGeneration)
        case .ended:
            guard sessionModel.phase == .paused else { return }
            if shouldResume {
                resume(captureGeneration: captureGeneration)
            } else {
                needsManualResume = true
            }
        @unknown default:
            finalizeCurrentSegment(mode: .forcedCompletion, captureGeneration: captureGeneration)
        }
    }

    func handleRouteChangeOrSessionFailure() async {
        guard let generation = activeCapture?.generation else { return }
        handleRouteChangeOrSessionFailure(captureGeneration: generation)
    }

    func handleRouteChangeOrSessionFailure(captureGeneration: UInt64) {
        guard captureGeneration == activeCapture?.generation else { return }
        finalizeCurrentSegment(mode: .forcedCompletion, captureGeneration: captureGeneration)
    }
}

private extension CaptureRecorder {
    func pause(captureGeneration: UInt64) {
        guard captureGeneration == activeCapture?.generation,
              sessionModel.phase == .recording else { return }
        writer.pause()
        _ = sessionModel.transition(to: .paused)
    }

    func resume(captureGeneration: UInt64) {
        guard captureGeneration == activeCapture?.generation,
              sessionModel.phase == .paused else { return }
        do {
            try writer.resume()
            needsManualResume = false
            _ = sessionModel.transition(to: .recording)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleInterruption(
        rawType: UInt?,
        rawOptions: UInt?,
        captureGeneration: UInt64
    ) async {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        let options = rawOptions.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        await handleInterruption(
            type: type,
            shouldResume: options.contains(.shouldResume),
            captureGeneration: captureGeneration
        )
    }

    func finalizeCurrentSegment(
        mode: FinalizationMode,
        captureGeneration: UInt64? = nil
    ) {
        guard let capture = activeCapture,
              captureGeneration == nil || captureGeneration == capture.generation,
              sessionModel.phase == .recording
                || sessionModel.phase == .paused
                || sessionModel.phase == .finalizing else { return }
        if sessionModel.phase != .finalizing {
            guard sessionModel.transition(to: .finalizing) else { return }
        }

        do {
            switch mode {
            case .delegateCompletion:
                guard finalizationGeneration != capture.generation else { return }
                finalizationGeneration = capture.generation
                try writer.stop(generation: capture.generation)
            case .forcedCompletion:
                guard forcedTerminationGeneration != capture.generation else { return }
                finalizationGeneration = capture.generation
                forcedTerminationGeneration = capture.generation
                try writer.forceTerminate(generation: capture.generation)
            }
        } catch {
            handleWriterTerminal(CaptureFileWriterTerminalEvent(
                generation: capture.generation,
                result: .failure(.incompleteFile)
            ))
        }
    }

    func handleWriterTerminal(_ event: CaptureFileWriterTerminalEvent) {
        guard let capture = activeCapture,
              capture.generation == event.generation,
              sessionModel.phase == .recording
                || sessionModel.phase == .paused
                || sessionModel.phase == .finalizing else { return }

        if sessionModel.phase != .finalizing {
            guard sessionModel.transition(to: .finalizing) else { return }
        }

        switch event.result {
        case let .success(duration):
            do {
                guard FileManager.default.fileExists(atPath: capture.url.path),
                      (try capture.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                    throw Error.incompleteFile
                }
                guard sessionModel.stageCurrentItem(
                    url: capture.url,
                    duration: duration,
                    capturedAt: Date()
                ) else { throw Error.incompleteFile }
                finishTerminalCleanup()
            } catch {
                failTerminalCapture(error)
            }
        case let .failure(error):
            failTerminalCapture(error)
        }
    }

    func failTerminalCapture(_ error: Swift.Error) {
        _ = sessionModel.failCurrentItem()
        lastError = error.localizedDescription
        finishTerminalCleanup()
    }

    func finishTerminalCleanup() {
        clearActiveCapture()
        needsManualResume = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func clearActiveCapture() {
        activeCapture = nil
        activeCaptureGeneration = nil
        finalizationGeneration = nil
        forcedTerminationGeneration = nil
        removeSessionObservers()
    }

    func installSessionObservers(for captureGeneration: UInt64) {
        guard observeSessionNotifications else { return }
        removeSessionObservers()
        sessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let recorder = self else { return }
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [recorder, rawType, rawOptions, captureGeneration] in
                await recorder.handleInterruption(
                    rawType: rawType,
                    rawOptions: rawOptions,
                    captureGeneration: captureGeneration
                )
            }
        })
        observeFinalizingNotification(
            AVAudioSession.routeChangeNotification,
            captureGeneration: captureGeneration
        )
        observeFinalizingNotification(
            AVAudioSession.mediaServicesWereLostNotification,
            captureGeneration: captureGeneration
        )
        observeFinalizingNotification(
            AVAudioSession.mediaServicesWereResetNotification,
            captureGeneration: captureGeneration
        )
    }

    func observeFinalizingNotification(
        _ name: Notification.Name,
        captureGeneration: UInt64
    ) {
        sessionObservers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let recorder = self else { return }
            Task { @MainActor [recorder, captureGeneration] in
                recorder.handleRouteChangeOrSessionFailure(captureGeneration: captureGeneration)
            }
        })
    }

    func removeSessionObservers() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers.removeAll()
    }

    func nextFileURL() -> URL {
        let stamp = Self.filenameDateFormatter.string(from: Date())
        let sequence = UUID().uuidString.prefix(8).lowercased()
        return stagingDirectory.appendingPathComponent("heimdal-\(deviceShortID)-\(stamp)-\(sequence).m4a")
    }

    static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func defaultStagingDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heimdal/Staging", isDirectory: true)
    }
}
