import AppKit
import CoreGraphics
import Foundation
import ImageIO
import IOKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
protocol ScreenCaptureProviding {
    func frontmostApplication() -> ScreenApplication?
    func isIdleOrLocked() -> Bool
    func captureFrontmostWindow(appIdentifier: String) async throws -> ScreenFrame?
}

@MainActor
final class MacOSScreenCaptureProvider: NSObject, ScreenCaptureProviding {
    enum CaptureError: LocalizedError {
        case unavailableImageEncoder

        var errorDescription: String? {
            "macOS could not encode the selected screen window. No frame was queued."
        }
    }

    private static let idleThresholdSeconds: TimeInterval = 60
    private static let blockedApplications: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.ScreenSaver.Engine.legacyScreenSaver"
    ]

    private var sessionIsActive: Bool

    override init() {
        sessionIsActive = NSApp.isActive
        super.init()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionBecameActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: NSWorkspace.shared
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionResignedActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: NSWorkspace.shared
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
    }

    func frontmostApplication() -> ScreenApplication? {
        guard let runningApplication = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = runningApplication.bundleIdentifier,
              !bundleIdentifier.isEmpty,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let name = runningApplication.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleIdentifier
        return ScreenApplication(bundleIdentifier: bundleIdentifier, name: resolvedName)
    }

    func isIdleOrLocked() -> Bool {
        guard sessionIsActive,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
              onConsole,
              let application = frontmostApplication(),
              !Self.blockedApplications.contains(application.bundleIdentifier),
              let idleSeconds = inputIdleSeconds() else {
            return true
        }
        return idleSeconds >= Self.idleThresholdSeconds
    }

    func captureFrontmostWindow(appIdentifier: String) async throws -> ScreenFrame? {
        guard frontmostApplication()?.bundleIdentifier == appIdentifier, !isIdleOrLocked() else { return nil }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard frontmostApplication()?.bundleIdentifier == appIdentifier, !isIdleOrLocked() else { return nil }
        guard let activeApplication = NSWorkspace.shared.frontmostApplication,
              activeApplication.bundleIdentifier == appIdentifier,
              let window = frontmostWindow(in: content, processIdentifier: activeApplication.processIdentifier) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = min(2048, max(1, Int(window.frame.width.rounded(.up))))
        configuration.height = min(2048, max(1, Int(window.frame.height.rounded(.up))))
        configuration.showsCursor = false

        // Recheck the active application and session immediately before requesting pixels.
        guard frontmostApplication()?.bundleIdentifier == appIdentifier, !isIdleOrLocked() else { return nil }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptureError.unavailableImageEncoder
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.unavailableImageEncoder }

        return ScreenFrame(
            pngData: data as Data,
            capturedAt: Date(),
            windowIdentifier: window.windowID,
            windowTitle: window.title
        )
    }

    private func inputIdleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let idleProperty = IORegistryEntryCreateCFProperty(
            service,
            "HIDIdleTime" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let idleValue = idleProperty.takeRetainedValue()
        guard let nanoseconds = idleValue as? NSNumber, nanoseconds.doubleValue.isFinite else { return nil }
        return nanoseconds.doubleValue / 1_000_000_000
    }

    private func frontmostWindow(in content: SCShareableContent, processIdentifier: pid_t) -> SCWindow? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let activeWindowIdentifier = windowInfo.lazy.compactMap { info -> UInt32? in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            return number.uint32Value
        }.first
        guard let activeWindowIdentifier else { return nil }
        return content.windows.first { window in
            window.windowID == activeWindowIdentifier && window.isOnScreen
                && window.windowLayer == 0
                && window.owningApplication?.processID == processIdentifier
                && window.frame.width > 0 && window.frame.height > 0
        }
    }

    @objc
    private func sessionBecameActive() {
        sessionIsActive = true
    }

    @objc
    private func sessionResignedActive() {
        sessionIsActive = false
    }

    @objc
    private func applicationBecameActive() {
        sessionIsActive = true
    }
}
