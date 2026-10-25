import SwiftUI

@MainActor
final class HeimdalMacObserverRuntime: ObservableObject {
    static let identifier = "HeimdalMacObserver"

    @Published private(set) var status = ScreenObserverStatus()

    private let coordinator: ScreenObserverCoordinator?
    private let startupError: String?
    private var pollingTask: Task<Void, Never>?
    private var statusMonitorTask: Task<Void, Never>?

    init(coordinator: ScreenObserverCoordinator?, startupError: String? = nil) {
        self.coordinator = coordinator
        self.startupError = startupError
    }

    static func live() -> HeimdalMacObserverRuntime {
        do {
            let directory = try ScreenObserverStorage.applicationSupportDirectory()
            let buffer = try DurableScreenBuffer(directoryURL: directory)
            let machine = try ScreenMachineIdentityStore(directoryURL: directory).loadOrCreate()
            let api = try ScreenControlAPI.configured()
            let coordinator = ScreenObserverCoordinator(
                controls: api,
                capture: MacOSScreenCaptureProvider(),
                shipping: api,
                buffer: buffer,
                sensor: ScreenSensorIdentity(machine: machine)
            )
            return HeimdalMacObserverRuntime(coordinator: coordinator)
        } catch {
            return HeimdalMacObserverRuntime(coordinator: nil, startupError: error.localizedDescription)
        }
    }

    func start() async {
        guard pollingTask == nil else { return }
        guard let coordinator else {
            let detail = startupError ?? "unknown startup error"
            status.phase = .paused(
                "The observer could not open private storage or the local hub address. "
                    + "Capture remains paused: \(detail)"
            )
            return
        }

        statusMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                coordinator.refreshVisibleState()
                status = coordinator.status
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                await coordinator.runCycle()
                status = coordinator.status
                let delay = max(1, coordinator.nextIntervalSeconds)
                let nanoseconds = UInt64(min(delay, 3600) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        statusMonitorTask?.cancel()
        statusMonitorTask = nil
    }
}

@main
struct HeimdalMacObserverApp: App {
    @StateObject private var runtime: HeimdalMacObserverRuntime

    init() {
        _runtime = StateObject(wrappedValue: HeimdalMacObserverRuntime.live())
    }

    var body: some Scene {
        WindowGroup {
            HeimdalMacObserverView(runtime: runtime)
                .task { await runtime.start() }
        }
    }
}

private struct HeimdalMacObserverView: View {
    @ObservedObject var runtime: HeimdalMacObserverRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Heimdal macOS screen observer")
                .font(.title2)
                .accessibilityIdentifier(HeimdalMacObserverRuntime.identifier)
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(runtime.status.phase.title)
                    .font(.headline)
            }
            Text(runtime.status.phase.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let cadence = runtime.status.cadenceSeconds {
                Text("Accepted cadence: \(cadence.formatted()) seconds")
            }
            Text(
                "Durable queue: \(runtime.status.buffer.pendingCount) pending · "
                    + "\(runtime.status.buffer.oldestEvictionCount) oldest-frame evictions"
            )
            Divider()
            Text(
                "Only the frontmost application window is sampled. Keyboard input, clipboard, audio, "
                    + "and continuous video are not collected."
            )
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(
                "Pause, exclusions, and consent are read from Heimdal's control endpoint. "
                    + "This client does not change settings."
            )
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 260)
    }

    private var statusColor: Color {
        switch runtime.status.phase {
        case .observing: .green
        case .idle: .orange
        case .paused, .starting, .degraded: .secondary
        }
    }
}
