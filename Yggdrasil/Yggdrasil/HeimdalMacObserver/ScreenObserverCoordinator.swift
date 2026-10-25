import Foundation

enum ScreenObserverPhase: Equatable {
    case starting
    case paused(String)
    case idle
    case observing
    case degraded(String)

    var title: String {
        switch self {
        case .starting: "Starting"
        case .paused: "Paused"
        case .idle: "Idle"
        case .observing: "Observing"
        case .degraded: "Degraded · paused"
        }
    }

    var detail: String {
        switch self {
        case .starting: "Waiting for fresh Heimdal controls."
        case let .paused(reason), let .degraded(reason): reason
        case .idle: "No frame was sampled because the session is idle, locked, or lacks a frontmost app."
        case .observing: "The active application window was sampled and entered the local durable queue."
        }
    }
}

struct ScreenObserverStatus: Equatable {
    var phase: ScreenObserverPhase = .starting
    var cadenceSeconds: TimeInterval?
    var lastCaptureAt: Date?
    var buffer = ScreenBufferSummary(pendingCount: 0, oldestEvictionCount: 0)
}

private enum ScreenObserverFailure: LocalizedError {
    case controlsUnavailable(String)
    case bindingChanged
    case durableStorageUnavailable(String)
    case deliveryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .controlsUnavailable(detail):
            "Fresh valid screen controls are unavailable. Capture remains paused: \(detail)"
        case .bindingChanged:
            "The host binding changed while frames were queued. The queue is preserved and capture remains paused."
        case let .durableStorageUnavailable(detail):
            "The local durable screen queue could not be updated. Capture remains paused: \(detail)"
        case let .deliveryUnavailable(detail):
            "The host did not provide a durable acknowledgement. The frame remains queued: \(detail)"
        }
    }
}

@MainActor
final class ScreenObserverCoordinator {
    private enum QueueDrainResult: Equatable {
        case empty
        case blockedByCurrentControls
        case bindingChanged
    }

    private struct CycleDrainResult {
        let shouldContinue: Bool
        let deliveryError: String?
    }

    private let controls: ScreenControlProviding
    private let capture: ScreenCaptureProviding
    private let shipping: ScreenBundleShipping
    private let buffer: DurableScreenBuffer
    private let sensor: ScreenSensorIdentity
    private let encoder: JSONEncoder

    private(set) var status = ScreenObserverStatus()

