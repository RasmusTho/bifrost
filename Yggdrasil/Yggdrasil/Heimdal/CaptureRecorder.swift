import AVFoundation
import Combine
import Foundation

@MainActor
final class CaptureRecorder: ObservableObject {
    enum Error: LocalizedError {
        case couldNotStart
        case incompleteFile
        case recoveryFailed

        var errorDescription: String? {
            switch self {
            case .couldNotStart: "Heimdal could not start recording."
            case .incompleteFile: "Heimdal could not finish the recording safely."
            case .recoveryFailed:
                "Heimdal kept one or more recordings that could not be verified after restart."
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
    private(set) var activeCaptureGeneration: UInt64?

    private let writer: CaptureFileWriting
    private let stagingDirectory: URL
    private let deviceID: String
    private let deviceShortID: String
    private let sourceSurface: CaptureSourceSurface
    private let timeZoneProvider: @Sendable () -> TimeZone
    private let now: () -> Date
    private let observeSessionNotifications: Bool
    private let mediaValidator: CaptureMediaValidating
    private var activeCapture: ActiveCapture?
    private var nextCaptureGeneration: UInt64 = 0
    private var finalizationGeneration: UInt64?
    private var forcedTerminationGeneration: UInt64?
    private var sessionObservers: [NSObjectProtocol] = []

    init(
        sessionModel: CaptureSessionModel? = nil,
        writer: CaptureFileWriting? = nil,
        stagingDirectory: URL? = nil,
        deviceID: String? = nil,
        deviceShortID: String? = nil,
        sourceSurface: CaptureSourceSurface = .iphoneApp,
        timeZoneProvider: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent },
        now: @escaping () -> Date = Date.init,
        configuration: Configuration = .production,
        observeInterruptions: Bool = true,
        mediaValidator: CaptureMediaValidating = AVFoundationCaptureMediaValidator()
    ) {
        self.sessionModel = sessionModel ?? CaptureSessionModel()
        self.writer = writer ?? AVFoundationCaptureFileWriter()
        self.stagingDirectory = stagingDirectory ?? Self.defaultStagingDirectory()
        let stableDeviceID = deviceID ?? HeimdalDeviceIdentity().deviceID()
        self.deviceID = stableDeviceID
        self.deviceShortID = deviceShortID ?? String(stableDeviceID.prefix(8))
        self.sourceSurface = sourceSurface
        self.timeZoneProvider = timeZoneProvider
        self.now = now
        self.configuration = configuration
        observeSessionNotifications = observeInterruptions
        self.mediaValidator = mediaValidator
        reconcileStagingDirectory()
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

            activeCapture = ActiveCapture(
                generation: generation,
                url: url,
                recordedStartAt: now(),
                timezone: timeZoneProvider().identifier,
                interruptions: 0
            )
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
            activeCapture?.interruptions += 1
            if sessionModel.phase == .finalizing {
                finalizeCurrentSegment(
                    mode: .forcedCompletion,
                    captureGeneration: captureGeneration
                )
            } else {
                pause(captureGeneration: captureGeneration)
            }
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

    /// Rebuilds visible, accountable staged state after force-kill/relaunch.
    ///
    /// AVAudioRecorder writes the capture file progressively, but nonzero size does
    /// not prove that a force-killed MPEG-4 container was finalized. Only media that
    /// AVFoundation can open and decode enters the pending delivery queue. Every
    /// invalid or unverifiable `.m4a` remains untouched on disk and is surfaced as a
    /// separate recovery failure so custody is never confused with completeness.
    func reconcileStagingDirectory() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension.lowercased() == "m4a",
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .fileSizeKey,
                      .contentModificationDateKey
                  ]),
                  values.isRegularFile == true else { continue }

            let detectedAt = values.contentModificationDate ?? Date()
            switch mediaValidator.validate(url: url) {
            case let .success(media):
                sessionModel.recoverStagedItem(
                    url: url,
                    duration: media.duration,
                    capturedAt: detectedAt
                )
            case .failure:
                sessionModel.recordRecoveryFailure(
                    url: url,
                    detectedAt: detectedAt,
                    reason: .invalidOrUnverifiableMedia
                )
                lastError = Error.recoveryFailed.localizedDescription
            }
        }
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
        case .success:
            do {
                guard FileManager.default.fileExists(atPath: capture.url.path),
                      (try capture.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
                    throw Error.incompleteFile
                }
                let media = try mediaValidator.validate(url: capture.url).get()
                guard sessionModel.stageCurrentItem(
                    url: capture.url,
                    duration: media.duration,
                    capturedAt: capture.recordedStartAt,
                    captureMetadata: CaptureSessionModel.CaptureMetadata(
                        recordedStartAt: capture.recordedStartAt,
                        recordedEndAt: now(),
                        timezone: capture.timezone,
                        interruptions: capture.interruptions,
                        deviceID: deviceID,
                        sourceSurface: sourceSurface
                    )
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
        if let url = activeCapture?.url,
           FileManager.default.fileExists(atPath: url.path) {
            sessionModel.recordRecoveryFailure(
                url: url, detectedAt: Date(), reason: .invalidOrUnverifiableMedia
            )
        }
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
