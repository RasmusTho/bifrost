import AVFoundation
import Foundation

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
