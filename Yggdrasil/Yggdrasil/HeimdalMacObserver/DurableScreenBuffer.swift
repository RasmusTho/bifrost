import CoreFoundation
import CryptoKit
import Darwin
import Foundation

protocol ScreenQueueFileWriting: Sendable {
    func replaceAtomically(_ data: Data, at destinationURL: URL, fileManager: FileManager) throws
}

enum ScreenQueueFileWriteError: LocalizedError {
    case beforeReplacement(Error)
    case afterReplacement(Error)

    var errorDescription: String? {
        switch self {
        case let .beforeReplacement(error), let .afterReplacement(error):
            error.localizedDescription
        }
    }
}

struct AtomicScreenQueueFileWriter: ScreenQueueFileWriting {
    func replaceAtomically(_ data: Data, at destinationURL: URL, fileManager: FileManager) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: false
            )
        do {
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            let renameResult = temporaryURL.path.withCString { sourcePath in
                destinationURL.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ScreenQueueFileWriteError.beforeReplacement(error)
        }
    }
}

struct ScreenQueueEntry: Codable, Equatable, Sendable {
    let contentIdentity: String
    let appIdentifier: String
    let binding: ScreenControlBinding
    let payload: Data

    enum CodingKeys: String, CodingKey {
        case contentIdentity = "content_identity"
        case appIdentifier = "app_identifier"
        case binding
        case payload
    }

