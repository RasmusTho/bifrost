import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The foreground boundary for vault-backed Heimdal state. Registration facts
/// are refreshed before delivery work, because delivery may take time while a
/// cached consent grant must never continue to be presented as current.
@MainActor
func refreshHeimdalStateOnActivation(
    _ newPhase: ScenePhase,
    refreshRegistration: () async -> Void,
    retryUndelivered: () async -> Void
) async {
    guard newPhase == .active else { return }
    await refreshRegistration()
    await retryUndelivered()
}

/// Heimdal's isolated capture-client entry surface. It owns no Mimer lens
/// state and writes only this device's registration note through its model.
struct HeimdalShellView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var folderManager = CaptureFolderManager()
    @StateObject private var sessionModel = CaptureSessionModel()
    @StateObject private var recorder: CaptureRecorder
    @StateObject private var deliveryQueue: CaptureDeliveryQueue
    @StateObject private var registration: DeviceRegistrationModel
    @StateObject private var healthPanel: DeviceHealthPanelModel
    @State private var isFolderPickerPresented = false

    /// Delivery failures older than this are nameable gaps
    /// (`delivery_failed_aged`), not merely "still retrying".
    private static let deliveryFailedAgeThreshold: TimeInterval = 15 * 60

    init(
        sessionModel: CaptureSessionModel,
        fileStore: VaultFileStore? = nil,
        deviceID: String = HeimdalDeviceIdentity().deviceID(),
        deviceLabel: String = UIDevice.current.name
    ) {
        let model = sessionModel
        _sessionModel = StateObject(wrappedValue: model)
        _recorder = StateObject(wrappedValue: CaptureRecorder(sessionModel: model))
        _deliveryQueue = StateObject(wrappedValue: CaptureDeliveryQueue(sessionModel: model))
        _registration = StateObject(
            wrappedValue: DeviceRegistrationModel(
                fileStore: fileStore,
                deviceID: deviceID,
                deviceLabel: deviceLabel
            )
        )
        _healthPanel = StateObject(wrappedValue: DeviceHealthPanelModel(captureSession: model))
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section("Capture Folder") {
                        if let folderURL = folderManager.boundFolderURL {
                            YggStateBanner(
                                tone: .healthy, message: folderURL.lastPathComponent,
                                systemImage: "checkmark.circle.fill"
                            )
                            .accessibilityIdentifier("heimdal.captureFolder.bound")
                        } else {
                            YggStateBanner(
                                tone: .attention, message: "No capture folder selected",
                                systemImage: "folder.badge.questionmark"
                            )
                            .accessibilityIdentifier("heimdal.captureFolder.unbound")
                        }

                        Button("Choose Capture Folder") {
                            isFolderPickerPresented = true
                        }
                        .accessibilityIdentifier("heimdal.chooseCaptureFolder")

                        if let error = folderManager.lastError {
                            YggStateBanner(tone: .failure, message: error)
                        }
                    }

                    Section("Consent and Device") {
                        DeviceRegistrationStatusView(registration: registration)
                    }

                    Section("Capture") {
                        Text(recorder.configuration.microphonePrePrompt)
                            .font(YggTheme.Typography.caption)
                            .foregroundStyle(YggTheme.Color.textSecondary)
                        Button(recordButtonTitle) { recordButtonTapped() }
                            .disabled(!canPressRecord)
                            .accessibilityIdentifier("heimdal.record")
                        CaptureStatusView(status: sessionModel.captureStatus, onRecovery: perform)
                        if recorder.needsManualResume {
                            Button("Resume Recording") { recorder.resume() }
                        }
                        if let error = recorder.lastError {
                            YggStateBanner(tone: .failure, message: error)
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

                    // Placed last: this section is new, ephemeral (ADR-0049 §2's
                    // declared bend), and must never push an existing element
                    // (e.g. `heimdal.record`) out of the List's initially
                    // rendered viewport.
                    Section("Device Health") {
                        DeviceHealthPanelView(healthPanel: healthPanel)
                    }
                }
                .yggRows()
            }
            .yggPage()
            .navigationTitle("Heimdal")
            .sheet(isPresented: $isFolderPickerPresented) {
                CaptureFolderPicker { url in
                    folderManager.bind(folderURL: url)
                    isFolderPickerPresented = false
                    Task { await retryUndelivered() }
                }
            }
            .task {
                await recorder.refreshMicrophoneAvailability()
                await retryUndelivered()
                await registration.load()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Microphone access changes in Settings, outside the app.
                if newPhase == .active { Task { await recorder.refreshMicrophoneAvailability() } }
                Task {
                    await refreshHeimdalStateOnActivation(
                        newPhase,
                        refreshRegistration: { await registration.load() },
                        retryUndelivered: { await retryUndelivered() }
                    )
                }
                if newPhase == .background {
                    Task { await recordLastKnownSnapshot() }
                }
            }
            .onChange(of: sessionModel.stagedItems.map(\.deliveryState)) { _, _ in
                Task { await recordDeliveryFailedAgedGaps() }
            }
            .onChange(of: sessionModel.stagedItems.map(\.id)) { _, _ in
                Task { await deliverNewlyStaged() }
            }
        }
    }

    @ViewBuilder
    private func deliveryStatus(for item: CaptureSessionModel.StagedItem) -> some View {
        switch item.deliveryState {
        case .staged:
            YggStateBanner(tone: .pending, message: "Staged locally", systemImage: "internaldrive")
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
            YggStateBanner(
                tone: .failure,
                message: "Delivery failed — recording kept locally",
                systemImage: "exclamationmark.circle"
            )
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

    /// The durable half of the device-health bend: a coarse, low-churn
    /// readout, written on entering background. `updateLastKnownSnapshot`
    /// itself skips the write when nothing changed.
    private func recordLastKnownSnapshot() async {
        let recording = sessionModel.phase == .recording || sessionModel.phase == .paused
        await registration.updateLastKnownSnapshot(
            DeviceRegistrationModel.LastKnownSnapshot(
                battery: healthPanel.battery.level,
                queueDepth: healthPanel.queueDepth,
                recording: recording
            )
        )
    }

    /// Names one gap per staged item whose delivery has been failing for
    /// longer than `deliveryFailedAgeThreshold`. `recordGapEvent` is
    /// idempotent on `(kind, detail)`, so repeated calls for the same item
    /// append at most one entry.
    private func recordDeliveryFailedAgedGaps() async {
        let now = Date()
        for item in sessionModel.stagedItems {
            guard case let .failed(message, failedAt) = item.deliveryState,
                  now.timeIntervalSince(failedAt) >= Self.deliveryFailedAgeThreshold else { continue }
            await registration.recordGapEvent(
                kind: DeviceRegistrationModel.GapKind.deliveryFailedAged,
                detail: "item \(item.id.uuidString): \(message)"
            )
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

/// The record control and its capture-status recovery actions.
private extension HeimdalShellView {
    var recordButtonTitle: String {
        switch sessionModel.phase {
        case .recording, .paused: "Stop Recording"
        default: "Record"
        }
    }

    var canPressRecord: Bool {
        switch sessionModel.phase {
        case .recording, .paused: true
        default: sessionModel.captureStatus.canStartRecording
        }
    }

    func perform(_ recovery: CaptureStatus.Recovery) {
        switch recovery {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .checkAgain:
            Task { await recorder.refreshMicrophoneAvailability() }
        case .recordAgain:
            Task { await recorder.requestMicrophonePermissionAndStart() }
        }
    }

    func recordButtonTapped() {
        switch sessionModel.phase {
        case .recording, .paused:
            Task { await recorder.stop() }
        default: Task { await recorder.requestMicrophonePermissionAndStart() }
        }
    }
}

/// ADR-0049 §2's declared UI-only bend, rendered: every value here comes
/// straight from live runtime state and is never written anywhere.
private struct DeviceHealthPanelView: View {
    @ObservedObject var healthPanel: DeviceHealthPanelModel

    var body: some View {
        Group {
            Text("Session: \(String(describing: healthPanel.recordingPhase))")
                .accessibilityIdentifier("heimdal.health.phase")
            Text("Delivery queue: \(healthPanel.queueDepth)")
                .accessibilityIdentifier("heimdal.health.queueDepth")
            if let oldestPendingAge = healthPanel.oldestPendingAge {
                Text("Oldest pending: \(Int(oldestPendingAge))s")
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(YggTheme.Color.textSecondary)
            }
            if let level = healthPanel.battery.level {
                Text("Battery: \(Int(level * 100))%")
            } else {
                Text("Battery: unknown")
            }
            Text("Mic permission: \(String(describing: healthPanel.microphone))")
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
        }
    }
}

/// The capture status line and, where iOS permits one, its recovery action.
private struct CaptureStatusView: View {
    let status: CaptureStatus
    let onRecovery: (CaptureStatus.Recovery) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: YggTheme.Spacing.xs) {
            YggStateBanner(tone: status.tone, message: status.title, systemImage: status.systemImage)
            Text(status.message)
                .font(YggTheme.Typography.caption)
                .foregroundStyle(YggTheme.Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("heimdal.capture.status")
        if let recovery = status.recovery {
            Button(recovery.title) { onRecovery(recovery) }
                .accessibilityIdentifier("heimdal.capture.recovery")
        }
    }
}

private struct DeviceRegistrationStatusView: View {
    @ObservedObject var registration: DeviceRegistrationModel

    @ViewBuilder
    var body: some View {
        switch registration.state {
        case .unavailable:
            YggStateBanner(tone: .attention, message: "No vault selected — captures may be refused")
                .accessibilityIdentifier("heimdal.registration.unavailable")
        case .loading:
            ProgressView("Loading device registration")
        case let .failed(message):
            YggStateBanner(tone: .attention, message: "Registration status unavailable — captures may be refused")
            Text(message).font(YggTheme.Typography.caption)
        case let .loaded(snapshot):
            if let grant = snapshot.standingGrant {
                Label(
                    "Standing grant: \(grant.scope ?? "unspecified scope")",
                    systemImage: "checkmark.shield"
                )
                if let grantedAt = grant.grantedAt {
                    Text("Granted \(grantedAt)")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                }
            } else {
                YggStateBanner(
                    tone: .attention, message: "No standing grant found", systemImage: "exclamationmark.shield"
                )
                    .accessibilityIdentifier("heimdal.consent.empty")
            }

            if snapshot.isRegistered {
                YggStateBanner(
                    tone: .healthy, message: "This device is registered", systemImage: "checkmark.circle.fill"
                )
                    .accessibilityIdentifier("heimdal.registration.registered")
                if let deviceNote = snapshot.deviceNote {
                    Text("Device ID: \(deviceNote.deviceID ?? "missing")")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                        .accessibilityIdentifier("heimdal.registration.deviceID")
                    Text("Label: \(deviceNote.label ?? "missing")")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                        .accessibilityIdentifier("heimdal.registration.label")
                    Text(
                        deviceNote.consentGrantRef.map { "Grant reference: \($0)" }
                            ?? "No grant reference bound"
                    )
                    .font(YggTheme.Typography.caption)
                    .foregroundStyle(YggTheme.Color.textSecondary)
                    .accessibilityIdentifier("heimdal.registration.grantRef")
                    Text("Gap log entries: \(deviceNote.gapLogCount)")
                        .font(YggTheme.Typography.caption)
                        .foregroundStyle(YggTheme.Color.textSecondary)
                        .accessibilityIdentifier("heimdal.registration.gapLogCount")
                }
            } else {
                YggStateBanner(
                    tone: .attention, message: "Not registered — captures may be refused",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .accessibilityIdentifier("heimdal.registration.unregistered")
                Button("Register This Device") {
                    Task { await registration.register() }
                }
                .accessibilityIdentifier("heimdal.registration.register")
            }

            Text(
                "Posture A: single-party, discrete, press-to-record capture. Admission is decided by Heimdal."
            )
            .font(YggTheme.Typography.caption)
            .foregroundStyle(YggTheme.Color.textSecondary)
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
