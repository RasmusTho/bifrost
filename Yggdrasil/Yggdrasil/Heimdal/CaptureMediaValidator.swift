import AVFoundation
import Foundation

struct ValidatedCaptureMedia: Equatable {
    let duration: TimeInterval
}

enum CaptureMediaValidationFailure: LocalizedError, Equatable {
    case invalidOrUnverifiableMedia

    var errorDescription: String? {
        "Heimdal could not verify the recording as complete, decodable audio."
    }
}

protocol CaptureMediaValidating {
    func validate(url: URL) -> Result<ValidatedCaptureMedia, CaptureMediaValidationFailure>
}

/// Production completeness gate shared by phone capture, Watch custody, and phone relay ingress.
struct AVFoundationCaptureMediaValidator: CaptureMediaValidating {
    func validate(url: URL) -> Result<ValidatedCaptureMedia, CaptureMediaValidationFailure> {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let readableFrames = min(audioFile.length, AVAudioFramePosition(4_096))
            guard readableFrames > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: audioFile.processingFormat,
                      frameCapacity: AVAudioFrameCount(readableFrames)) else {
                return .failure(.invalidOrUnverifiableMedia)
            }

            try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(readableFrames))
            guard buffer.frameLength > 0 else { return .failure(.invalidOrUnverifiableMedia) }

            if audioFile.length > readableFrames {
                audioFile.framePosition = audioFile.length - readableFrames
                guard let tailBuffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: AVAudioFrameCount(readableFrames)) else {
                    return .failure(.invalidOrUnverifiableMedia)
                }
                try audioFile.read(into: tailBuffer, frameCount: AVAudioFrameCount(readableFrames))
                guard tailBuffer.frameLength > 0 else { return .failure(.invalidOrUnverifiableMedia) }
            }

            let sampleRate = audioFile.processingFormat.sampleRate
            let duration = Double(audioFile.length) / sampleRate
            guard sampleRate.isFinite, sampleRate > 0, duration.isFinite, duration > 0 else {
                return .failure(.invalidOrUnverifiableMedia)
            }
            return .success(ValidatedCaptureMedia(duration: duration))
        } catch {
            return .failure(.invalidOrUnverifiableMedia)
        }
    }
}
