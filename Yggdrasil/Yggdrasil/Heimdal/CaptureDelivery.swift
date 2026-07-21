import Combine
import Foundation

enum CaptureDeliveryError: LocalizedError {
    case missingSource
    case invalidSourceName
    case finalNameCollision
    case incompletePlacement
    case coordinationDidNotRun
    case noReachableCaptureFolder

    var errorDescription: String? {
        switch self {
        case .missingSource:
            "The staged recording is no longer available."
        case .invalidSourceName:
            "Only finalized .m4a recordings can enter the capture folder."
        case .finalNameCollision:
            "A different recording already uses this final name in the capture folder."
        case .incompletePlacement:
            "Heimdal could not confirm the complete recording in the capture folder."
        case .coordinationDidNotRun:
            "The Files provider did not grant coordinated write access."
        case .noReachableCaptureFolder:
            "No reachable capture folder is bound. Pick the folder again, then retry."
        }
    }
}

protocol CaptureDeliveryCoordinating {
    func coordinateWrite(in folderURL: URL, operation: (URL) throws -> Void) throws
}

/// Production Files-provider seam. Coordinating the directory with `.forMerging`
/// covers both creation of the non-admissible child and its same-directory rename.
struct NSFileCoordinatorCaptureDeliveryAccess: CaptureDeliveryCoordinating {
    func coordinateWrite(in folderURL: URL, operation: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<Void, Error>?
        coordinator.coordinate(
            writingItemAt: folderURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedFolderURL in
            operationResult = Result { try operation(coordinatedFolderURL) }
        }

        if let coordinationError { throw coordinationError }
        guard let operationResult else { throw CaptureDeliveryError.coordinationDidNotRun }
        try operationResult.get()
    }
}

protocol CaptureBytesCopying {
    func copy(from sourceURL: URL, to destinationURL: URL) throws
}

struct FileManagerCaptureBytesCopier: CaptureBytesCopying {
    func copy(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

protocol CaptureFilePlacing {
    func place(stagedURL: URL, in folderURL: URL) throws -> URL
}

/// Performs the custody hand-off up to confirmed final placement. It never
/// deletes the staging source; `CaptureDeliveryQueue` owns that later boundary.
struct CaptureDeliveryFilePlacer: CaptureFilePlacing {
    private let coordinator: CaptureDeliveryCoordinating
    private let bytesCopier: CaptureBytesCopying
    private let fileManager: FileManager

    init(
        coordinator: CaptureDeliveryCoordinating = NSFileCoordinatorCaptureDeliveryAccess(),
        bytesCopier: CaptureBytesCopying = FileManagerCaptureBytesCopier(),
        fileManager: FileManager = .default
    ) {
        self.coordinator = coordinator
        self.bytesCopier = bytesCopier
        self.fileManager = fileManager
    }

    func place(stagedURL: URL, in folderURL: URL) throws -> URL {
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            throw CaptureDeliveryError.missingSource
        }
        guard stagedURL.pathExtension.lowercased() == "m4a" else {
            throw CaptureDeliveryError.invalidSourceName
        }

        var placedURL: URL?
        try coordinator.coordinateWrite(in: folderURL) { coordinatedFolderURL in
            let finalURL = coordinatedFolderURL.appendingPathComponent(stagedURL.lastPathComponent)
            let tempURL = coordinatedFolderURL.appendingPathComponent(
                "\(stagedURL.lastPathComponent).uploading"
            )

            if fileManager.fileExists(atPath: finalURL.path) {
                guard try filesMatch(stagedURL, finalURL) else {
                    throw CaptureDeliveryError.finalNameCollision
                }
                placedURL = finalURL
                return
            }

            if fileManager.fileExists(atPath: tempURL.path) {
                try fileManager.removeItem(at: tempURL)
            }
            try bytesCopier.copy(from: stagedURL, to: tempURL)

            // Both URLs are children of the same coordinated provider directory,
            // so `moveItem` is the atomic admissibility boundary.
            try fileManager.moveItem(at: tempURL, to: finalURL)
            guard try filesHaveSameSize(stagedURL, finalURL) else {
                throw CaptureDeliveryError.incompletePlacement
            }
            placedURL = finalURL
        }

        guard let placedURL else { throw CaptureDeliveryError.coordinationDidNotRun }
        return placedURL
    }

    private func filesHaveSameSize(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let firstValues = try firstURL.resourceValues(forKeys: keys)
        let secondValues = try secondURL.resourceValues(forKeys: keys)
        guard firstValues.isRegularFile == true,
              secondValues.isRegularFile == true,
              let firstSize = firstValues.fileSize,
              let secondSize = secondValues.fileSize else { return false }
        return firstSize == secondSize
    }

    private func filesMatch(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        guard try filesHaveSameSize(firstURL, secondURL) else { return false }
        let firstHandle = try FileHandle(forReadingFrom: firstURL)
        let secondHandle = try FileHandle(forReadingFrom: secondURL)
        defer {
            try? firstHandle.close()
            try? secondHandle.close()
        }

        while true {
            let firstChunk = try firstHandle.read(upToCount: 64 * 1_024) ?? Data()
            let secondChunk = try secondHandle.read(upToCount: 64 * 1_024) ?? Data()
            guard firstChunk == secondChunk else { return false }
            if firstChunk.isEmpty { return true }
        }
    }
}

/// A disk-backed retry queue: the durable ledger is the set of validated `.m4a`
/// files still in staging. In-memory states exist to explain the current attempt;
/// relaunch reconstruction deliberately turns every retained valid file into staged.
@MainActor
final class CaptureDeliveryQueue: ObservableObject {
    private let sessionModel: CaptureSessionModel
    private let placer: CaptureFilePlacing
    private let fileManager: FileManager

