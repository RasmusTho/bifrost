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

/// Copies a WatchConnectivity-owned file into durable iPhone staging while its
/// delegate callback still owns the source URL. WatchConnectivity removes the
/// source as soon as that callback returns, so this seam deliberately has no
/// actor hop or deferred work.
final class WatchRelayFileStager {
    private let stagingDirectory: URL
    private let fileManager: FileManager

    init(
        stagingDirectory: URL = CaptureStagingPaths.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.stagingDirectory = stagingDirectory
        self.fileManager = fileManager
    }

    func stage(fileURL: URL) throws -> URL {
        guard fileManager.fileExists(atPath: fileURL.path) else { throw WatchRelayReceiveError.missingFile }
        guard fileURL.pathExtension.lowercased() == "m4a" else {
            throw WatchRelayReceiveError.invalidExtension
        }

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destinationURL = stagingDirectory.appendingPathComponent(
            "watch-\(UUID().uuidString.lowercased()).m4a"
        )
        try fileManager.copyItem(at: fileURL, to: destinationURL)
        return destinationURL
    }
}

/// Phone-side bridge into the existing HCAP-03 queue. It creates no parallel
/// delivery path: newly received Watch files become ordinary staged items.
final class WatchRelayStagingReceiver {
    private let sessionModel: CaptureSessionModel
    private let fileStager: WatchRelayFileStager

    init(
        sessionModel: CaptureSessionModel,
        stagingDirectory: URL = CaptureStagingPaths.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.sessionModel = sessionModel
        fileStager = WatchRelayFileStager(
            stagingDirectory: stagingDirectory,
            fileManager: fileManager
        )
    }

    @discardableResult
    @MainActor
    func receive(fileURL: URL, capturedAt: Date = Date()) throws -> URL {
        let stagedURL = try fileStager.stage(fileURL: fileURL)
        register(stagedURL: stagedURL, capturedAt: capturedAt)
        return stagedURL
    }

    /// Registers a file that has already crossed the callback-lifetime seam.
    /// The durable file is sufficient for `CaptureRecorder` to recover after a
    /// process kill before this main-actor bookkeeping can run.
    @MainActor
    func register(stagedURL: URL, capturedAt: Date = Date()) {
        sessionModel.recoverStagedItem(
            url: stagedURL,
            duration: 0,
            capturedAt: capturedAt
        )
    }
}

protocol WatchRelayActivating: AnyObject {
    func activate()
}

/// The only iPhone WatchConnectivity ingress. It delegates every received
/// recording to `WatchRelayStagingReceiver`, then normal HCAP-03 delivery owns it.
final class WatchRelayReceiver: NSObject, ObservableObject, WCSessionDelegate {
    private let stagingReceiver: WatchRelayStagingReceiver
    private let fileStager: WatchRelayFileStager
    @Published private(set) var lastReceiveError: String?

    init(
        sessionModel: CaptureSessionModel,
        stagingDirectory: URL = CaptureStagingPaths.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        stagingReceiver = WatchRelayStagingReceiver(
            sessionModel: sessionModel,
            stagingDirectory: stagingDirectory,
            fileManager: fileManager
        )
        fileStager = WatchRelayFileStager(
            stagingDirectory: stagingDirectory,
            fileManager: fileManager
        )
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
        receiveIncomingFile(at: file.fileURL)
    }

    /// The delegate's synchronous callback-lifetime seam. The source is copied
    /// before returning; only model bookkeeping is deferred to the main actor.
    @discardableResult
    func receiveIncomingFile(at fileURL: URL, capturedAt: Date = Date()) -> Bool {
        do {
            let stagedURL = try fileStager.stage(fileURL: fileURL)
            Task { @MainActor [stagingReceiver] in
                stagingReceiver.register(stagedURL: stagedURL, capturedAt: capturedAt)
            }
            return true
        } catch {
            Task { @MainActor [weak self] in
                self?.lastReceiveError = error.localizedDescription
            }
            return false
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}

extension WatchRelayReceiver: WatchRelayActivating {}

/// Retains and activates phone-side WatchConnectivity ingress before the
/// auth/vault/UI tree is evaluated, including a background WC launch.
@MainActor
final class WatchRelayStartup: ObservableObject {
    private let receiver: WatchRelayActivating
    let sessionModel: CaptureSessionModel

    init(receiver: WatchRelayActivating? = nil) {
        let sessionModel = CaptureSessionModel()
        self.sessionModel = sessionModel
        if let receiver {
            self.receiver = receiver
        } else {
            self.receiver = WatchRelayReceiver(sessionModel: sessionModel)
        }
        self.receiver.activate()
    }
}
