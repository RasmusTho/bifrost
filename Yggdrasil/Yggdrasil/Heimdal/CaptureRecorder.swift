import AVFoundation
import Combine
import Foundation
import UIKit

enum CaptureFileWriterFailure: LocalizedError, Equatable, Sendable {
    case couldNotStart
    case incompleteFile
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Heimdal could not start recording."
        case .incompleteFile:
            "Heimdal could not finish the recording safely."
        case let .encodingFailed(description):
            "Heimdal could not encode the recording: \(description)"
        }
    }
}

struct CaptureFileWriterTerminalEvent: Sendable {
    let generation: UInt64
    let result: Result<TimeInterval, CaptureFileWriterFailure>
}

@MainActor
protocol CaptureFileWriting: AnyObject {
    func start(
        url: URL,
        generation: UInt64,
        onTerminal: @escaping @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void
    ) throws
    func pause()
    func resume() throws
    func stop(generation: UInt64) throws
    func forceTerminate(generation: UInt64) throws
}

@MainActor
final class AVFoundationCaptureFileWriter: NSObject, CaptureFileWriting {
    private var recorder: AVAudioRecorder?
    private var delegateProxy: AudioRecorderDelegateProxy?
    private var terminalContinuation: AsyncStream<AudioRecorderTerminalSignal>.Continuation?
    private var terminalConsumer: Task<Void, Never>?
    private var terminalHandler: (@MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void)?
    private var activeGeneration: UInt64?
    private var durationAtStop: TimeInterval = 0
    private var deliveredTerminalEvent = false

    func start(
        url: URL,
        generation: UInt64,
        onTerminal: @escaping @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void
    ) throws {
        guard recorder == nil, activeGeneration == nil else {
            throw CaptureFileWriterFailure.couldNotStart
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        let (signals, continuation) = AsyncStream.makeStream(of: AudioRecorderTerminalSignal.self)
        terminalContinuation = continuation
        terminalHandler = onTerminal
        activeGeneration = generation
        deliveredTerminalEvent = false
        durationAtStop = 0

        delegateProxy = AudioRecorderDelegateProxy { signal in
            continuation.yield(signal)
        }
        newRecorder.delegate = delegateProxy
        recorder = newRecorder
        terminalConsumer = Task { @MainActor [weak self] in
            for await signal in signals {
                guard let self else { return }
                self.accept(signal, generation: generation)
            }
        }

        guard newRecorder.record() else {
            disposeRecorder()
            throw CaptureFileWriterFailure.couldNotStart
        }
    }

    func pause() {
        recorder?.pause()
    }

    func resume() throws {
        guard recorder?.record() == true else {
            throw CaptureFileWriterFailure.couldNotStart
        }
    }

    func stop(generation: UInt64) throws {
        guard generation == activeGeneration, let recorder else {
            throw CaptureFileWriterFailure.incompleteFile
        }
        durationAtStop = recorder.currentTime
        recorder.stop()
    }

    func forceTerminate(generation: UInt64) throws {
        guard generation == activeGeneration, let recorder else {
            throw CaptureFileWriterFailure.incompleteFile
        }

        // Media-service loss/reset may suppress the delegate callback entirely. Stop and
        // dispose the invalid recorder, then inject a terminal signal through the same
        // ordered stream used by delegate callbacks. If an encode error was already
        // enqueued, FIFO ordering makes that earlier failure win.
        let duration = recorder.currentTime
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        delegateProxy = nil
        terminalContinuation?.yield(.forcedCompletion(duration))
    }

    private func accept(_ signal: AudioRecorderTerminalSignal, generation: UInt64) {
        guard generation == activeGeneration, !deliveredTerminalEvent else { return }
        deliveredTerminalEvent = true

        let result: Result<TimeInterval, CaptureFileWriterFailure>
        switch signal {
        case let .delegateCompletion(successfully):
            result = successfully ? .success(durationAtStop) : .failure(.incompleteFile)
        case let .encodingFailure(description):
            result = .failure(.encodingFailed(description))
        case let .forcedCompletion(duration):
            result = .success(duration)
        }

        let handler = terminalHandler
        disposeRecorder()
        handler?(CaptureFileWriterTerminalEvent(generation: generation, result: result))
    }

    private func disposeRecorder() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        delegateProxy = nil
        activeGeneration = nil
        terminalHandler = nil
        terminalContinuation?.finish()
        terminalContinuation = nil
        terminalConsumer = nil
    }
}

private enum AudioRecorderTerminalSignal: Sendable {
    case delegateCompletion(Bool)
    case encodingFailure(String)
    case forcedCompletion(TimeInterval)
}

private final class AudioRecorderDelegateProxy: NSObject, AVAudioRecorderDelegate {
    private let onTerminal: @Sendable (AudioRecorderTerminalSignal) -> Void

    init(onTerminal: @escaping @Sendable (AudioRecorderTerminalSignal) -> Void) {
        self.onTerminal = onTerminal
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onTerminal(.delegateCompletion(flag))
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Swift.Error?) {
        onTerminal(.encodingFailure(error?.localizedDescription ?? "Unknown encoder failure"))
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

    private func pause(captureGeneration: UInt64) {
        guard captureGeneration == activeCapture?.generation,
              sessionModel.phase == .recording else { return }
        writer.pause()
        _ = sessionModel.transition(to: .paused)
    }

    private func resume(captureGeneration: UInt64) {
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

    private func handleInterruption(
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

    private func finalizeCurrentSegment(
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

    private func handleWriterTerminal(_ event: CaptureFileWriterTerminalEvent) {
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

    private func failTerminalCapture(_ error: Swift.Error) {
        _ = sessionModel.failCurrentItem()
        lastError = error.localizedDescription
        finishTerminalCleanup()
    }

    private func finishTerminalCleanup() {
        clearActiveCapture()
        needsManualResume = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func clearActiveCapture() {
        activeCapture = nil
        activeCaptureGeneration = nil
        finalizationGeneration = nil
        forcedTerminationGeneration = nil
        removeSessionObservers()
    }

    private func installSessionObservers(for captureGeneration: UInt64) {
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

    private func observeFinalizingNotification(
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

    private func removeSessionObservers() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers.removeAll()
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
