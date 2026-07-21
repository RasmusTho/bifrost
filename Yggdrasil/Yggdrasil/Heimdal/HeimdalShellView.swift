import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Heimdal's isolated capture-client entry surface. It owns no Mimer lens
/// state and no vault writes; later capture slices extend this boundary.
struct HeimdalShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var folderManager = CaptureFolderManager()
    @StateObject private var sessionModel = CaptureSessionModel()
    @StateObject private var recorder: CaptureRecorder
    @StateObject private var deliveryQueue: CaptureDeliveryQueue
    @State private var isFolderPickerPresented = false

    init(sessionModel: CaptureSessionModel) {
        let model = sessionModel
        _sessionModel = StateObject(wrappedValue: model)
        _recorder = StateObject(wrappedValue: CaptureRecorder(sessionModel: model))
        _deliveryQueue = StateObject(wrappedValue: CaptureDeliveryQueue(sessionModel: model))
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
                            deliveryStatus(for: item)
                        }
                    }
                }

                if !sessionModel.recoveryFailures.isEmpty {
                    Section("Recovery Issues") {
                        ForEach(sessionModel.recoveryFailures) { failure in
                            VStack(alignment: .leading) {
                                Label(
                                    "Recording needs recovery",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                Text(failure.url.lastPathComponent)
                                    .font(YggTheme.Typography.caption)
                                Text(failure.reason.message)
                                    .font(YggTheme.Typography.caption)
                                    .foregroundStyle(YggTheme.Color.textSecondary)
                            }
                            .accessibilityIdentifier("heimdal.recoveryFailure")
                        }
                    }
                }
            }
            .navigationTitle("Heimdal")
            .sheet(isPresented: $isFolderPickerPresented) {
                CaptureFolderPicker { url in
                    folderManager.bind(folderURL: url)
                    isFolderPickerPresented = false
                    Task { await retryUndelivered() }
                }
            }
            .task {
                await retryUndelivered()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await retryUndelivered() }
            }
            .onChange(of: sessionModel.stagedItems.map(\.id)) { _, _ in
                Task { await deliverNewlyStaged() }
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

    @ViewBuilder
    private func deliveryStatus(for item: CaptureSessionModel.StagedItem) -> some View {
        switch item.deliveryState {
        case .staged:
            Label("Staged locally", systemImage: "internaldrive")
                .accessibilityIdentifier("heimdal.delivery.staged")
        case let .delivering(startedAt):
            Label("Placing in capture folder", systemImage: "arrow.up.doc")
            Text(startedAt, format: .dateTime.hour().minute().second())
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
        case let .deliveredAwaitingSync(placedAt):
            Label("Placed in capture folder", systemImage: "checkmark.circle")
                .accessibilityIdentifier("heimdal.delivery.placed")
            Text(placedAt, format: .dateTime.hour().minute().second())
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
            Text("iCloud sync and hub admission are not confirmed here.")
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
        case let .failed(message, failedAt):
            Label("Delivery failed — recording kept locally", systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
                .accessibilityIdentifier("heimdal.delivery.failed")
            Text(failedAt, format: .dateTime.hour().minute().second())
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
            Text(message)
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
            Button("Retry Placement") {
                Task { await retry(itemID: item.id) }
            }
            .accessibilityIdentifier("heimdal.delivery.retry")
        }
    }

    private func retryUndelivered() async {
        await withBoundCaptureFolder { folderURL in
            await deliveryQueue.retryUndelivered(to: folderURL)
        }
    }

    private func deliverNewlyStaged() async {
        await withBoundCaptureFolder { folderURL in
            await deliveryQueue.deliverNewlyStaged(to: folderURL)
        }
    }

    private func retry(itemID: UUID) async {
        await withBoundCaptureFolder { folderURL in
            await deliveryQueue.deliver(itemID: itemID, to: folderURL)
        }
    }

    private func withBoundCaptureFolder(
        operation: (URL?) async -> Void
    ) async {
        guard let folderURL = folderManager.beginAccessingBoundFolder() else {
            await operation(nil)
            return
        }
        defer { folderManager.endAccessingBoundFolder(folderURL) }
        await operation(folderURL)
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
