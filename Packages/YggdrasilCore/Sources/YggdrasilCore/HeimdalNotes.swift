import Foundation

/// Typed wrappers over `_heimdal/**` notes. Each wrapper only reads/writes
/// the fields the Mimer-iPhone lenses are authoritative for (per the
/// human-editable / agent-authored split declared by `app/heimdal/*` in the
/// hub repo); every other field on the note is preserved untouched on
/// read-merge-write, so a client save never clobbers backend-owned state.
public protocol HeimdalNote {
    var document: FrontmatterDocument { get set }
}

// MARK: - Interests (A18) — client owns `weights` only

public struct InterestsNote: HeimdalNote {
    public var document: FrontmatterDocument

    public init(document: FrontmatterDocument) { self.document = document }

    public var weights: [(name: String, weight: Double)] {
        guard let map = document.frontmatter["weights"]?.mapValue else { return [] }
        return map.pairs.compactMap { key, value in
            guard let weight = value.doubleValue else { return nil }
            return (key, weight)
        }
    }

    public mutating func setWeight(_ weight: Double, for name: String) {
        var map = document.frontmatter["weights"]?.mapValue ?? YAMLMap()
        map[name] = .double(weight)
        document.frontmatter["weights"] = .map(map)
    }
}

// MARK: - Watchlist / Never (A18) — client owns the list + appended body lines

public struct ListNote: HeimdalNote {
    public var document: FrontmatterDocument
    private let listKey: String

    public init(document: FrontmatterDocument, listKey: String) {
        self.document = document
        self.listKey = listKey
    }

    public var entries: [String] {
        document.frontmatter[listKey]?.stringArray ?? []
    }

    public mutating func addEntry(_ entry: String, source: String, target: String, note: String, timestamp: String) {
        var current = document.frontmatter[listKey]?.arrayValue ?? []
        let alreadyListed = current.contains(where: { $0.stringValue == entry })
        guard !alreadyListed else { return }
        current.append(.string(entry))
        document.frontmatter[listKey] = .array(current)

        let line = "- [\(timestamp)] source=\(source) target='\(target)' | \(note)"
        if !document.body.isEmpty && !document.body.hasSuffix("\n") {
            document.body += "\n"
        }
        document.body += line + "\n"
    }
}

public extension ListNote {
    static func watchlist(document: FrontmatterDocument) -> ListNote {
        ListNote(document: document, listKey: "watched")
    }

    static func never(document: FrontmatterDocument) -> ListNote {
        ListNote(document: document, listKey: "never")
    }
}

// MARK: - Settings (A14) — client owns `options` and `retention_window_days`

public struct SettingsNote: HeimdalNote {
    public var document: FrontmatterDocument

    public init(document: FrontmatterDocument) { self.document = document }

    public var options: [(key: String, value: String)] {
        guard let map = document.frontmatter["options"]?.mapValue else { return [] }
        return map.pairs.compactMap { key, value in
            guard let stringValue = value.stringValue else { return nil }
            return (key, stringValue)
        }
    }

    public mutating func setOption(_ value: String, for key: String) {
        var map = document.frontmatter["options"]?.mapValue ?? YAMLMap()
        map[key] = .string(value)
        document.frontmatter["options"] = .map(map)
    }

    public var retentionWindowDays: Int? {
        document.frontmatter["retention_window_days"]?.intValue
    }

    public mutating func setRetentionWindowDays(_ days: Int) {
        document.frontmatter["retention_window_days"] = .int(days)
    }
}

// MARK: - Entity confirmation (A17) — client reads `pending`, appends `decisions`

public struct EntityReviewEntry: Identifiable {
    public let id: String
    public let mentionId: String
    public let surfaceForm: String
    public let resolution: String
    public let confidence: Double?
    public let candidateEntityIDs: [String]
}

public struct EntityReviewNote: HeimdalNote {
    public var document: FrontmatterDocument

    public init(document: FrontmatterDocument) { self.document = document }

    public var pending: [EntityReviewEntry] {
        guard let items = document.frontmatter["pending"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let map = item.mapValue,
                  let queueEntryId = map["queue_entry_id"]?.stringValue,
                  let mentionId = map["mention_id"]?.stringValue,
                  let surfaceForm = map["surface_form"]?.stringValue,
                  let resolution = map["resolution"]?.stringValue else { return nil }
            return EntityReviewEntry(
                id: queueEntryId,
                mentionId: mentionId,
                surfaceForm: surfaceForm,
                resolution: resolution,
                confidence: map["confidence"]?.doubleValue,
                candidateEntityIDs: map["candidate_entity_ids"]?.stringArray ?? []
            )
        }
    }

