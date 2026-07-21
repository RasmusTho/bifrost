import Combine
import Foundation

struct WatchRelayTransfer: Equatable {
    let identifier: UUID
    let fileURL: URL?

    init(identifier: UUID, fileURL: URL? = nil) {
        self.identifier = identifier
        self.fileURL = fileURL
    }
}

protocol WatchRelayTransferring {
    func transfer(fileURL: URL) throws -> WatchRelayTransfer
    func outstandingFileURLs() -> Set<URL>
}

/// Disk remains the custody ledger. A transfer acknowledgement is the only
/// condition that may remove a Watch recording from that ledger.
@MainActor
final class WatchRelayCustody: ObservableObject {
    @Published private(set) var queuedFiles: [URL] = []
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private var transfers: [UUID: URL] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var queuedCount: Int { queuedFiles.count }

    func rebuildQueue(from directoryURL: URL) {
        let files = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        queuedFiles = files.filter { $0.pathExtension.lowercased() == "m4a" }
        lastError = nil
    }

    /// Reconciles disk (the custody ledger) with WatchConnectivity's retained
    /// transfer queue on relaunch. Files not already owned by an outstanding
    /// transfer are submitted again; every file stays on disk until a confirmed
    /// completion callback removes it.
    func reconcileQueue(from directoryURL: URL, using transport: WatchRelayTransferring) {
        rebuildQueue(from: directoryURL)
        let outstanding = Set(transport.outstandingFileURLs().map(normalizedURL))
        for fileURL in queuedFiles where !outstanding.contains(normalizedURL(fileURL)) {
            _ = enqueue(fileURL: fileURL, using: transport)
        }
    }

    @discardableResult
    func enqueue(fileURL: URL, using transport: WatchRelayTransferring) -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastError = "The Watch recording is no longer available."
            return false
        }
        if !queuedFiles.contains(fileURL) { queuedFiles.append(fileURL) }

        do {
            let transfer = try transport.transfer(fileURL: fileURL)
            transfers[transfer.identifier] = fileURL
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Called only by WatchConnectivity's `didFinish(_:error:)` callback.
    /// A failed hand-off deliberately leaves the file on disk and in the queue.
    func complete(transfer: WatchRelayTransfer, error: Error?) {
        guard let fileURL = transfers.removeValue(forKey: transfer.identifier) ?? transfer.fileURL else { return }
        guard error == nil else {
            lastError = error?.localizedDescription
            return
        }

        do {
            try fileManager.removeItem(at: fileURL)
            queuedFiles.removeAll { $0 == fileURL }
            lastError = nil
        } catch {
            // A confirmed transfer with a retained file is safe: it stays visible
            // until a later retry can reconcile custody.
            if !queuedFiles.contains(fileURL) { queuedFiles.append(fileURL) }
            lastError = error.localizedDescription
        }
    }

    private func normalizedURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
