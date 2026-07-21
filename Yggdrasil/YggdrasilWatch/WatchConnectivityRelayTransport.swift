import Foundation
import WatchConnectivity

/// Wraps WatchConnectivity without giving the Watch any network capability.
/// File transfer is queued by the OS and acknowledged through `didFinish`.
final class WatchConnectivityRelayTransport: NSObject, WatchRelayTransferring, WCSessionDelegate {
    var completion: ((WatchRelayTransfer, Error?) -> Void)?

    private var transferIDs: [ObjectIdentifier: WatchRelayTransfer] = [:]

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func transfer(
        fileURL: URL,
        metadata: WatchRelayCaptureMetadata?
    ) throws -> WatchRelayTransfer {
        guard WCSession.isSupported() else { throw WatchRelayTransportError.unavailable }
        let transfer = WCSession.default.transferFile(
            fileURL,
            metadata: try metadata?.transferMetadata()
        )
        let token = WatchRelayTransfer(identifier: UUID(), fileURL: fileURL)
        transferIDs[ObjectIdentifier(transfer)] = token
        return token
    }

    func outstandingFileURLs() -> Set<URL> {
        guard WCSession.isSupported() else { return [] }
        return Set(WCSession.default.outstandingFileTransfers.map { $0.file.fileURL })
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let token = transferIDs.removeValue(forKey: ObjectIdentifier(fileTransfer))
            ?? WatchRelayTransfer(identifier: UUID(), fileURL: fileTransfer.file.fileURL)
        completion?(token, error)
    }
}

private enum WatchRelayTransportError: LocalizedError {
    case unavailable
    var errorDescription: String? { "WatchConnectivity is unavailable; the recording remains queued." }
}