    init(appIdentifier: String, binding: ScreenControlBinding, payload: Data) {
        self.appIdentifier = appIdentifier
        self.binding = binding
        self.payload = payload
        contentIdentity = Self.identity(appIdentifier: appIdentifier, binding: binding, payload: payload)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedIdentity = try container.decode(String.self, forKey: .contentIdentity)
        let decodedAppIdentifier = try container.decode(String.self, forKey: .appIdentifier)
        let decodedBinding = try container.decode(ScreenControlBinding.self, forKey: .binding)
        let decodedPayload = try container.decode(Data.self, forKey: .payload)
        let normalizedPayload: Data
        do {
            normalizedPayload = try Self.migratedLegacyPayload(
                from: decodedPayload,
                appIdentifier: decodedAppIdentifier
            ) ?? decodedPayload
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .payload,
                in: container,
                debugDescription: "The queued legacy screen payload could not be migrated: \(error)."
            )
        }
        let currentIdentity = Self.identity(
            appIdentifier: decodedAppIdentifier,
            binding: decodedBinding,
            payload: normalizedPayload
        )
        let previousIdentity = Self.legacyIdentity(
            appIdentifier: decodedAppIdentifier,
            binding: decodedBinding,
            payload: decodedPayload
        )
        let preMigrationIdentity = normalizedPayload == decodedPayload
            ? nil
            : Self.identity(
                appIdentifier: decodedAppIdentifier,
                binding: decodedBinding,
                payload: decodedPayload
            )
        let matchesPreMigrationIdentity = preMigrationIdentity.map { decodedIdentity == $0 } ?? false
        guard decodedIdentity == currentIdentity
            || decodedIdentity == previousIdentity
            || matchesPreMigrationIdentity else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentIdentity,
                in: container,
                debugDescription: "The queued screen capture identity did not match its payload."
            )
        }
        contentIdentity = currentIdentity
        appIdentifier = decodedAppIdentifier
        binding = decodedBinding
        payload = normalizedPayload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentIdentity, forKey: .contentIdentity)
        try container.encode(appIdentifier, forKey: .appIdentifier)
        try container.encode(binding, forKey: .binding)
        try container.encode(payload, forKey: .payload)
    }

    static func identity(appIdentifier: String, binding: ScreenControlBinding, payload: Data) -> String {
        if let hostRawPayload = Self.hostRawPayload(from: payload) {
            let digest = SHA256.hash(data: hostRawPayload)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        return Self.legacyIdentity(appIdentifier: appIdentifier, binding: binding, payload: payload)
    }

    private static func legacyIdentity(appIdentifier: String, binding: ScreenControlBinding, payload: Data) -> String {
        let context = [appIdentifier, binding.vaultIdentifier, binding.localInstanceIdentifier]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
        let digest = SHA256.hash(data: Data(context.utf8) + payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func migratedLegacyPayload(from payload: Data, appIdentifier: String) throws -> Data? {
        guard var bundle = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              var raw = bundle["raw"] as? [String: Any] else { return nil }
        let legacyFields = ["app_name", "frame_png_base64"]
        guard legacyFields.contains(where: { raw[$0] != nil }) else { return nil }

        guard raw["app"] == nil, raw["frame"] == nil else {
            throw ScreenQueuePayloadMigrationError.invalidLegacyPayload("mixed legacy and current raw fields")
        }
        guard let app = raw.removeValue(forKey: "app_name") as? String,
              let frame = raw.removeValue(forKey: "frame_png_base64") as? String else {
            throw ScreenQueuePayloadMigrationError.invalidLegacyPayload("missing app_name or frame_png_base64")
        }
        guard raw["app_bundle_id"] as? String == appIdentifier else {
            throw ScreenQueuePayloadMigrationError.invalidLegacyPayload("app_bundle_id does not match the queue entry")
        }
        guard raw["modality"] as? String == "screen",
              raw["captured_at"] is String,
              let cadence = raw["cadence_seconds"] as? NSNumber,
              cadence.doubleValue.isFinite,
              cadence.doubleValue > 0,
              raw["window_id"] is NSNumber else {
            throw ScreenQueuePayloadMigrationError.invalidLegacyPayload("invalid legacy screen metadata")
        }
        guard bundle["bundle_shape"] as? String == "raw_capture_bundle",
              bundle["scope"] as? String == "screen_always_on" else {
            throw ScreenQueuePayloadMigrationError.invalidLegacyPayload("invalid legacy bundle scope or shape")
        }

        if let legacyWindow = raw.removeValue(forKey: "window_title") {
            if legacyWindow is NSNull {
                // A nil optional was omitted by the previous JSONEncoder.
            } else if legacyWindow is String {
                raw["window"] = legacyWindow
            } else {
                throw ScreenQueuePayloadMigrationError.invalidLegacyPayload("invalid window_title")
            }
        }
        raw["app"] = app
        raw["frame"] = frame
        raw["scope"] = "screen_always_on"
        bundle["raw"] = raw
        return try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
    }

    private static func hostRawPayload(from payload: Data) -> Data? {
        guard let bundle = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let raw = bundle["raw"] else { return nil }
        if let rawText = raw as? String { return Data(rawText.utf8) }
        guard raw is [String: Any] else { return nil }
        return PythonCompatibleJSON.data(from: raw)
    }
}

private enum PythonCompatibleJSON {
    static func data(from value: Any) -> Data? {
        guard let json = encode(value) else { return nil }
        return Data(json.utf8)
    }

    private static func encode(_ value: Any) -> String? {
        if let string = value as? String { return quote(string) }
        if value is NSNull { return "null" }
        if let dictionary = value as? [String: Any] { return encode(dictionary) }
        if let array = value as? [Any] { return encode(array) }
        if let number = value as? NSNumber { return encode(number) }
        return nil
    }

    private static func encode(_ dictionary: [String: Any]) -> String? {
        var members: [String] = []
        for key in dictionary.keys.sorted() {
            guard let value = dictionary[key], let encodedValue = encode(value) else { return nil }
            members.append("\(quote(key)):\(encodedValue)")
        }
        return "{\(members.joined(separator: ","))}"
    }

    private static func encode(_ array: [Any]) -> String? {
        let members = array.compactMap { encode($0) }
        guard members.count == array.count else { return nil }
        return "[\(members.joined(separator: ","))]"
    }

    private static func encode(_ number: NSNumber) -> String? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        let type = String(cString: number.objCType)
        guard type == "d" || type == "f" else { return number.stringValue }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        let formatted = String(double)
        guard !formatted.contains(".") && !formatted.contains("e") && !formatted.contains("E") else {
            return formatted
        }
        return "\(formatted).0"
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            if let escaped = shortEscape(scalar.value) {
                result += escaped
            } else if scalar.value < 0x20 || scalar.value >= 0x7F {
                result += unicodeEscape(scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    private static func shortEscape(_ scalar: UInt32) -> String? {
        switch scalar {
        case 0x08: return "\\b"
        case 0x09: return "\\t"
        case 0x0A: return "\\n"
        case 0x0C: return "\\f"
        case 0x0D: return "\\r"
        case 0x22: return "\\\""
        case 0x5C: return "\\\\"
        default: return nil
        }
    }

    private static func unicodeEscape(_ scalar: UInt32) -> String {
        guard scalar > 0xFFFF else { return String(format: "\\u%04x", scalar) }
        let adjusted = scalar - 0x10000
        let high = 0xD800 + (adjusted >> 10)
        let low = 0xDC00 + (adjusted & 0x3FF)
        return String(format: "\\u%04x\\u%04x", high, low)
    }
}

private enum ScreenQueuePayloadMigrationError: Error {
    case invalidLegacyPayload(String)
}

struct ScreenBufferSummary: Equatable, Sendable {
    let pendingCount: Int
    let oldestEvictionCount: Int
}

enum ScreenBufferError: LocalizedError {
    case corruptQueue
    case corruptMachineIdentity
    case acknowledgementOutOfOrder

    var errorDescription: String? {
        switch self {
        case .corruptQueue:
            "The durable screen queue is unreadable. Capture remains paused and the queue file was preserved."
        case .corruptMachineIdentity:
            "The persisted machine identity is unreadable. Capture remains paused and the identity file was preserved."
        case .acknowledgementOutOfOrder:
            "A screen acknowledgement did not match the oldest queued frame. The queue remains unchanged."
        }
    }
}

actor DurableScreenBuffer {
    private struct Snapshot: Codable {
        var entries: [ScreenQueueEntry]
        var oldestEvictionCount: Int
    }

    private var entries: [ScreenQueueEntry]
    private var oldestEvictionCount: Int
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let fileWriter: ScreenQueueFileWriting

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        fileWriter: ScreenQueueFileWriting = AtomicScreenQueueFileWriter()
    ) throws {
        self.fileManager = fileManager
        self.fileWriter = fileWriter
        fileURL = directoryURL.appendingPathComponent("screen-buffer.json", isDirectory: false)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        try Self.preparePrivateDirectory(directoryURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
                guard snapshot.oldestEvictionCount >= 0,
                      snapshot.entries.allSatisfy(Self.hasValidContentIdentity) else {
                    throw ScreenBufferError.corruptQueue
                }
                entries = snapshot.entries
                oldestEvictionCount = snapshot.oldestEvictionCount
            } catch {
                throw ScreenBufferError.corruptQueue
            }
        } else {
            entries = []
            oldestEvictionCount = 0
        }
    }

    func enqueue(_ entry: ScreenQueueEntry, maximum: Int) throws {
        guard (1...10_000).contains(maximum) else { throw ScreenControlDecodeError.invalidOrAmbiguousControls }
        let oldEntries = entries
        let oldEvictionCount = oldestEvictionCount
        while entries.count >= maximum {
            entries.removeFirst()
            oldestEvictionCount += 1
        }
        entries.append(entry)
        do {
            try persist()
        } catch {
            entries = oldEntries
            oldestEvictionCount = oldEvictionCount
            throw error
        }
    }

    func firstEntry() -> ScreenQueueEntry? {
        entries.first
    }

    func acknowledgeOldest(contentIdentity: String) throws {
        guard entries.first?.contentIdentity == contentIdentity else {
            throw ScreenBufferError.acknowledgementOutOfOrder
        }
        let oldEntries = entries
        entries.removeFirst()
        do {
            try persist()
        } catch {
            entries = oldEntries
            throw error
        }
    }

    func summary() -> ScreenBufferSummary {
        ScreenBufferSummary(pendingCount: entries.count, oldestEvictionCount: oldestEvictionCount)
    }

    func identities() -> [String] {
        entries.map(\.contentIdentity)
    }

    private static func hasValidContentIdentity(_ entry: ScreenQueueEntry) -> Bool {
        let identity = ScreenQueueEntry.identity(
            appIdentifier: entry.appIdentifier,
            binding: entry.binding,
            payload: entry.payload
        )
        return identity == entry.contentIdentity
    }

    private func persist() throws {
        let snapshot = Snapshot(entries: entries, oldestEvictionCount: oldestEvictionCount)
        do {
            try fileWriter.replaceAtomically(encoder.encode(snapshot), at: fileURL, fileManager: fileManager)
        } catch let error as ScreenQueueFileWriteError {
            switch error {
            case let .beforeReplacement(underlying):
                throw underlying
            case .afterReplacement:
                return
            }
        }
    }

    private static func preparePrivateDirectory(_ directoryURL: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }
}

struct ScreenMachineIdentityStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private let fileWriter: ScreenQueueFileWriting

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        fileWriter: ScreenQueueFileWriting = AtomicScreenQueueFileWriter()
    ) throws {
        self.fileManager = fileManager
        self.fileWriter = fileWriter
        fileURL = directoryURL.appendingPathComponent("machine-id", isDirectory: false)
        try DurableScreenBuffer.prepareDirectoryForIdentity(directoryURL, fileManager: fileManager)
    }

    func loadOrCreate() throws -> String {
        if fileManager.fileExists(atPath: fileURL.path) {
            let value = try String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: value) != nil else { throw ScreenBufferError.corruptMachineIdentity }
            return value
        }

        let value = UUID().uuidString.lowercased()
        try fileWriter.replaceAtomically(Data(value.utf8), at: fileURL, fileManager: fileManager)
        return value
    }
}

extension DurableScreenBuffer {
    fileprivate static func prepareDirectoryForIdentity(_ directoryURL: URL, fileManager: FileManager) throws {
        try preparePrivateDirectory(directoryURL, fileManager: fileManager)
    }
}

enum ScreenObserverStorage {
    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("Bifrost", isDirectory: true)
            .appendingPathComponent("HeimdalMacObserver", isDirectory: true)
    }
}
