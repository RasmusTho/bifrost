import CoreFoundation
import Foundation

struct ScreenApplication: Equatable {
    let bundleIdentifier: String
    let name: String
}

struct ScreenFrame: Equatable {
    let pngData: Data
    let capturedAt: Date
    let windowIdentifier: UInt32
    let windowTitle: String?
}

struct ScreenControlBinding: Codable, Equatable, Sendable {
    let vaultIdentifier: String
    let localInstanceIdentifier: String
}

struct ScreenSensorIdentity: Codable, Equatable {
    static let adapter = "heimdal_macos_screen_observer"
    static let version = "v1"

    let adapter: String
    let version: String
    let machine: String

    init(machine: String) {
        adapter = Self.adapter
        version = Self.version
        self.machine = machine
    }
}

struct ScreenControlSnapshot: Equatable {
    let appIdentifier: String
    let state: String
    let settingsState: String
    let errors: [String]
    let capturePermitted: Bool
    let excluded: Bool
    let consentActive: Bool
    let vaultIdentifier: String
    let localInstanceIdentifier: String
    let screenPaused: Bool
    let excludedApplications: Set<String>
    let excludedScopes: Set<String>
    let scopeApplications: [String: Set<String>]
    let cadenceSeconds: TimeInterval
    let bufferMaximum: Int

    var binding: ScreenControlBinding {
        ScreenControlBinding(
            vaultIdentifier: vaultIdentifier,
            localInstanceIdentifier: localInstanceIdentifier
        )
    }

    var isReady: Bool {
        state == "ready" && settingsState == "ok" && errors.isEmpty && !screenPaused
            && consentActive && !vaultIdentifier.isEmpty && !localInstanceIdentifier.isEmpty
    }

    func permitsCapture(for appIdentifier: String) -> Bool {
        guard appIdentifier == self.appIdentifier, isReady, capturePermitted, !excluded else { return false }
        guard !excludedApplications.contains(appIdentifier) else { return false }
        let mappedScopes = scopeApplications.compactMap { scope, applications in
            applications.contains(appIdentifier) ? scope : nil
        }
        return mappedScopes.allSatisfy { !excludedScopes.contains($0) }
    }

    static func decode(_ data: Data, expectedApplication: String) throws -> ScreenControlSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appIdentifier = root["app_id"] as? String,
              appIdentifier == expectedApplication,
              let state = root["state"] as? String,
              ["paused", "ready", "degraded"].contains(state),
              let settingsState = root["settings_state"] as? String,
              let errors = stringArray(root["errors"]),
              let capturePermitted = strictBoolean(root["capture_permitted"]),
              let excluded = strictBoolean(root["excluded"]),
              let consentActive = strictBoolean(root["consent_active"]),
              let vaultIdentifier = nonemptyString(root["vault_id"]),
              let localInstanceIdentifier = nonemptyString(root["local_instance_id"]),
              let controls = root["controls"] as? [String: Any],
              let screenPaused = strictBoolean(controls["screen_paused"]),
              let excludedApplications = stringSet(controls["screen_excluded_apps"]),
              let excludedScopes = stringSet(controls["screen_excluded_scopes"]),
              let scopeApplications = scopeApplicationMap(controls["screen_scope_app_mapping"]),
              let cadenceSeconds = finitePositiveNumber(controls["screen_capture_cadence_seconds"]),
              cadenceSeconds <= 3600,
              let bufferMaximum = strictInteger(controls["screen_client_buffer_max"]),
              (1...10_000).contains(bufferMaximum) else {
            throw ScreenControlDecodeError.invalidOrAmbiguousControls
        }

        return ScreenControlSnapshot(
            appIdentifier: appIdentifier,
            state: state,
            settingsState: settingsState,
            errors: errors,
            capturePermitted: capturePermitted,
            excluded: excluded,
            consentActive: consentActive,
            vaultIdentifier: vaultIdentifier,
            localInstanceIdentifier: localInstanceIdentifier,
            screenPaused: screenPaused,
            excludedApplications: excludedApplications,
            excludedScopes: excludedScopes,
            scopeApplications: scopeApplications,
            cadenceSeconds: cadenceSeconds,
            bufferMaximum: bufferMaximum
        )
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func finitePositiveNumber(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue > 0 else { return nil }
        return number.doubleValue
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any], values.allSatisfy({ $0 is String }) else { return nil }
        return values.compactMap { $0 as? String }
    }

    private static func stringSet(_ value: Any?) -> Set<String>? {
        guard let values = stringArray(value) else { return nil }
        return Set(values)
    }

    private static func scopeApplicationMap(_ value: Any?) -> [String: Set<String>]? {
        guard let mapping = value as? [String: Any] else { return nil }
        var result: [String: Set<String>] = [:]
        for (scope, rawApplications) in mapping {
            guard !scope.isEmpty, let applications = stringSet(rawApplications) else { return nil }
            result[scope] = applications
        }
        return result
    }
}

enum ScreenControlDecodeError: LocalizedError {
    case invalidOrAmbiguousControls

    var errorDescription: String? {
        "The hub returned missing, invalid, or ambiguous screen controls. Capture remains paused."
    }
}

struct ScreenRawFrame: Encodable {
    let modality = "screen"
    let capturedAt: String
    let cadenceSeconds: TimeInterval
    let app: String
    let appBundleIdentifier: String
    let window: String?
    let scope = "screen_always_on"
    let frame: String

    enum CodingKeys: String, CodingKey {
        case modality
        case capturedAt = "captured_at"
        case cadenceSeconds = "cadence_seconds"
        case app
        case appBundleIdentifier = "app_bundle_id"
        case window
        case scope
        case frame
    }
}

struct ScreenCaptureBundle: Encodable {
    let sensor: ScreenSensorIdentity
    let scope = "screen_always_on"
    let captureChain = ["screen_capture_post", "heimdal_macos_screen_observer"]
    let bundleShape = "raw_capture_bundle"
    let raw: ScreenRawFrame

    enum CodingKeys: String, CodingKey {
        case sensor
        case scope
        case captureChain = "capture_chain"
        case bundleShape = "bundle_shape"
        case raw
    }

    init(
        sensor: ScreenSensorIdentity,
        application: ScreenApplication,
        frame: ScreenFrame,
        cadenceSeconds: TimeInterval
    ) {
        self.sensor = sensor
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        raw = ScreenRawFrame(
            capturedAt: formatter.string(from: frame.capturedAt),
            cadenceSeconds: cadenceSeconds,
            app: application.name,
            appBundleIdentifier: application.bundleIdentifier,
            window: frame.windowTitle,
            frame: frame.pngData.base64EncodedString()
        )
    }
}