    init(
        sessionModel: CaptureSessionModel,
        placer: CaptureFilePlacing = CaptureDeliveryFilePlacer(),
        fileManager: FileManager = .default
    ) {
        self.sessionModel = sessionModel
        self.placer = placer
        self.fileManager = fileManager
    }

    func deliver(itemID: UUID, to folderURL: URL?) async {
        guard let item = sessionModel.stagedItems.first(where: { $0.id == itemID }) else { return }
        switch item.deliveryState {
        case .delivering, .deliveredAwaitingSync:
            return
        case .staged, .failed:
            break
        }

        let startedAt = Date()
        _ = sessionModel.updateDeliveryState(for: itemID, to: .delivering(startedAt: startedAt))
        guard let folderURL else {
            recordFailure(CaptureDeliveryError.noReachableCaptureFolder, for: itemID)
            return
        }

        let placer = self.placer
        let fileManager = self.fileManager
        do {
            try await Task.detached(priority: .utility) {
                _ = try placer.place(stagedURL: item.url, in: folderURL)
                // Placement has returned only after the final admissible name exists.
                // Deletion is deliberately outside the placer and strictly after it.
                try fileManager.removeItem(at: item.url)
            }.value
            _ = sessionModel.updateDeliveryState(
                for: itemID,
                to: .deliveredAwaitingSync(placedAt: Date())
            )
        } catch {
            recordFailure(error, for: itemID)
        }
    }

    func retryUndelivered(to folderURL: URL?) async {
        let itemIDs = sessionModel.stagedItems.compactMap { item -> UUID? in
            switch item.deliveryState {
            case .staged, .failed:
                item.id
            case .delivering, .deliveredAwaitingSync:
                nil
            }
        }
        for itemID in itemIDs {
            await deliver(itemID: itemID, to: folderURL)
        }
    }

    func deliverNewlyStaged(to folderURL: URL?) async {
        let itemIDs = sessionModel.stagedItems.compactMap { item in
            item.deliveryState == .staged ? item.id : nil
        }
        for itemID in itemIDs {
            await deliver(itemID: itemID, to: folderURL)
        }
    }

    private func recordFailure(_ error: Error, for itemID: UUID) {
        _ = sessionModel.updateDeliveryState(
            for: itemID,
            to: .failed(message: error.localizedDescription, at: Date())
        )
    }
}