    init(
        controls: ScreenControlProviding,
        capture: ScreenCaptureProviding,
        shipping: ScreenBundleShipping,
        buffer: DurableScreenBuffer,
        sensor: ScreenSensorIdentity
    ) {
        self.controls = controls
        self.capture = capture
        self.shipping = shipping
        self.buffer = buffer
        self.sensor = sensor
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    var nextIntervalSeconds: TimeInterval {
        status.cadenceSeconds ?? 30
    }

    func refreshVisibleState() {
        switch status.phase {
        case .starting, .observing:
            if capture.isIdleOrLocked() { status.phase = .idle }
        case .idle:
            if !capture.isIdleOrLocked() { status.phase = .starting }
        case .paused, .degraded:
            break
        }
    }

    func runCycle() async {
        guard let application = capture.frontmostApplication() else {
            status.phase = .idle
            await refreshBufferSummary()
            return
        }
        guard !capture.isIdleOrLocked() else {
            status.phase = .idle
            await refreshBufferSummary()
            return
        }

        guard let initialControls = await readInitialControls(for: application.bundleIdentifier) else {
            await refreshBufferSummary()
            return
        }
        status.cadenceSeconds = initialControls.cadenceSeconds
        guard initialControls.permitsCapture(for: application.bundleIdentifier) else {
            status.phase = Self.pausedReason(for: initialControls, appIdentifier: application.bundleIdentifier)
            await refreshBufferSummary()
            return
        }

        let firstDrain = await drainQueueForCycle()
        guard firstDrain.shouldContinue else {
            await refreshBufferSummary()
            return
        }

        guard let captured = await captureForCycle(application) else {
            await refreshBufferSummary()
            return
        }

        var deliveryError = firstDrain.deliveryError
        if captured {
            let finalDrain = await drainQueueForCycle()
            guard finalDrain.shouldContinue else {
                await refreshBufferSummary()
                return
            }
            deliveryError = finalDrain.deliveryError
        }

        if case .observing = status.phase, let deliveryError {
            status.phase = .degraded("Durable delivery is waiting: \(deliveryError)")
        }
        await refreshBufferSummary()
    }

    private func readInitialControls(for appIdentifier: String) async -> ScreenControlSnapshot? {
        do {
            return try await readControls(for: appIdentifier)
        } catch let failure as ScreenObserverFailure {
            _ = stopCycle(for: failure)
        } catch {
            status.phase = .paused("Fresh valid screen controls are unavailable. Capture remains paused.")
        }
        return nil
    }

    private func drainQueueForCycle() async -> CycleDrainResult {
        do {
            if try await drainPermittedQueue() == .bindingChanged {
                _ = stopCycle(for: .bindingChanged)
                return CycleDrainResult(shouldContinue: false, deliveryError: nil)
            }
            return CycleDrainResult(shouldContinue: true, deliveryError: nil)
        } catch let failure as ScreenObserverFailure {
            if stopCycle(for: failure) {
                return CycleDrainResult(shouldContinue: false, deliveryError: nil)
            }
            return CycleDrainResult(shouldContinue: true, deliveryError: failure.localizedDescription)
        } catch {
            return CycleDrainResult(shouldContinue: true, deliveryError: error.localizedDescription)
        }
    }

    private func captureForCycle(_ application: ScreenApplication) async -> Bool? {
        do {
            return try await captureAndQueue(application)
        } catch let failure as ScreenObserverFailure {
            _ = stopCycle(for: failure)
        } catch {
            status.phase = .degraded("Screen capture could not proceed: \(error.localizedDescription)")
        }
        return nil
    }

    private func captureAndQueue(_ application: ScreenApplication) async throws -> Bool {
        guard capture.frontmostApplication()?.bundleIdentifier == application.bundleIdentifier,
              !capture.isIdleOrLocked() else {
            status.phase = .idle
            return false
        }
        let captureControls = try await readControls(for: application.bundleIdentifier)
        status.cadenceSeconds = captureControls.cadenceSeconds
        guard captureControls.permitsCapture(for: application.bundleIdentifier) else {
            status.phase = Self.pausedReason(for: captureControls, appIdentifier: application.bundleIdentifier)
            return false
        }
        guard let frame = try await capture.captureFrontmostWindow(appIdentifier: application.bundleIdentifier) else {
            status.phase = .idle
            return false
        }
        guard capture.frontmostApplication()?.bundleIdentifier == application.bundleIdentifier,
              !capture.isIdleOrLocked() else {
            status.phase = .idle
            return false
        }
        let currentControls = try await readControls(for: application.bundleIdentifier)
        status.cadenceSeconds = currentControls.cadenceSeconds
        guard currentControls.binding == captureControls.binding else {
            throw ScreenObserverFailure.bindingChanged
        }
        guard currentControls.permitsCapture(for: application.bundleIdentifier) else {
            status.phase = Self.pausedReason(for: currentControls, appIdentifier: application.bundleIdentifier)
            return false
        }

        let bundle = ScreenCaptureBundle(
            sensor: sensor,
            application: application,
            frame: frame,
            cadenceSeconds: currentControls.cadenceSeconds
        )
        let entry = ScreenQueueEntry(
            appIdentifier: application.bundleIdentifier,
            binding: currentControls.binding,
            payload: try encoder.encode(bundle)
        )
        do {
            try await buffer.enqueue(entry, maximum: currentControls.bufferMaximum)
        } catch {
            throw ScreenObserverFailure.durableStorageUnavailable(error.localizedDescription)
        }
        status.lastCaptureAt = frame.capturedAt
        status.phase = .observing
        return true
    }

    private func drainPermittedQueue() async throws -> QueueDrainResult {
        while let entry = await buffer.firstEntry() {
            let currentControls = try await readControls(for: entry.appIdentifier)
            guard currentControls.binding == entry.binding else { return .bindingChanged }
            guard currentControls.permitsCapture(for: entry.appIdentifier) else {
                return .blockedByCurrentControls
            }
            let acknowledgement: DurableScreenAcknowledgement
            do {
                acknowledgement = try await shipping.ship(entry)
            } catch {
                throw ScreenObserverFailure.deliveryUnavailable(error.localizedDescription)
            }
            guard !acknowledgement.recordIdentifier.isEmpty,
                  !acknowledgement.contentIdentity.isEmpty,
                  acknowledgement.bundleShape == "raw_capture_bundle" else {
                throw ScreenObserverFailure.deliveryUnavailable(
                    "The acknowledgement was missing its durable record identity or bundle shape."
                )
            }
            do {
                try await buffer.acknowledgeOldest(contentIdentity: entry.contentIdentity)
            } catch {
                throw ScreenObserverFailure.durableStorageUnavailable(error.localizedDescription)
            }
        }
        return .empty
    }

    private func readControls(for appIdentifier: String) async throws -> ScreenControlSnapshot {
        do {
            return try await controls.controls(for: appIdentifier)
        } catch {
            throw ScreenObserverFailure.controlsUnavailable(error.localizedDescription)
        }
    }

    private func stopCycle(for failure: ScreenObserverFailure) -> Bool {
        switch failure {
        case let .controlsUnavailable(detail):
            status.phase = .paused("Fresh valid screen controls are unavailable. Capture remains paused: \(detail)")
            return true
        case .bindingChanged:
            status.phase = .paused(ScreenObserverFailure.bindingChanged.localizedDescription)
            return true
        case let .durableStorageUnavailable(detail):
            status.phase = .degraded("The local durable queue failed. Capture remains paused: \(detail)")
            return true
        case .deliveryUnavailable:
            return false
        }
    }

    private func refreshBufferSummary() async {
        status.buffer = await buffer.summary()
    }

    private static func pausedReason(
        for controls: ScreenControlSnapshot,
        appIdentifier: String
    ) -> ScreenObserverPhase {
        if !controls.isReady {
            return .paused("The host controls are paused, degraded, or missing required accepted settings.")
        }
        if !controls.permitsCapture(for: appIdentifier) {
            return .paused(
                "The frontmost application or one of its mapped scopes is excluded. No frame was captured."
            )
        }
        return .paused("The host did not permit screen capture. No frame was captured.")
    }
}
