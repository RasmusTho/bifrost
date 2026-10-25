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

    static func identity(appIdentifier: String, binding: ScreenControlBinding, payload: Data) -> String {
        let context = [appIdentifier, binding.vaultIdentifier, binding.localInstanceIdentifier]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
        let digest = SHA256.hash(data: Data(context.utf8) + payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
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