    /// Appends a human decision (`merge` or `reject`). Idempotent: the
    /// backend applies decisions and removes the matching pending entry, and
    /// a duplicate write for an id no longer pending is a no-op there — but
    /// this client still avoids appending an exact duplicate decision.
    public mutating func addDecision(
        queueEntryId: String,
        action: String,
        fromId: String,
        intoId: String,
        decidedAt: String
    ) {
        var decision = YAMLMap()
        decision["queue_entry_id"] = .string(queueEntryId)
        decision["action"] = .string(action)
        decision["from_id"] = .string(fromId)
        decision["into_id"] = .string(intoId)
        decision["decided_at"] = .string(decidedAt)

        var decisions = document.frontmatter["decisions"]?.arrayValue ?? []
        let alreadyPresent = decisions.contains { existing in
            guard let existingMap = existing.mapValue else { return false }
            return existingMap["queue_entry_id"]?.stringValue == queueEntryId
                && existingMap["action"]?.stringValue == action
        }
        if !alreadyPresent {
            decisions.append(.map(decision))
            document.frontmatter["decisions"] = .array(decisions)
        }
    }
}

// MARK: - Consent (A19) — read-only display surface for this client

public struct ConsentGrant {
    public let grantRef: String?
    public let basis: String?
    public let scope: String?
    public let grantedAt: String?
    public let expiry: String?
}

public struct ConsentNote: HeimdalNote {
    public var document: FrontmatterDocument

    public init(document: FrontmatterDocument) { self.document = document }

    public var grants: [ConsentGrant] {
        guard let items = document.frontmatter["grants"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let map = item.mapValue else { return nil }
            return ConsentGrant(
                grantRef: map["grant_ref"]?.stringValue,
                basis: map["basis"]?.stringValue,
                scope: map["scope"]?.stringValue,
                grantedAt: map["granted_at"]?.stringValue,
                expiry: map["expiry"]?.stringValue
            )
        }
    }

    public var withholdReviewEnabled: Bool {
        document.frontmatter["withhold_span_review"]?.mapValue?["enabled"]?.boolValue ?? false
    }

    public var retentionErasureSupported: Bool {
        document.frontmatter["retention_erasure"]?.mapValue?["supported"]?.boolValue ?? false
    }
}

// MARK: - Attention (A16) — client appends `overrides`, reads `counts`/`reasons`

public struct AttentionOverride: Equatable {
    public let itemId: String
    public let originalDecision: String
    public let overriddenDecision: String
    public let note: String
    public let overriddenAt: String

    public init(
        itemId: String,
        originalDecision: String,
        overriddenDecision: String,
        note: String,
        overriddenAt: String
    ) {
        self.itemId = itemId
        self.originalDecision = originalDecision
        self.overriddenDecision = overriddenDecision
        self.note = note
        self.overriddenAt = overriddenAt
    }
}

public struct AttentionNote: HeimdalNote {
    public var document: FrontmatterDocument

    public init(document: FrontmatterDocument) { self.document = document }

    public var overrides: [AttentionOverride] {
        guard let items = document.frontmatter["overrides"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let map = item.mapValue,
                  let itemId = map["item_id"]?.stringValue,
                  let original = map["original_decision"]?.stringValue,
                  let overridden = map["overridden_decision"]?.stringValue,
                  let overriddenAt = map["overridden_at"]?.stringValue else { return nil }
            return AttentionOverride(
                itemId: itemId,
                originalDecision: original,
                overriddenDecision: overridden,
                note: map["note"]?.stringValue ?? "",
                overriddenAt: overriddenAt
            )
        }
    }

    public var counts: [(key: String, count: Int)] {
        guard let map = document.frontmatter["counts"]?.mapValue else { return [] }
        return map.pairs.compactMap { key, value in
            guard let count = value.intValue else { return nil }
            return (key, count)
        }
    }

    /// Appends an override. Idempotent on exact-duplicate entries, matching
    /// the backend's fold semantics.
    public mutating func addOverride(_ override: AttentionOverride) {
        var map = YAMLMap()
        map["item_id"] = .string(override.itemId)
        map["original_decision"] = .string(override.originalDecision)
        map["overridden_decision"] = .string(override.overriddenDecision)
        map["note"] = .string(override.note)
        map["overridden_at"] = .string(override.overriddenAt)

        var overrides = document.frontmatter["overrides"]?.arrayValue ?? []
        let duplicate = overrides.contains { .map(map) == $0 }
        if !duplicate {
            overrides.append(.map(map))
            document.frontmatter["overrides"] = .array(overrides)
        }
    }
}
