import SwiftUI

struct WatchCaptureView: View {
    @StateObject private var model: WatchCaptureSessionModel
    @StateObject private var recorder: WatchCaptureRecorder

    init() {
        let model = WatchCaptureSessionModel(haptics: WatchKitHapticPlayer())
        _model = StateObject(wrappedValue: model)
        _recorder = StateObject(wrappedValue: WatchCaptureRecorder(model: model))
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(statusText)
                .font(.headline)
                .accessibilityIdentifier("watch.capture.status")

            if model.isActivelyRecording {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(recorder.elapsedText(at: context.date))
                        .monospacedDigit()
                        .font(.title3)
                }
                Label("Recording", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
            } else if model.phase == .paused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }

            Button(actionTitle) { recordButtonTapped() }
                .buttonStyle(.borderedProminent)
                .tint(model.phase == .recording || model.phase == .paused ? .red : .accentColor)
                .accessibilityIdentifier("watch.capture.record")
                .disabled(model.phase == .starting || model.phase == .finalizing)

            Text("\(model.queuedRelayCount) queued for phone relay")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("watch.capture.queued")

            Text(
                "Without your phone, recordings stay queued on this Watch. "
                    + "Native phoneless delivery is not available."
            )
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let error = recorder.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private var actionTitle: String {
        switch model.phase {
        case .recording, .paused: "Stop"
        case .starting: "Starting…"
        case .idle, .finalizing: "Record"
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "Ready to capture"
        case .starting: "Starting capture"
        case .recording: "Still capturing"
        case .paused: "Capture paused"
        case .finalizing: "Finalizing"
        }
    }

    private func recordButtonTapped() {
        switch model.phase {
        case .recording, .paused: recorder.stop()
        case .idle: recorder.start()
        case .starting, .finalizing: break
        }
    }
}
