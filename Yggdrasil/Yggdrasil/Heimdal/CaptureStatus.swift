import AVFoundation
import Foundation

/// What the OS reports about the microphone, read from
/// `AVCaptureDevice.authorizationStatus(for: .audio)` and
/// `AVAudioSession.isInputAvailable`. Only iOS may change the first three; the
/// app can ask once (`undetermined`) and otherwise only explain and route.
enum MicrophoneAvailability: Equatable {
    case undetermined
    case granted
    /// The person turned microphone access off for Heimdal in Settings.
    case denied
    /// Screen Time or device management blocks the microphone; Heimdal's own
    /// Settings page cannot change it.
    case restricted
    /// Access is granted but the system reports no audio input right now.
    case unavailable
}

/// The single, truthful line Heimdal shows above the record control. Built
/// only from observed session facts: it never says more than the session
/// model knows (staged is local custody, not delivery or transcription).
struct CaptureStatus: Equatable {
    enum Kind: Equatable {
        case ready
        case permissionDenied
        case permissionRestricted
        case inputUnavailable
        case recording
        case paused
        case finalizing
        case staged
        case failed
    }

    /// Recovery actions iOS actually permits from inside the app.
    enum Recovery: Equatable {
        /// `UIApplication.openSettingsURLString`: Heimdal's own Settings page.
        case openSettings
        /// Re-read the OS state, e.g. after a microphone is reconnected.
        case checkAgain
        /// Start a new recording; the failed attempt's file is not reused.
        case recordAgain

        var title: String {
            switch self {
            case .openSettings: "Open Settings"
            case .checkAgain: "Check Again"
            case .recordAgain: "Record Again"
            }
        }
    }

    let kind: Kind
    let tone: YggStateTone
    let systemImage: String
    let title: String
    let message: String
    let recovery: Recovery?

    /// Whether the record control can start a capture from this state.
    /// Denied and restricted block it: iOS would record silence. A missing
    /// input still allows the attempt, so a false negative from the OS read
    /// cannot stop a real recording; a failed start reports itself.
    var canStartRecording: Bool {
        switch kind {
        case .ready, .staged, .failed, .inputUnavailable: true
        default: false
        }
    }
}

/// Reads the OS microphone facts. Injected so tests can supply states the
/// simulator cannot produce; production reads the live system values. The
/// read runs off the main thread: the first `AVAudioSession` access can stall
/// it while the audio server starts.
struct MicrophoneAvailabilityProbe: Sendable {
    let read: @Sendable () -> MicrophoneAvailability

    static let system = MicrophoneAvailabilityProbe {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .undetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: AVAudioSession.sharedInstance().isInputAvailable ? .granted : .unavailable
        @unknown default: .undetermined
        }
    }
}

extension CaptureSessionModel {
    /// Microphone problems outrank an idle/staged/failed phase, because they
    /// decide whether the next recording can start at all. A live recording
    /// keeps its own state: revoking access mid-capture surfaces through the
    /// recorder's failure path, not by relabelling the session here.
    var captureStatus: CaptureStatus {
        switch phase {
        case .recording:
            return CaptureStatus(
                kind: .recording, tone: .pending, systemImage: "record.circle", title: "Recording",
                message: "Audio is being written to a local file on this device.", recovery: nil
            )
        case .paused:
            return CaptureStatus(
                kind: .paused, tone: .pending, systemImage: "pause.circle", title: "Paused",
                message: "Recording is paused. Nothing is captured until you resume.", recovery: nil
            )
        case .finalizing:
            return CaptureStatus(
                kind: .finalizing, tone: .pending, systemImage: "hourglass",
                title: "Finishing Recording",
                message: "Heimdal is closing the audio file safely.", recovery: nil
            )
        case .idle, .staged, .failed:
            return microphoneStatus ?? restingStatus
        }
    }

    private var microphoneStatus: CaptureStatus? {
        switch microphone {
        case .undetermined, .granted:
            nil
        case .denied:
            CaptureStatus(
                kind: .permissionDenied, tone: .failure, systemImage: "mic.slash",
                title: "Microphone Access Is Off",
                message: "Heimdal cannot record until microphone access is turned on for Heimdal in Settings.",
                recovery: .openSettings
            )
        case .restricted:
            CaptureStatus(
                kind: .permissionRestricted, tone: .failure, systemImage: "lock.circle",
                title: "Microphone Is Restricted",
                message: "Screen Time or device management blocks the microphone on this device. "
                    + "Heimdal cannot change this; whoever manages those restrictions can.",
                recovery: nil
            )
        case .unavailable:
            CaptureStatus(
                kind: .inputUnavailable, tone: .attention, systemImage: "mic.badge.xmark",
                title: "No Microphone Available",
                message: "The system reports no audio input right now. "
                    + "Check the connected microphone or audio route.",
                recovery: .checkAgain
            )
        }
    }

    private var restingStatus: CaptureStatus {
        switch phase {
        case .failed:
            CaptureStatus(
                kind: .failed, tone: .failure, systemImage: "xmark.octagon",
                title: "Recording Failed",
                message: "The last recording could not be finished safely and was not staged.",
                recovery: .recordAgain
            )
        case .staged:
            CaptureStatus(
                kind: .staged, tone: .pending, systemImage: "internaldrive",
                title: "Staged on This Device",
                message: "The recording is kept locally. Delivery and transcription are not confirmed here.",
                recovery: nil
            )
        default:
            CaptureStatus(
                kind: .ready, tone: .empty, systemImage: "mic", title: "Ready to Record",
                message: "Press Record to capture your own spoken thoughts.", recovery: nil
            )
        }
    }
}

extension CaptureRecorder {
    /// Re-reads the OS microphone state into the session model. Call when
    /// Heimdal appears and whenever the app becomes active, since Settings
    /// changes happen outside the app.
    func refreshMicrophoneAvailability() async {
        let probe = microphoneProbe
        let availability = await Task.detached { probe.read() }.value
        sessionModel.updateMicrophone(availability)
    }

    /// Asks iOS for access only when it has not been decided; iOS shows its
    /// prompt once, so a denied or restricted state is explained by
    /// `CaptureSessionModel.captureStatus` instead of re-asking.
    func requestMicrophonePermissionAndStart() async {
        await refreshMicrophoneAvailability()
        switch sessionModel.microphone {
        case .granted, .unavailable:
            start()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] _ in
                guard let recorder = self else { return }
                Task { @MainActor [recorder] in
                    await recorder.refreshMicrophoneAvailability()
                    switch recorder.sessionModel.microphone {
                    case .granted, .unavailable: recorder.start()
                    case .undetermined, .denied, .restricted: break
                    }
                }
            }
        case .denied, .restricted:
            break
        }
    }
}
