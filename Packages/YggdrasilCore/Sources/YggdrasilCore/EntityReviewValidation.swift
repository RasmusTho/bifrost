import Foundation

public struct EntityReviewValidationError: LocalizedError, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? {
        "Entity review is unavailable because \(reason)."
    }
}

public extension EntityReviewNote {
    /// Returns the pending queue only after every authority-bearing row in
    /// the note has been validated. A compare surface must not derive action
    /// eligibility from a partially parsed document.
    func validatedPending() throws -> [EntityReviewEntry] {
        let validator = EntityReviewDocumentValidator(document: document)
        let entries = try validator.parsePending()
        try validator.validateDecisions()
        return entries
    }
}

private struct EntityReviewDocumentValidator {
    let document: FrontmatterDocument

    func parsePending() throws -> [EntityReviewEntry] {
        let items = try sequence(named: "pending")
        return try items.enumerated().map { index, item in
            let path = "pending[\(index)]"
            guard let map = item.mapValue else {
                throw validationError("\(path) must be a mapping")
            }

            let queueEntryID = try requiredString(map["queue_entry_id"], at: "\(path).queue_entry_id")
            let mentionID = try requiredString(map["mention_id"], at: "\(path).mention_id")
            let surfaceForm = try requiredString(map["surface_form"], at: "\(path).surface_form")
            let resolution = try requiredString(map["resolution"], at: "\(path).resolution")
            let confidence = try optionalNumber(map["confidence"], at: "\(path).confidence")
            let candidateEntityIDs = try optionalStringArray(
                map["candidate_entity_ids"],
                at: "\(path).candidate_entity_ids"
            )
            try validateOptionalString(map["queued_at"], at: "\(path).queued_at")

            return EntityReviewEntry(
                id: queueEntryID,
                mentionId: mentionID,
                surfaceForm: surfaceForm,
                resolution: resolution,
                confidence: confidence,
                candidateEntityIDs: candidateEntityIDs
            )
        }
    }

    func validateDecisions() throws {
        for (index, item) in try sequence(named: "decisions").enumerated() {
            let path = "decisions[\(index)]"
            guard let map = item.mapValue else {
                throw validationError("\(path) must be a mapping")
            }

            _ = try requiredString(map["queue_entry_id"], at: "\(path).queue_entry_id")
            let action = try requiredString(map["action"], at: "\(path).action")
            try validateOptionalString(map["decided_at"], at: "\(path).decided_at")
            try validateOptionalString(map["from_id"], at: "\(path).from_id")
            try validateOptionalString(map["into_id"], at: "\(path).into_id")

            switch action {
            case "merge":
                _ = try requiredString(map["from_id"], at: "\(path).from_id")
                _ = try requiredString(map["into_id"], at: "\(path).into_id")
            case "reject":
                break
            case "undo":
                if hasNonNullValue(map["from_id"]) || hasNonNullValue(map["into_id"]) {
                    throw validationError(
                        "\(path) action 'undo' must compensate by queue_entry_id only"
                    )
                }
            default:
                throw validationError("\(path) has unsupported action '\(action)'")
            }
        }
    }

    private func sequence(named name: String) throws -> [YAMLValue] {
        guard let value = document.frontmatter[name] else { return [] }
        guard let items = value.arrayValue else {
            throw validationError("\(name) must be a sequence")
        }
        return items
    }

    private func requiredString(_ value: YAMLValue?, at path: String) throws -> String {
        guard case .string(let string)? = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw validationError("\(path) must be a non-empty string")
        }
        return string
    }

    private func validateOptionalString(_ value: YAMLValue?, at path: String) throws {
        guard let value else { return }
        switch value {
        case .null, .string:
            return
        default:
            throw validationError("\(path) must be a string when present")
        }
    }

    private func optionalNumber(_ value: YAMLValue?, at path: String) throws -> Double? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .int(let number):
            return Double(number)
        case .double(let number):
            return number
        default:
            throw validationError("\(path) must be numeric when present")
        }
    }

    private func optionalStringArray(_ value: YAMLValue?, at path: String) throws -> [String] {
        guard let value else { return [] }
        if case .null = value { return [] }
        guard let items = value.arrayValue else {
            throw validationError("\(path) must be a sequence when present")
        }
        return try items.enumerated().map { index, item in
            try requiredString(item, at: "\(path)[\(index)]")
        }
    }

    private func hasNonNullValue(_ value: YAMLValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return false }
        return true
    }

    private func validationError(_ reason: String) -> EntityReviewValidationError {
        EntityReviewValidationError(reason: reason)
    }
}
