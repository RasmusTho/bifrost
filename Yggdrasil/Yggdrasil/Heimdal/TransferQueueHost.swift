import Foundation
import SwiftUI

/// Status source used when no hub address is configured, or when the hub simply
/// is not answering. It throws rather than returning "nothing is happening",
/// because those are different statements and only one of them is true.
struct UnreachableHubStatusSource: TransferQueueStatusSource {
    func statuses(forCaptureIDs captureIDs: [String]) async throws -> [String: HubItemStatus] {
        throw URLError(.cannotConnectToHost)
    }
}

/// DEBUG-only scripted source for the composed UI journey: the hub is down for
/// the first query and answers afterwards, which is exactly the offline →
/// complete arc the journey walks. Inert in release like every other
/// `UITestLaunchConfiguration` seam.
final class ScriptedHubStatusSource: TransferQueueStatusSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queriesAnswered = 0

    func statuses(forCaptureIDs captureIDs: [String]) async throws -> [String: HubItemStatus] {
        lock.lock()
        queriesAnswered += 1
        let answered = queriesAnswered
        lock.unlock()

        guard answered > 1 else { throw URLError(.cannotConnectToHost) }
        return Dictionary(uniqueKeysWithValues: captureIDs.map { captureID in
            (captureID, HubItemStatus(captureID: captureID, progress: .complete, observedAt: Date()))
        })
    }
}

/// Builds the queue surface over the real CDLM-03 outbox store.
///
/// The host owns no state of its own: one store feeds this surface and the JD
/// health panel, so there is no second bookkeeping to drift.
struct TransferQueueHost: View {
    @StateObject private var model: TransferQueueViewModel

    init(
        store: TransferOutboxStore = TransferOutboxStore(),
        statusSource: TransferQueueStatusSource = UnreachableHubStatusSource()
    ) {
        _model = StateObject(
            wrappedValue: TransferQueueViewModel(store: store, statusSource: statusSource)
        )
    }

    var body: some View {
        NavigationStack {
            TransferQueueView(model: model)
                .navigationTitle("Queue")
        }
        .task { await model.loadOnColdLaunch() }
    }
}
