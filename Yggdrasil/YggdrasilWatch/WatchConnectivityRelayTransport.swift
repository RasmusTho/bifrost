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

    func transfer(fileURL: URL) throws -> WatchRelayTransfer {
        guard WCSession.isSupported() else { throw WatchRelayTransportError.unavailable }
        let transfer = WCSession.default.transferFile(fileURL, metadata: nil)
        let token = WatchRelayTransfer(identifier: UUID())
        transferIDs[ObjectIdentifier(transfer)] = token
        return token
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let token = transferIDs.removeValue(forKey: ObjectIdentifier(fileTransfer)) else { return }
        completion?(token, error)
    }
}

private enum WatchRelayTransportError: LocalizedError {
    case unavailable
    var errorDescription: String? { "WatchConnectivity is unavailable; the recording remains queued." }
}
