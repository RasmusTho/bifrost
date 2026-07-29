import Foundation
import SwiftUI
import YggdrasilCore

enum MimerEntityCandidateAvailability: Equatable, Sendable {
    case note
    case missing
    case unreadable(String)
}

struct MimerEntityCandidate: Identifiable, Equatable, Sendable {
    var id: String { entityID }

    let entityID: String
    let relativePath: String
    let label: String
    let kind: String?
    let lifecycle: String?
    let markdown: String
    let availability: MimerEntityCandidateAvailability
}

enum MimerEntityCandidateResolver {
    /// Mirrors the canonical slug mapping owned by the hub's
    /// `app/heimdal/entity_register.py`. Bifrost only resolves these notes;
    /// it never creates or edits them.
    static func registerPath(for entityID: String) -> String {
        var slug = ""
        var previousWasSeparator = false
        for scalar in entityID.replacingOccurrences(of: ":", with: "-").unicodeScalars {
            let isASCIIAlphaNumeric = (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
            if isASCIIAlphaNumeric {
                slug.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !slug.isEmpty, !previousWasSeparator {
                slug.append("-")
                previousWasSeparator = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
        if slug.isEmpty { slug = "entity" }
        return "_heimdal/register/\(slug).md"
    }

    static func resolve(
        _ entityIDs: [String],
        using fileStore: VaultFileStore
    ) async -> [MimerEntityCandidate] {
        let paths = entityIDs.map(registerPath(for:))
        let results = await fileStore.readMany(paths)
        return zip(entityIDs, paths).map { entityID, path in
            guard let result = results[path] else {
                return missingCandidate(entityID: entityID, path: path)
            }
            switch result {
            case .success(let text):
                do {
                    let document = try FrontmatterDocument.parse(text)
                    return MimerEntityCandidate(
                        entityID: entityID,
                        relativePath: path,
                        label: document.frontmatter["label"]?.stringValue ?? entityID,
                        kind: document.frontmatter["kind"]?.stringValue,
                        lifecycle: document.frontmatter["lifecycle"]?.stringValue,
                        markdown: text,
                        availability: .note
                    )
                } catch {
                    return MimerEntityCandidate(
                        entityID: entityID,
                        relativePath: path,
                        label: entityID,
                        kind: nil,
                        lifecycle: nil,
                        markdown: "",
                        availability: .unreadable(error.localizedDescription)
                    )
                }
            case .failure(let error):
                if case VaultFileStoreError.notFound = error {
                    return missingCandidate(entityID: entityID, path: path)
                }
                return MimerEntityCandidate(
                    entityID: entityID,
                    relativePath: path,
                    label: entityID,
                    kind: nil,
                    lifecycle: nil,
                    markdown: "",
                    availability: .unreadable(error.localizedDescription)
                )
            }
        }
    }

    private static func missingCandidate(entityID: String, path: String) -> MimerEntityCandidate {
        MimerEntityCandidate(
            entityID: entityID,
            relativePath: path,
            label: entityID,
            kind: nil,
            lifecycle: nil,
            markdown: "",
            availability: .missing
        )
    }
}

enum MimerEntityDecision: Equatable, Sendable {
    case merge(candidateID: String)
    case reject
}

enum MimerEntityDecisionWrite: Equatable, Sendable {
    case merge(candidateID: String)
    case reject
    case undo
}

enum MimerEntityDecisionWriteError: LocalizedError, Equatable {
    case staleAuthorityState

    var errorDescription: String? {
        switch self {
        case .staleAuthorityState:
            "Entity review changed after it was loaded. Reload before recording another decision."
        }
    }
}

struct MimerEntityPendingAuthority: Equatable, Sendable {
    let queueEntryID: String
    let canonicalRow: String

    static func capture(
        for queueEntryID: String,
        in document: FrontmatterDocument
    ) -> MimerEntityPendingAuthority? {
        guard let pending = document.frontmatter["pending"]?.arrayValue else {
            return nil
        }
        let matchingRows = pending.filter {
            $0.mapValue?["queue_entry_id"]?.stringValue == queueEntryID
        }
        guard matchingRows.count == 1, let row = matchingRows.first else {
            return nil
        }
        return MimerEntityPendingAuthority(
            queueEntryID: queueEntryID,
            canonicalRow: YAMLCodec.serialize(row)
        )
    }
}

struct MimerEntityDecisionAuthority: Equatable, Sendable {
    let queueEntryID: String
    let canonicalRows: [String]
    let effectiveDecision: MimerEntityDecision?

    static func capture(
        for queueEntryID: String,
        in document: FrontmatterDocument
    ) -> MimerEntityDecisionAuthority {
        guard let decisions = document.frontmatter["decisions"]?.arrayValue else {
            return MimerEntityDecisionAuthority(
                queueEntryID: queueEntryID,
                canonicalRows: [],
                effectiveDecision: nil
            )
        }
        var effective: MimerEntityDecision?
        var canonicalRows: [String] = []
        for decision in decisions {
            guard let map = decision.mapValue,
                  map["queue_entry_id"]?.stringValue == queueEntryID else {
                continue
            }
            canonicalRows.append(YAMLCodec.serialize(decision))
            guard let action = map["action"]?.stringValue else {
                continue
            }
            switch action {
            case "merge":
                if let candidateID = map["into_id"]?.stringValue {
                    effective = .merge(candidateID: candidateID)
                }
            case "reject":
                effective = .reject
            case "undo":
                effective = nil
            default:
                continue
            }
        }
        return MimerEntityDecisionAuthority(
            queueEntryID: queueEntryID,
            canonicalRows: canonicalRows,
            effectiveDecision: effective
        )
    }
}

struct MimerEntityAuthoritySnapshot: Equatable, Sendable {
    let pending: MimerEntityPendingAuthority
    let decision: MimerEntityDecisionAuthority

    static func capture(
        for queueEntryID: String,
        in document: FrontmatterDocument
    ) -> MimerEntityAuthoritySnapshot? {
        guard let pending = MimerEntityPendingAuthority.capture(
            for: queueEntryID,
            in: document
        ) else {
            return nil
        }
        return MimerEntityAuthoritySnapshot(
            pending: pending,
            decision: MimerEntityDecisionAuthority.capture(
                for: queueEntryID,
                in: document
            )
        )
    }
}

enum MimerEntityDecisionWriter {
    static func append(
        _ decision: MimerEntityDecisionWrite,
        for entry: EntityReviewEntry,
        expectedAuthority: MimerEntityAuthoritySnapshot,
        decidedAt: String,
        using fileStore: VaultFileStore
    ) async throws {
        let queueEntryID = entry.id
        let mentionID = entry.mentionId
        let action: String
        let intoID: String
        switch decision {
        case .merge(let candidateID):
            action = "merge"
            intoID = candidateID
        case .reject:
            action = "reject"
            intoID = ""
        case .undo:
            action = "undo"
            intoID = ""
        }

        try await fileStore.readModifyWrite(
            HeimdalPaths.entityReview,
            sourcePreservingAppendToRootSequence: "decisions"
        ) { document in
            // The compare UI is an ephemeral lens. Revalidate the complete,
            // freshly coordinated authority document at the mutation seam so
            // a stale enabled action cannot append to a shape the hub cannot
            // safely consume.
            _ = try EntityReviewNote(document: document).validatedPending()
            guard MimerEntityPendingAuthority.capture(
                for: queueEntryID,
                in: document
            ) == expectedAuthority.pending,
                MimerEntityDecisionAuthority.capture(
                    for: queueEntryID,
                    in: document
                ) == expectedAuthority.decision else {
                throw MimerEntityDecisionWriteError.staleAuthorityState
            }
            var review = EntityReviewNote(document: document)
            review.addDecision(
                queueEntryId: queueEntryID,
                action: action,
                fromId: mentionID,
                intoId: intoID,
                decidedAt: decidedAt
            )
            document = review.document
        }
    }
}

@MainActor
final class MimerEntityCompareModel: ObservableObject {
    @Published private(set) var pending: [EntityReviewEntry] = []
    @Published private(set) var selectedEntryID: String?
    @Published private(set) var candidates: [MimerEntityCandidate] = []
    @Published private(set) var selectedCandidateID: String?
    @Published private(set) var effectiveDecision: MimerEntityDecision?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isWriting = false

    let fileStore: VaultFileStore
    private let timestampProvider: @Sendable () -> String
    private var reviewDocument: FrontmatterDocument?
    private var candidateLoadID = UUID()

    init(
        fileStore: VaultFileStore,
        timestampProvider: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.fileStore = fileStore
        self.timestampProvider = timestampProvider
    }

    var selectedEntry: EntityReviewEntry? {
        pending.first { $0.id == selectedEntryID }
    }

    var canMerge: Bool {
        reviewDocument != nil
            && loadError == nil
            && selectedCandidateID != nil
            && selectedAuthority != nil
            && effectiveDecision == nil
            && !isLoading
            && !isWriting
    }

    var canReject: Bool {
        reviewDocument != nil
            && loadError == nil
            && selectedEntry != nil
            && selectedAuthority != nil
            && effectiveDecision == nil
            && !isLoading
            && !isWriting
    }

    var canUndo: Bool {
        reviewDocument != nil
            && loadError == nil
            && selectedAuthority != nil
            && effectiveDecision != nil
            && !isLoading
            && !isWriting
    }

    var decisionStatus: String {
        switch effectiveDecision {
        case .merge(let candidateID):
            "Merge proposed: \(candidateID)"
        case .reject:
            "Reject proposed"
        case nil:
            "Undecided locally"
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let text = try await fileStore.read(HeimdalPaths.entityReview)
            let document = try FrontmatterDocument.parse(text)
            let entries = try EntityReviewNote(document: document).validatedPending()
            reviewDocument = document
            pending = entries
            if !entries.contains(where: { $0.id == selectedEntryID }) {
                selectedEntryID = entries.first?.id
            }
            loadError = nil
            await loadSelectedCandidates(preservingSelection: true)
        } catch VaultFileStoreError.notFound {
            clearLoadedReviewState()
            loadError = nil
        } catch {
            clearLoadedReviewState()
            loadError = error.localizedDescription
        }
    }

    func selectEntry(_ entryID: String) {
        guard selectedEntryID != entryID else { return }
        selectedEntryID = entryID
        selectedCandidateID = nil
        candidates = []
        effectiveDecision = effectiveDecisionForSelectedEntry()
        Task { await loadSelectedCandidates(preservingSelection: false) }
    }

    func selectCandidate(_ entityID: String) {
        guard candidates.contains(where: { $0.entityID == entityID }) else { return }
        selectedCandidateID = entityID
    }

    func merge() async {
        guard canMerge, let selectedCandidateID else { return }
        await append(.merge(candidateID: selectedCandidateID))
    }

    func reject() async {
        guard canReject else { return }
        await append(.reject)
    }

    func undo() async {
        guard canUndo else { return }
        await append(.undo)
    }

    private func append(_ decision: MimerEntityDecisionWrite) async {
        guard let entry = selectedEntry,
              let expectedAuthority = selectedAuthority else {
            return
        }
        isWriting = true
        defer { isWriting = false }
        do {
            try await MimerEntityDecisionWriter.append(
                decision,
                for: entry,
                expectedAuthority: expectedAuthority,
                decidedAt: timestampProvider(),
                using: fileStore
            )
            loadError = nil
            await load()
        } catch {
            clearLoadedReviewState()
            loadError = error.localizedDescription
        }
    }

    private func clearLoadedReviewState() {
        candidateLoadID = UUID()
        reviewDocument = nil
        pending = []
        selectedEntryID = nil
        candidates = []
        selectedCandidateID = nil
        effectiveDecision = nil
    }

    private func loadSelectedCandidates(preservingSelection: Bool) async {
        guard let entry = selectedEntry else {
            candidates = []
            selectedCandidateID = nil
            effectiveDecision = nil
            return
        }
        let loadID = UUID()
        candidateLoadID = loadID
        let resolved = await MimerEntityCandidateResolver.resolve(
            entry.candidateEntityIDs,
            using: fileStore
        )
        guard candidateLoadID == loadID, selectedEntryID == entry.id else { return }
        candidates = resolved
        if !preservingSelection
            || !resolved.contains(where: { $0.entityID == selectedCandidateID }) {
            selectedCandidateID = nil
        }
        effectiveDecision = effectiveDecisionForSelectedEntry()
    }

    private func effectiveDecisionForSelectedEntry() -> MimerEntityDecision? {
        selectedAuthority?.decision.effectiveDecision
    }

    private var selectedAuthority: MimerEntityAuthoritySnapshot? {
        guard let selectedEntryID, let reviewDocument else {
            return nil
        }
        return MimerEntityAuthoritySnapshot.capture(
            for: selectedEntryID,
            in: reviewDocument
        )
    }
}
