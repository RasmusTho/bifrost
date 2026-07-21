import Combine
import Foundation
import WatchConnectivity

enum CaptureStagingPaths {
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heimdal/Staging", isDirectory: true)
    }
}

enum WatchRelayReceiveError: LocalizedError {
    case missingFile
    case invalidExtension

    var errorDescription: String? {
        switch self {
        case .missingFile: "The Watch relay file was unavailable before it reached staging."
        case .invalidExtension: "Only finalized .m4a Watch recordings may enter staging."
        }
    }
}

/// Phone-side bridge into the existing HCAP-03 queue. It creates no parallel
/// delivery path: newly received Watch files become ordinary staged items.
final class WatchRelayStagingReceiver {
    private let sessionModel: CaptureSessionModel
    private let stagingDirectory: URL
    private let fileManager: FileManager

    init(
        sessionModel: CaptureSessionModel,
        stagingDirectory: URL = CaptureStagingPaths.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.sessionModel = sessionModel
        self.stagingDirectory = stagingDirectory
        self.fileManager = fileManager
    }

    @discardableResult
    @MainActor
    func receive(fileURL: URL, capturedAt: Date = Date()) throws -> URL {
        guard fileManager.fileExists(atPath: fileURL.path) else { throw WatchRelayReceiveError.missingFile }
        guard fileURL.pathExtension.lowercased() == "m4a" else { throw WatchRelayReceiveError.invalidExtension }

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destinationURL = stagingDirectory.appendingPathComponent(
            "watch-\(UUID().uuidString.lowercased()).m4a"
        )
        try fileManager.copyItem(at: fileURL, to: destinationURL)
        sessionModel.recoverStagedItem(
            url: destinationURL,
            duration: 0,
            capturedAt: capturedAt
        )
        return destinationURL
    }
}

/// The only iPhone WatchConnectivity ingress. It delegates every received
/// recording to `WatchRelayStagingReceiver`, then normal HCAP-03 delivery owns it.
final class WatchRelayReceiver: NSObject, ObservableObject, WCSessionDelegate {
    private let stagingReceiver: WatchRelayStagingReceiver

    init(sessionModel: CaptureSessionModel) {
        stagingReceiver = WatchRelayStagingReceiver(sessionModel: sessionModel)
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor [stagingReceiver] in
            _ = try? stagingReceiver.receive(fileURL: file.fileURL)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
