import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Heimdal's isolated capture-client entry surface. It owns no Mimer lens
/// state and no vault writes; later capture slices extend this boundary.
struct HeimdalShellView: View {
    @StateObject private var folderManager = CaptureFolderManager()
    @StateObject private var sessionModel = CaptureSessionModel()
    @StateObject private var recorder: CaptureRecorder
    @State private var isFolderPickerPresented = false

    init() {
        let model = CaptureSessionModel()
        _sessionModel = StateObject(wrappedValue: model)
        _recorder = StateObject(wrappedValue: CaptureRecorder(sessionModel: model))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Capture Folder") {
                    if let folderURL = folderManager.boundFolderURL {
                        Label(folderURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .accessibilityIdentifier("heimdal.captureFolder.bound")
                    } else {
                        Label("No capture folder selected", systemImage: "folder.badge.questionmark")
                            .accessibilityIdentifier("heimdal.captureFolder.unbound")
                    }

                    Button("Choose Capture Folder") {
                        isFolderPickerPresented = true
                    }
                    .accessibilityIdentifier("heimdal.chooseCaptureFolder")

                    if let error = folderManager.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Capture") {
                    Text(recorder.configuration.microphonePrePrompt)
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                    Button(recordButtonTitle) { recordButtonTapped() }
                        .accessibilityIdentifier("heimdal.record")
                    if recorder.needsManualResume {
                        Button("Resume Recording") { recorder.resume() }
                    }
                    if let error = recorder.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Staged Items") {
                    if sessionModel.stagedItems.isEmpty {
                        Text("No staged recordings yet.")
                            .foregroundStyle(YggTheme.Color.textSecondary)
                    }
                    ForEach(sessionModel.stagedItems) { item in
                        VStack(alignment: .leading) {
                            Text(item.capturedAt, format: .dateTime.year().month().day().hour().minute())
                            Text("\(item.duration, format: .number.precision(.fractionLength(1))) seconds")
                                .font(YggTheme.Typography.caption)
                                .foregroundStyle(YggTheme.Color.textSecondary)
                            if item.wasRecoveredAfterRestart {
                                Label("Recovered after restart", systemImage: "arrow.clockwise")
                                    .font(YggTheme.Typography.caption)
                                    .foregroundStyle(YggTheme.Color.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Heimdal")
            .sheet(isPresented: $isFolderPickerPresented) {
                CaptureFolderPicker { url in
                    folderManager.bind(folderURL: url)
                    isFolderPickerPresented = false
                }
            }
        }
    }

    private var recordButtonTitle: String {
        switch sessionModel.phase {
        case .recording, .paused: "Stop Recording"
        default: "Record"
        }
    }

    private func recordButtonTapped() {
        switch sessionModel.phase {
        case .recording, .paused:
            Task { await recorder.stop() }
        default: recorder.requestMicrophonePermissionAndStart()
        }
    }
}

struct CaptureFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
